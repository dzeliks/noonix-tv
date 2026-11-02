// one playback session: resume, progress, scrobble, skip segments, next episode, tv side effects.
// c++ owns mpv and reports open -> loaded -> tick... -> stop; everything here is bookkeeping
use crate::addons::{self, Query};
use crate::ranking;
use crate::skip::{self, Segment};
use crate::store::{self, Progress};
use crate::stremio::Stream;
use crate::system::{self, ModeSwitch};
use crate::matches::{self, Rel, Sub};
use crate::{app, home, subtitles, tmdb, trakt};
use std::collections::HashSet;
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;
use tokio::sync::Mutex;

const SAVE_EVERY_SECS: u64 = 10;
const HEARTBEAT_SECS: u64 = 300;
const COMPLETED: f64 = 0.90;
const NEXT_AT: f64 = 0.70;
const OUTRO_GUESS_SECS: f64 = 50.0;
/// shorter than this, a "movie" or "episode" is a debrid error clip ("unexpected provider response")
const DUD_SECS: f64 = 90.0;
/// "watched to the end" counts as a quiet good only for a real file
const REAL_SECS: f64 = 300.0;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub kind: String, // movie | episode
    pub tmdb: i64,    // movie id or show id
    pub imdb: Option<String>,
    pub season: Option<i64>,
    pub episode: Option<i64>,
    pub title: String,
    pub subtitle: Option<String>,
    pub episode_title: Option<String>,
    pub logo: Value,
    pub backdrop: Value,
    pub still: Value,
    pub year: Value,
    pub original_language: Option<String>,
}

impl Item {
    fn key(&self) -> String {
        match (self.season, self.episode) {
            (Some(s), Some(e)) if self.kind == "episode" => store::episode_key(self.tmdb, s, e),
            _ => store::movie_key(self.tmdb),
        }
    }
    fn trakt_target(&self) -> Value {
        let kind = if self.kind == "episode" { "show" } else { "movie" };
        trakt::target(kind, self.tmdb, self.imdb.as_deref(), self.season, self.episode)
    }
}

struct Session {
    id: u64,
    profile: i64,
    item: Item,
    position: f64,
    duration: f64,
    paused: bool,
    started: bool,
    last_save: Instant,
    last_heartbeat: Instant,
    mode: Option<ModeSwitch>,
    output: String,
    leds: bool,
    segments: Vec<Segment>,
    next_asked: bool,
    next: Option<Value>,
    release: subtitles::Release,
    stream: Stream,
    rel: Rel,
    /// the subtitle on screen (none = off)
    sub: Option<Sub>,
    /// every external subtitle handed to the player, by path
    ext: Vec<subtitles::Found>,
    tried_subs: HashSet<String>,
    reported: bool,
}

// sources already tried for one title ("picture or sound problem" moves on, never back)
/// per title: the files tried, and (resolution, size) of each so the same encode under another name counts too
#[allow(clippy::type_complexity)]
static TRIED_SOURCES: Lazy<Mutex<(String, HashSet<String>, Vec<(u32, u64)>)>> = Lazy::new(|| Mutex::new((String::new(), HashSet::new(), Vec::new())));

/// another scraper's name for a file already tried: same resolution, size within 0.5 %
fn same_copy(s: &Stream, tried: &[(u32, u64)]) -> bool {
    let Some(size) = s.size.filter(|n| *n > 0) else { return false };
    tried.iter().any(|(res, other)| *res == s.resolution && (size as f64 - *other as f64).abs() <= *other as f64 * 0.005)
}

static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
static IDS: AtomicU64 = AtomicU64::new(1);

/// NOONIX_TEST=1: no refresh switching, no pad leds (tests run beside real use of the tv)
fn test_mode() -> bool {
    std::env::var_os("NOONIX_TEST").is_some_and(|v| v != "0")
}

async fn setting_on(key: &'static str) -> bool {
    setting_or(key, true).await
}

async fn setting_or(key: &'static str, default: bool) -> bool {
    store::with(move |c| store::get_setting(c, "app", key)).await.ok().flatten().and_then(|v| v.as_bool()).unwrap_or(default)
}

async fn item_for(kind: &str, tmdb_id: i64, season: Option<i64>, episode: Option<i64>) -> Result<Item> {
    let d = tmdb::details(if kind == "movie" { "movie" } else { "show" }, tmdb_id).await?;
    let s = |k: &str| d.get(k).and_then(Value::as_str).map(str::to_owned);
    let mut item = Item {
        kind: if kind == "movie" { "movie".into() } else { "episode".into() },
        tmdb: tmdb_id,
        imdb: s("imdb"),
        season,
        episode,
        title: s("title").unwrap_or_default(),
        subtitle: None,
        episode_title: None,
        logo: d.get("logo").cloned().unwrap_or(Value::Null),
        backdrop: d.get("backdrop").cloned().unwrap_or(Value::Null),
        still: Value::Null,
        year: d.get("year").cloned().unwrap_or(Value::Null),
        original_language: s("originalLanguage"),
    };
    if let (Some(se), Some(ep)) = (season, episode) {
        if let Ok(e) = tmdb::episode_details(tmdb_id, se, ep).await {
            item.episode_title = e.get("episodeTitle").and_then(Value::as_str).map(str::to_owned);
            item.still = e.get("still").cloned().unwrap_or(Value::Null);
        }
        item.subtitle = Some(match &item.episode_title {
            Some(t) => format!("S{se} · E{ep}  {t}"),
            None => format!("S{se} · E{ep}"),
        });
    }
    Ok(item)
}

/// what c++ needs to start mpv: url, headers, start point, languages, osd metadata
pub async fn open(profile: i64, args: &Value) -> Result<Value> {
    let kind = args.get("kind").and_then(Value::as_str).context("missing kind")?;
    let tmdb_id = args.get("tmdb").and_then(Value::as_i64).context("missing tmdb")?;
    let season = args.get("season").and_then(Value::as_i64);
    let episode = args.get("episode").and_then(Value::as_i64);
    let stream: Stream = serde_json::from_value(args.get("stream").cloned().context("missing stream")?)?;
    stop(&json!({ "reason": "replaced" })).await.ok();
    let url = match (&stream.url, &stream.info_hash) {
        (Some(u), _) => u.clone(),
        (None, Some(h)) if store::with(|c| Ok(addons::torrents(c))).await? == Some(true) => crate::torrent::url_for(h, stream.file_idx, &stream.sources).await?,
        _ => anyhow::bail!("this source has no playable address"),
    };
    let item = item_for(kind, tmdb_id, season, episode).await?;

    // explicit start (seconds) from the resume prompt, else the saved point
    let start: Option<f64> = match args.get("start") {
        Some(Value::Number(n)) => n.as_f64(),
        _ => {
            let key = item.key();
            store::with(move |c| store::get_progress(c, profile, &key))
                .await
                .ok()
                .flatten()
                .filter(|p| !p.completed && p.position > 30.0 && p.duration > 0.0 && p.position / p.duration < COMPLETED)
                .map(|p| (p.position - 5.0).max(0.0))
        }
    };

    if item.kind == "episode" {
        // a release of another show once pinned itself here (friends -> "your friends and neighbors")
        if !stream.off_title {
            addons::remember(profile, tmdb_id, &stream).await.ok();
        }
    }
    let prefs = addons::prefs(profile).await;
    let original = item.original_language.as_deref();
    let headers: Vec<String> = stream.headers.iter().map(|(k, v)| format!("{k}: {v}")).collect();

    let id = IDS.fetch_add(1, Ordering::Relaxed);
    *SESSION.lock().await = Some(Session {
        id,
        profile,
        item: item.clone(),
        position: start.unwrap_or(0.0),
        duration: 0.0,
        paused: false,
        started: false,
        last_save: Instant::now(),
        last_heartbeat: Instant::now(),
        mode: None,
        output: String::new(),
        leds: false,
        segments: Vec::new(),
        next_asked: false,
        next: None,
        release: subtitles::Release::of(&stream),
        rel: matches::rel_of(&item.key(), (item.kind == "episode").then_some(tmdb_id), &stream),
        stream: stream.clone(),
        sub: None,
        ext: Vec::new(),
        tried_subs: HashSet::new(),
        reported: false,
    });
    system::write_state(Some(json!({ "state": "loading", "title": item.title })));
    Ok(json!({
        "session": id,
        "url": url,
        "headers": headers,
        "start": start,
        "alang": ranking::mpv_langs(&prefs.languages, original),
        "slang": ranking::mpv_langs(&prefs.subtitles, original),
        "item": item,
        "stream": { "resolution": stream.resolution, "hdr": stream.hdr, "codec": stream.codec, "audio": stream.audio, "group": stream.group },
    }))
}

/// file is loaded (paused): match the tv's refresh rate, dim pads, start scrobbling
pub async fn loaded(args: &Value) -> Result<Value> {
    let duration = args.get("duration").and_then(Value::as_f64).unwrap_or(0.0);
    let fps = args.get("fps").and_then(Value::as_f64).unwrap_or(0.0);
    let output = args.get("output").and_then(Value::as_str).unwrap_or("").to_owned();
    let chapters: Vec<(String, f64)> = args
        .get("chapters")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|c| Some((c.get("title").and_then(Value::as_str).unwrap_or("").to_owned(), c.get("time")?.as_f64()?)))
                .collect()
        })
        .unwrap_or_default();

    let (id, item, profile, mut release, rel, local) = {
        let mut g = SESSION.lock().await;
        let s = g.as_mut().context("no playback session")?;
        s.duration = duration;
        s.release.fps = fps;
        s.release.duration = duration;
        s.output = output.clone();
        (s.id, s.item.clone(), s.profile, s.release.clone(), s.rel.clone(), s.stream.local)
    };
    release.fps = fps;
    release.duration = duration;

    // dolby vision profile 5 has no hdr10 base: vo_gpu shows it green and purple (gpu-next reshapes
    // it). reported like a picture problem, the ui moves to another version when there is one and
    // keeps this one otherwise
    let dv_profile = args.get("dvProfile").and_then(Value::as_i64).unwrap_or(0);
    if dv_profile > 0 {
        tracing::info!("dolby vision profile {dv_profile}");
    }
    if dv_profile == 5 && !crate::ranking::display().dv {
        tracing::warn!("dolby vision profile 5 without an hdr10 base: looking for another version");
        let r = rel.clone();
        store::with(move |c| matches::judge(c, &r, None, matches::BAD, Some("av"))).await.ok();
        app::emit("playback.dv", json!({ "session": id }));
    }

    // an error clip instead of the title: reported, and the ui moves on to the next source (a file
    // of the user's own is whatever it is)
    let dud = !local && duration > 0.0 && duration < DUD_SECS;
    if dud {
        tracing::warn!("{:.0} s long: an error clip, not the title", duration);
        let r = rel.clone();
        store::with(move |c| matches::judge(c, &r, None, matches::BAD, Some("av"))).await.ok();
        if let Some(s) = SESSION.lock().await.as_mut().filter(|s| s.id == id) {
            s.reported = true;
        }
        app::emit("playback.dud", json!({ "session": id }));
    }

    // the file's own subtitle tracks, minus the ones the viewers reported for this release
    let tracks: Vec<Value> = args.get("tracks").and_then(Value::as_array).cloned().unwrap_or_default();
    let learn = {
        let rel = rel.clone();
        store::with(move |c| matches::sub_learn(c, &rel)).await.unwrap_or_default()
    };
    let (embedded, sub_pick) = pick_embedded(&tracks, &learn);
    let take = sub_pick == Some(-1) || learn.exact.iter().any(|s| !s.is_embedded());
    // a file the viewer added to this title last time comes back on, after the player's own pick
    let imported = {
        let key = imported_key(&item.key());
        store::with(move |c| store::get_setting(c, &format!("profile:{profile}"), &key)).await.ok().flatten()
    }
    .and_then(|v| serde_json::from_value::<subtitles::Found>(v).ok())
    .filter(|f| std::path::Path::new(&f.path).exists());
    let take = take && imported.is_none();
    if let Some(f) = imported {
        app::RUNTIME.spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            hand_over(id, vec![f], true).await;
        });
    }
    // extra subtitles for the preferences the file has no (good) track for; arrive a moment later
    if let (Some(imdb), false, true) = (item.imdb.clone(), dud, setting_on("extra_subs").await) {
        let (season, ep, original) = (item.season, item.episode, item.original_language.clone());
        app::RUNTIME.spawn(async move {
            let prefs = addons::prefs(profile).await;
            match subtitles::find(&imdb, season, ep, &prefs.subtitles, original.as_deref(), &embedded, &release, &learn).await {
                Ok(found) if !found.is_empty() => hand_over(id, found, take).await,
                Ok(_) => {}
                Err(e) => tracing::warn!("extra subtitles: {e:#}"),
            }
        });
    }
    let episode = item.kind == "episode";
    let from_chapters = skip::from_chapters(&chapters, duration);
    let segments = skip::merge(from_chapters.clone(), Vec::new(), duration, OUTRO_GUESS_SECS, episode);

    // introdb fills what chapters didn't cover; arrives after playback started
    if let (true, Some(imdb), Some(se), Some(ep)) = (episode, item.imdb.clone(), item.season, item.episode) {
        let have = segments.clone();
        app::RUNTIME.spawn(async move {
            let found = skip::introdb(&imdb, se, ep).await;
            let merged = skip::merge(from_chapters, found, duration, OUTRO_GUESS_SECS, true);
            let line: Vec<String> = merged.iter().map(|g| format!("{} {:.0}-{:.0} ({})", g.kind, g.start, g.end, g.source)).collect();
            tracing::info!("skip segments: {}", line.join(", "));
            if merged != have {
                let mut g = SESSION.lock().await;
                if let Some(s) = g.as_mut().filter(|s| s.id == id) {
                    s.segments = merged.clone();
                    app::emit("playback.skip", json!({ "session": id, "segments": merged }));
                }
            }
        });
    }

    let allow_refresh = args.get("refresh").and_then(Value::as_bool).unwrap_or(true)
        && !test_mode()
        && !output.is_empty()
        && setting_or("refresh_match", false).await;
    let (mode, exact) = if allow_refresh {
        system::match_refresh(&output, fps).await.unwrap_or_else(|e| {
            tracing::warn!("refresh match: {e:#}");
            (None, false)
        })
    } else {
        (None, false)
    };
    let leds = !test_mode() && setting_on("pad_leds").await;
    if leds {
        system::pads_dim(true);
    }
    {
        let mut g = SESSION.lock().await;
        if let Some(s) = g.as_mut().filter(|s| s.id == id) {
            s.mode = mode;
            s.leds = leds;
            s.segments = segments.clone();
        } else if let Some(m) = mode {
            system::restore_refresh(&m).await; // stopped while we switched
        }
    }
    Ok(json!({
        "session": id,
        "sync": if exact { "audio" } else { "display-resample" },
        "segments": segments,
        "refresh": allow_refresh,
        "subPick": sub_pick,
    }))
}

/// (languages of the usable embedded tracks, the track to select: an id, -1 = off until the
/// externals arrive, none = leave mpv's own pick). a track liked with this file wins; one the
/// viewers reported is never the pick
fn pick_embedded(tracks: &[Value], learn: &matches::SubLearn) -> (Vec<String>, Option<i64>) {
    let key = |t: &Value| {
        let s = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
        Sub::embedded(&s("lang"), &s("title"), &s("codec")).key
    };
    let full: Vec<&Value> = tracks.iter().filter(|t| !t.get("forced").and_then(Value::as_bool).unwrap_or(false)).collect();
    let usable: Vec<&&Value> = full.iter().filter(|t| !learn.avoid_embedded.contains(&key(t))).collect();
    let langs = usable.iter().filter_map(|t| t.get("lang").and_then(Value::as_str).map(str::to_owned)).collect();
    if let Some(t) = full.iter().find(|t| learn.exact.iter().any(|s| s.key == key(t))) {
        return (langs, t.get("id").and_then(Value::as_i64));
    }
    let selected = full.iter().find(|t| t.get("selected").and_then(Value::as_bool).unwrap_or(false));
    match selected {
        Some(t) if learn.avoid_embedded.contains(&key(t)) => {
            // another track in the same language, else off until the externals come
            let lang = t.get("lang").and_then(Value::as_str).unwrap_or("");
            let other = usable.iter().find(|u| u.get("lang").and_then(Value::as_str) == Some(lang));
            (langs, Some(other.and_then(|u| u.get("id").and_then(Value::as_i64)).unwrap_or(-1)))
        }
        _ => (langs, None),
    }
}

/// external subtitles to the player (take = select the first even when a track is on)
async fn hand_over(id: u64, found: Vec<subtitles::Found>, take: bool) {
    let mut g = SESSION.lock().await;
    let Some(s) = g.as_mut().filter(|s| s.id == id) else { return };
    for f in &found {
        if !s.ext.iter().any(|e| e.path == f.path) {
            s.ext.push(f.clone());
        }
    }
    app::emit("playback.subs", json!({ "session": id, "subs": found, "take": take }));
}

fn track_sub(s: &Session, t: &Value) -> Option<Sub> {
    let str_of = |k: &str| t.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    if t.get("external").and_then(Value::as_bool).unwrap_or(false) {
        let file = str_of("file");
        return Some(match s.ext.iter().find(|e| e.path == file) {
            Some(f) => f.sub(),
            None => {
                let name = std::path::Path::new(&file).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(file.clone());
                Sub { key: format!("ext:{name}"), lang: str_of("lang"), name: str_of("title"), provider: "file".into(), src: None }
            }
        });
    }
    t.get("id")?;
    Some(Sub::embedded(&str_of("lang"), &str_of("title"), &str_of("codec")))
}

/// the player switched subtitles (or turned them off): the timing that goes with this one
pub async fn sub_changed(args: &Value) -> Result<Value> {
    let (rel, sub) = {
        let mut g = SESSION.lock().await;
        let Some(s) = g.as_mut() else { return Ok(json!({ "delayMs": 0 })) };
        let sub = args.get("track").filter(|t| t.is_object()).and_then(|t| track_sub(s, t));
        s.sub = sub.clone();
        (s.rel.clone(), sub)
    };
    let Some(sub) = sub else { return Ok(json!({ "delayMs": 0 })) };
    let found = store::with(move |c| matches::offset_for(c, &rel, &sub)).await.unwrap_or(None);
    Ok(match found {
        // the ui translates the note (qml/CoreStrings.js) and fills in the args
        Some((ms, from)) => match from.as_deref().and_then(matches::episode_label) {
            Some(e) => json!({ "delayMs": ms, "note": "Subtitle timing %1, as on %2", "noteArgs": [signed_secs(ms), e] }),
            None => json!({ "delayMs": ms }),
        },
        None => json!({ "delayMs": 0 }),
    })
}

pub fn signed_secs(ms: i64) -> String {
    format!("{}{:.1} s", if ms < 0 { "−" } else { "+" }, ms.abs() as f64 / 1000.0)
}

/// the player's refresh button: matching on / off right now (and from now on)
pub async fn refresh(args: &Value) -> Result<Value> {
    let on = args.get("on").and_then(Value::as_bool).unwrap_or(false);
    store::with(move |c| store::set_setting(c, "app", "refresh_match", &json!(on))).await?;
    let (id, output, fps, mode) = {
        let mut g = SESSION.lock().await;
        let s = g.as_mut().context("no playback session")?;
        (s.id, s.output.clone(), s.release.fps, s.mode.take())
    };
    if let Some(m) = &mode {
        system::restore_refresh(m).await;
    }
    let (mode, exact) = if on && !test_mode() && !output.is_empty() {
        system::match_refresh(&output, fps).await.unwrap_or_else(|e| {
            tracing::warn!("refresh match: {e:#}");
            (None, false)
        })
    } else {
        (None, false)
    };
    let mut g = SESSION.lock().await;
    match g.as_mut().filter(|s| s.id == id) {
        Some(s) => s.mode = mode,
        None => {
            if let Some(m) = &mode {
                system::restore_refresh(m).await;
            }
        }
    }
    Ok(json!({ "on": on, "sync": if exact { "audio" } else { "display-resample" } }))
}

fn scrobble(profile: i64, item: &Item, action: &'static str, progress: f64) {
    let target = item.trakt_target();
    app::RUNTIME.spawn(async move {
        if let Ok(Some(acc)) = trakt::Account::for_profile(profile).await {
            if let Err(e) = acc.scrobble(action, &target, progress).await {
                tracing::warn!("scrobble {action}: {e:#}");
            }
            if action == "stop" {
                acc.invalidate().await;
            }
        }
    });
}

fn progress_row(s: &Session, completed: bool) -> Progress {
    Progress {
        key: s.item.key(),
        kind: s.item.kind.clone(),
        tmdb: s.item.tmdb,
        imdb: s.item.imdb.clone(),
        season: s.item.season,
        episode: s.item.episode,
        title: Some(s.item.title.clone()),
        position: s.position,
        duration: s.duration,
        completed,
        updated: store::now(),
    }
}

/// position reports: every ~10 s while playing, and on pause/resume/seek
/// the picker's "search subtitles": every preferred language, embedded tracks or not
pub async fn search_subs() -> Result<Value> {
    let (id, item, profile, release) = {
        let g = SESSION.lock().await;
        let s = g.as_ref().context("nothing is playing")?;
        (s.id, s.item.clone(), s.profile, s.release.clone())
    };
    let imdb = item.imdb.clone().context("this title has no imdb id")?;
    let prefs = addons::prefs(profile).await;
    let learn = store::with({
        let rel = SESSION.lock().await.as_ref().map(|s| s.rel.clone()).unwrap_or_default();
        move |c| matches::sub_learn(c, &rel)
    })
    .await
    .unwrap_or_default();
    let found = subtitles::find(&imdb, item.season, item.episode, &prefs.subtitles, item.original_language.as_deref(), &[], &release, &learn).await?;
    let count = found.len();
    if count > 0 {
        hand_over(id, found, false).await;
    }
    Ok(json!({ "count": count }))
}

fn imported_key(item: &str) -> String {
    format!("imported_sub:{item}")
}

/// a subtitle file the viewer picked: on at once, and on again the next time this title plays
pub async fn import_sub(path: &str) -> Result<Value> {
    let path = path.to_owned();
    let found = tokio::task::spawn_blocking(move || subtitles::import(&path)).await??;
    let (id, profile, key) = {
        let g = SESSION.lock().await;
        let s = g.as_ref().context("nothing is playing")?;
        (s.id, s.profile, imported_key(&s.item.key()))
    };
    let v = serde_json::to_value(&found)?;
    store::with(move |c| store::set_setting(c, &format!("profile:{profile}"), &key, &v)).await?;
    hand_over(id, vec![found], true).await;
    Ok(json!({ "ok": true }))
}

pub async fn tick(args: &Value) -> Result<Value> {
    let position = args.get("position").and_then(Value::as_f64).unwrap_or(0.0);
    let paused = args.get("paused").and_then(Value::as_bool).unwrap_or(false);
    let mut g = SESSION.lock().await;
    let Some(s) = g.as_mut() else { return Ok(json!({ "session": null })) };
    if let Some(d) = args.get("duration").and_then(Value::as_f64).filter(|d| *d > 0.0) {
        s.duration = d;
    }
    s.position = position;
    let frac = if s.duration > 0.0 { position / s.duration } else { 0.0 };

    let state_changed = !s.started || paused != s.paused;
    s.paused = paused;
    if state_changed {
        scrobble(s.profile, &s.item, if paused { "pause" } else { "start" }, frac);
        s.started = true;
        s.last_heartbeat = Instant::now();
        system::write_state(Some(json!({ "state": if paused { "paused" } else { "playing" }, "title": s.item.title })));
    } else if !paused && s.last_heartbeat.elapsed().as_secs() >= HEARTBEAT_SECS {
        scrobble(s.profile, &s.item, "start", frac);
        s.last_heartbeat = Instant::now();
    }

    if state_changed || s.last_save.elapsed().as_secs() >= SAVE_EVERY_SECS || args.get("reason").and_then(Value::as_str) == Some("seek") {
        s.last_save = Instant::now();
        if s.duration > 0.0 && position > 5.0 {
            let row = progress_row(s, false);
            let profile = s.profile;
            app::RUNTIME.spawn(async move {
                let _ = store::with(move |c| store::save_progress(c, profile, &row)).await;
            });
        }
    }

    if s.item.kind == "episode" && !s.next_asked && frac >= NEXT_AT {
        s.next_asked = true;
        let (id, profile, show, se, ep) = (s.id, s.profile, s.item.tmdb, s.item.season.unwrap_or(0), s.item.episode.unwrap_or(0));
        app::RUNTIME.spawn(async move {
            let next = find_next(profile, show, se, ep).await;
            let mut g = SESSION.lock().await;
            if let Some(s) = g.as_mut().filter(|s| s.id == id) {
                s.next = next.clone();
                app::emit("playback.next", json!({ "session": id, "next": next }));
            }
        });
    }
    Ok(json!({ "session": s.id }))
}

async fn find_next(profile: i64, show: i64, season: i64, episode: i64) -> Option<Value> {
    let (ns, ne) = home::next_episode(show, season, episode).await?;
    let q = Query { req: "next".into(), kind: "show".into(), tmdb: show, season: Some(ns), episode: Some(ne) };
    let found = addons::streams(profile, q).await.ok()?;
    let top = found.get("streams").and_then(Value::as_array).and_then(|a| a.first()).cloned()?;
    let ep = tmdb::episode_details(show, ns, ne).await.ok();
    Some(json!({
        "kind": "show",
        "tmdb": show,
        "season": ns,
        "episode": ne,
        "title": ep.as_ref().and_then(|e| e.get("episodeTitle")).cloned(),
        "still": ep.as_ref().and_then(|e| e.get("still")).cloned(),
        "stream": top,
    }))
}

/// end of the session: final save + scrobble, history, undo the tv side effects
pub async fn stop(args: &Value) -> Result<Value> {
    let Some(mut s) = SESSION.lock().await.take() else { return Ok(json!({ "session": null })) };
    crate::torrent::stop().await;
    if let Some(p) = args.get("position").and_then(Value::as_f64) {
        s.position = p;
    }
    if let Some(d) = args.get("duration").and_then(Value::as_f64).filter(|d| *d > 0.0) {
        s.duration = d;
    }
    let reason = args.get("reason").and_then(Value::as_str).unwrap_or("user");
    let frac = if s.duration > 0.0 { s.position / s.duration } else { 0.0 };
    // past the outro guess or at the end of file counts as watched
    let completed = s.duration > 0.0 && (frac >= COMPLETED || (reason == "eof" && frac > 0.5));

    if s.started && s.duration > 0.0 {
        let row = progress_row(&s, completed);
        let profile = s.profile;
        store::with(move |c| {
            store::save_progress(c, profile, &row)?;
            if row.completed {
                store::add_history(c, profile, &row)?;
            }
            Ok(())
        })
        .await
        .ok();
        scrobble(s.profile, &s.item, "stop", if completed { frac.max(COMPLETED) } else { frac });
        // watched to the end without a report: a quiet "good" for the pair
        if completed && !s.reported && s.duration >= REAL_SECS {
            let (rel, sub) = (s.rel.clone(), s.sub.clone());
            store::with(move |c| matches::watched(c, &rel, sub.as_ref())).await.ok();
        }
    }
    if let Some(m) = &s.mode {
        system::restore_refresh(m).await;
    }
    if s.leds {
        system::pads_dim(false);
    }
    system::write_state(None);
    Ok(json!({ "session": s.id, "completed": completed, "next": s.next }))
}

/// the prepared next episode, ready for open()
pub async fn next() -> Option<Value> {
    SESSION.lock().await.as_ref().and_then(|s| s.next.clone())
}

// ---- the player's match sheet: "good match", what's wrong, other subtitles / sources, timing

/// what's playing, for the sheet's header and its marks
pub async fn match_state() -> Result<Value> {
    let (rel, sub, stream) = {
        let g = SESSION.lock().await;
        let s = g.as_ref().context("nothing is playing")?;
        (s.rel.clone(), s.sub.clone(), s.stream.clone())
    };
    let sub_key = sub.as_ref().map(|s| s.key.clone());
    let (rm, sm) = store::with(move |c| {
        let rm = matches::get(c, &rel, "")?;
        let sm = match &sub_key {
            Some(k) => matches::get(c, &rel, k)?,
            None => None,
        };
        Ok((rm, sm))
    })
    .await?;
    Ok(json!({
        "release": { "label": release_label(&stream), "group": stream.group, "file": stream.filename },
        "sub": sub.map(|s| json!({
            "lang": s.lang, "name": s.name, "provider": s.provider, "embedded": s.is_embedded(),
            // a file of the viewer's own isn't made for any release, whatever its name says
            "group": if s.provider == "file" { None } else { matches::sub_group_name(&s.name) },
        })),
        "releaseMark": matches::state_json(rm),
        "subMark": matches::state_json(sm),
    }))
}

fn release_label(s: &Stream) -> String {
    let res = match s.resolution {
        2160 => "4K".to_owned(),
        0 => String::new(),
        r => format!("{r}p"),
    };
    [res, s.source.clone().unwrap_or_default(), s.group.clone().unwrap_or_default()]
        .into_iter()
        .filter(|x| !x.is_empty())
        .collect::<Vec<_>>()
        .join(" · ")
}

/// good: the release and the subtitle on screen are right. bad + why: sync | wrong (the
/// subtitle) or av (the release itself)
pub async fn match_rate(args: &Value) -> Result<Value> {
    let verdict = args.get("verdict").and_then(Value::as_str).context("missing verdict")?.to_owned();
    let reason = args.get("reason").and_then(Value::as_str).map(str::to_owned);
    let (rel, sub) = {
        let mut g = SESSION.lock().await;
        let s = g.as_mut().context("nothing is playing")?;
        s.reported = verdict == "bad";
        (s.rel.clone(), s.sub.clone())
    };
    store::with(move |c| {
        match (verdict.as_str(), reason.as_deref()) {
            ("good", _) => {
                matches::judge(c, &rel, None, matches::GOOD, None)?;
                if let Some(s) = &sub {
                    matches::judge(c, &rel, Some(s), matches::GOOD, None)?;
                }
            }
            ("bad", Some("av")) => matches::judge(c, &rel, None, matches::BAD, Some("av"))?,
            ("bad", Some(r @ ("sync" | "wrong"))) => {
                let s = sub.as_ref().context("no subtitles are on")?;
                matches::judge(c, &rel, Some(s), matches::BAD, Some(r))?;
            }
            _ => anyhow::bail!("unknown rating"),
        }
        Ok(())
    })
    .await?;
    Ok(json!({ "ok": true }))
}

/// "try other subtitles": tracks: every subtitle track the player has. the next one in the same
/// language set: a track already there (embedded first), else a new one from the sources.
/// {select: id} | {added: true} | {none: true}, with how many are left to try
pub async fn match_next_sub(args: &Value) -> Result<Value> {
    let tracks: Vec<Value> = args.get("tracks").and_then(Value::as_array).cloned().unwrap_or_default();
    let (id, item, profile, rel, release, cur, keyed, tried) = {
        let mut g = SESSION.lock().await;
        let s = g.as_mut().context("nothing is playing")?;
        if let Some(c) = &s.sub {
            s.tried_subs.insert(c.key.clone());
        }
        let mut keyed: Vec<(i64, bool, Sub)> = tracks
            .iter()
            .filter(|t| !t.get("forced").and_then(Value::as_bool).unwrap_or(false))
            .filter_map(|t| {
                let ext = t.get("external").and_then(Value::as_bool).unwrap_or(false);
                Some((t.get("id")?.as_i64()?, ext, track_sub(s, t)?))
            })
            .collect();
        keyed.sort_by_key(|(_, ext, _)| *ext);
        (s.id, s.item.clone(), s.profile, s.rel.clone(), s.release.clone(), s.sub.clone(), keyed, s.tried_subs.clone())
    };
    let learn = {
        let rel = rel.clone();
        store::with(move |c| matches::sub_learn(c, &rel)).await.unwrap_or_default()
    };
    let prefs = addons::prefs(profile).await;
    let sets = ranking::expand(&prefs.subtitles, item.original_language.as_deref());
    let two = cur.as_ref().and_then(|s| subtitles::two_letter(&s.lang));
    let set = two.as_ref().and_then(|l| sets.iter().find(|set| set.contains(l))).or(sets.first()).cloned().unwrap_or_default();
    let skip: HashSet<String> = tried.iter().chain(learn.bad.iter()).cloned().collect();
    // the release names of the ones ruled out: the other source's copy is skipped too
    let mut names: HashSet<String> = learn.bad_names.clone();
    names.extend(keyed.iter().filter(|(_, ext, s)| *ext && tried.contains(&s.key)).map(|(_, _, s)| s.name.to_lowercase()));
    let in_set = |s: &Sub| subtitles::two_letter(&s.lang).is_some_and(|l| set.contains(&l));
    let fresh = |ext: bool, s: &Sub| !skip.contains(&s.key) && !(ext && !s.name.is_empty() && names.contains(&s.name.to_lowercase()));
    let there: Vec<&(i64, bool, Sub)> = keyed.iter().filter(|(_, ext, s)| in_set(s) && fresh(*ext, s)).collect();
    if let Some((tid, _, s)) = there.first() {
        tracing::info!("trying subtitle track {tid}: {}", s.name);
        return Ok(json!({ "select": tid, "left": there.len() - 1 }));
    }
    let Some(imdb) = item.imdb.clone() else { return Ok(json!({ "none": true })) };
    // the ones the player has count as tried here
    let skip: HashSet<String> = skip.into_iter().chain(keyed.iter().map(|(_, _, s)| s.key.clone())).collect();
    let (found, left) = subtitles::next(&imdb, item.season, item.episode, &set, &release, &learn, &skip, &names).await?;
    match found {
        Some(f) => {
            tracing::info!("trying subtitle {} {}: {}", f.provider, f.key, f.title);
            hand_over(id, vec![f], true).await;
            Ok(json!({ "added": true, "left": left }))
        }
        None => {
            tracing::info!("no other subtitles to try");
            Ok(json!({ "none": true }))
        }
    }
}

/// "picture or sound problem": the next source for this title, past every one tried here.
/// {stream, start} or {stream: null}
pub async fn match_next_source(args: &Value) -> Result<Value> {
    let (profile, item, file, copy, pos) = {
        let g = SESSION.lock().await;
        let s = g.as_ref().context("nothing is playing")?;
        // the player's own position: the session's lags up to a progress report behind
        let live = args.get("position").and_then(Value::as_f64).filter(|p| *p > 0.0);
        (s.profile, s.item.clone(), s.rel.file.clone(), s.stream.size.map(|n| (s.stream.resolution, n)), live.unwrap_or(s.position))
    };
    let (tried, copies) = {
        let mut t = TRIED_SOURCES.lock().await;
        if t.0 != item.key() {
            *t = (item.key(), HashSet::new(), Vec::new());
        }
        t.1.insert(file);
        t.2.extend(copy);
        (t.1.clone(), t.2.clone())
    };
    let q = Query {
        req: "reroll".into(),
        kind: q_kind(&item).into(),
        tmdb: item.tmdb,
        season: item.season,
        episode: item.episode,
    };
    let found = addons::streams(profile, q).await?;
    let left: Vec<Stream> = found
        .get("streams")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|v| serde_json::from_value::<Stream>(v.clone()).ok())
        // the list only has torrents when they're allowed
        .filter(|s| (s.url.is_some() || s.info_hash.is_some()) && !s.off_title && !tried.contains(&matches::file_key(s)) && !same_copy(s, &copies))
        .collect();
    // picked from the sources list with one addon shown: its next one, the rest when it has none
    let addon = args.get("addon").and_then(Value::as_str).unwrap_or("");
    let next = left.iter().find(|s| !addon.is_empty() && s.addon == addon).or(left.first());
    // the title to open it with (after "next episode" the ui's own target is the previous one)
    let target = json!({ "kind": q_kind(&item), "tmdb": item.tmdb, "season": item.season, "episode": item.episode });
    Ok(json!({ "stream": next, "start": pos, "target": target }))
}

fn q_kind(item: &Item) -> &'static str {
    if item.kind == "episode" { "show" } else { "movie" }
}

/// timing set by hand for the subtitle on screen
pub async fn match_offset(args: &Value) -> Result<Value> {
    let ms = args.get("ms").and_then(Value::as_i64).context("missing ms")?;
    let (rel, sub) = {
        let g = SESSION.lock().await;
        let s = g.as_ref().context("nothing is playing")?;
        (s.rel.clone(), s.sub.clone().context("no subtitles are on")?)
    };
    store::with(move |c| matches::set_offset(c, &rel, &sub, ms)).await?;
    Ok(json!({ "ok": true }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_encode_under_another_name() {
        let mut s = crate::stremio::parse_release("Euphoria (2019) S01E02 (2160p WEB-DL Hybrid H265 DV HDR DDP 5.1 English - GRP).mkv");
        s.size = Some(10_020_000_000);
        assert!(same_copy(&s, &[(2160, 10_000_000_000)]));
        assert!(!same_copy(&s, &[(1080, 10_000_000_000)]));
        assert!(!same_copy(&s, &[(2160, 9_000_000_000)]));
        s.size = None;
        assert!(!same_copy(&s, &[(2160, 10_000_000_000)]));
    }

    #[test]
    fn embedded_pick_follows_the_viewers() {
        let t = |id: i64, lang: &str, title: &str, selected: bool| json!({ "id": id, "lang": lang, "title": title, "codec": "subrip", "selected": selected, "forced": false });
        let tracks = vec![t(1, "eng", "English", true), t(2, "eng", "SDH", false), t(3, "srp", "Srpski", false)];
        let none = matches::SubLearn::default();
        assert_eq!(pick_embedded(&tracks, &none), (vec!["eng".to_owned(), "eng".to_owned(), "srp".to_owned()], None));
        // the selected english track was reported: the other english one, and it no longer counts
        let mut learn = matches::SubLearn::default();
        learn.avoid_embedded.insert(Sub::embedded("eng", "English", "subrip").key);
        assert_eq!(pick_embedded(&tracks, &learn), (vec!["eng".to_owned(), "srp".to_owned()], Some(2)));
        // both english tracks reported: off until the externals arrive, english is missing now
        learn.avoid_embedded.insert(Sub::embedded("eng", "SDH", "subrip").key);
        assert_eq!(pick_embedded(&tracks, &learn), (vec!["srp".to_owned()], Some(-1)));
        // a track liked with this file wins
        let mut liked = matches::SubLearn::default();
        liked.exact.push(Sub::embedded("srp", "Srpski", "subrip"));
        assert_eq!(pick_embedded(&tracks, &liked).1, Some(3));
        assert_eq!(signed_secs(-1250), "−1.2 s");
        assert_eq!(signed_secs(400), "+0.4 s");
    }
}
