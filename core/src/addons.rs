// addon registry + parallel stream lookup across enabled addons
use crate::config::{preview, redact};
use crate::ranking::{self, Prefs};
use crate::store::{self, SourceMemory};
use crate::stremio::{self, Addon, Stream};
use crate::{app, tmdb};
use anyhow::{Context, Result};
use futures::stream::{FuturesUnordered, StreamExt};
use rusqlite::{params, Connection};
use serde::Serialize;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: i64,
    pub name: String,
    pub version: String,
    /// never the full url, it carries tokens
    pub address: String,
    pub resources: Vec<String>,
    pub types: Vec<String>,
    pub enabled: bool,
    pub formatting: Option<String>,
    pub last_error: Option<String>,
    /// the extension that added it (settings lists it there), None = added by hand
    pub extension: Option<String>,
    #[serde(skip)]
    pub addon: Option<Addon>,
}

fn rows(c: &Connection) -> Result<Vec<Row>> {
    let mut st = c.prepare(
        "select id, name, version, manifest_url, manifest, enabled, formatting, last_error, extension from addons order by position, id",
    )?;
    let out = st.query_map([], |r| {
        let url: String = r.get(3)?;
        let addon: Option<Addon> = serde_json::from_str(&r.get::<_, String>(4)?).ok();
        Ok(Row {
            id: r.get(0)?,
            name: r.get(1)?,
            version: r.get(2)?,
            address: preview(&url),
            resources: addon.as_ref().map(|a| a.resources.clone()).unwrap_or_default(),
            types: addon.as_ref().map(|a| a.types.clone()).unwrap_or_default(),
            enabled: r.get::<_, i64>(5)? != 0,
            formatting: r.get(6)?,
            last_error: r.get(7)?,
            extension: r.get(8)?,
            addon,
        })
    })?;
    Ok(out.collect::<rusqlite::Result<_>>()?)
}

pub(crate) fn labelled(a: &Addon) -> Addon {
    let mut a = a.clone();
    let local = url::Url::parse(&a.manifest_url)
        .ok()
        .is_some_and(|u| matches!(u.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")));
    if local && !a.name.ends_with("(this PC)") {
        a.name = format!("{} (this PC)", a.name);
    }
    a
}

pub(crate) fn insert(c: &Connection, a: &Addon) -> Result<i64> {
    let a = &labelled(a);
    let pos: i64 = c.query_row("select coalesce(max(position), 0) + 1 from addons", [], |r| r.get(0))?;
    c.execute(
        "insert into addons (manifest_url, addon_id, name, version, manifest, position, added)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         on conflict(manifest_url) do update set name = excluded.name, version = excluded.version, manifest = excluded.manifest",
        params![a.manifest_url, a.id, a.name, a.version, serde_json::to_string(a)?, pos, store::now()],
    )?;
    Ok(c.query_row("select id from addons where manifest_url = ?1", params![a.manifest_url], |r| r.get(0))?)
}

pub async fn list() -> Result<Vec<Row>> {
    store::with(rows).await
}

pub async fn add(url: &str) -> Result<Row> {
    let a = stremio::load_manifest(url).await?;
    anyhow::ensure!(
        a.usable(),
        "This addon doesn't offer anything Noonix TV can use"
    );
    let id = store::with(move |c| insert(c, &a)).await?;
    store::with(rows).await?.into_iter().find(|r| r.id == id).context("addon")
}

pub async fn remove(id: i64) -> Result<()> {
    store::with(move |c| {
        c.execute("delete from addons where id = ?1", params![id])?;
        store::cache_drop_prefix(c, &format!("streams:{id}:"))?;
        Ok(())
    })
    .await
}

pub async fn set_enabled(id: i64, on: bool) -> Result<()> {
    store::with(move |c| Ok(c.execute("update addons set enabled = ?2 where id = ?1", params![id, on as i64]).map(|_| ())?))
        .await
}

pub async fn reorder(ids: Vec<i64>) -> Result<()> {
    store::with(move |c| {
        for (i, id) in ids.iter().enumerate() {
            c.execute("update addons set position = ?2 where id = ?1", params![id, i as i64])?;
        }
        Ok(())
    })
    .await
}

/// reload the manifest and ask for a well-known title, so the user sees it work
pub async fn test(id: i64) -> Result<Value> {
    let row = store::with(rows).await?.into_iter().find(|r| r.id == id).context("no such addon")?;
    let mut a = row.addon.context("addon manifest missing")?;
    if let Ok(fresh) = stremio::load_manifest(&a.manifest_url).await {
        a = fresh.clone();
        store::with(move |c| insert(c, &fresh).map(|_| ())).await?;
    }
    if !a.resources.iter().any(|r| r == "stream") {
        return Ok(json!({ "ok": true, "streams": null }));
    }
    let t = Instant::now();
    // the shawshank redemption: every source has it
    let r = stremio::streams(&a, "movie", "tt0111161").await;
    let ms = t.elapsed().as_millis() as u64;
    let (ok, n, fmt, err) = match &r {
        Ok(list) => (true, list.len(), Some(stremio::formatting(list)), None),
        Err(e) => (false, 0, None, Some(redact(&format!("{e:#}")))),
    };
    record(id, fmt, err.clone()).await;
    Ok(json!({ "ok": ok, "streams": n, "ms": ms, "formatting": fmt, "error": err }))
}

async fn record(id: i64, fmt: Option<&'static str>, err: Option<String>) {
    let _ = store::with(move |c| {
        match fmt {
            Some(f) => c.execute("update addons set formatting = ?2, last_error = null where id = ?1", params![id, f])?,
            None => c.execute("update addons set last_error = ?2 where id = ?1", params![id, err])?,
        };
        Ok(())
    })
    .await;
}

pub fn formatter_template() -> Value {
    json!({ "name": stremio::NOONIX_FORMATTER_NAME, "description": stremio::NOONIX_FORMATTER_DESCRIPTION })
}

/// the user's own release patterns (settings › sources), install-wide
pub fn user_patterns(c: &rusqlite::Connection) -> (Vec<String>, Vec<String>) {
    let v = store::get_setting(c, "app", "patterns").ok().flatten().unwrap_or(Value::Null);
    let list = |k: &str| v.get(k).and_then(|x| serde_json::from_value::<Vec<String>>(x.clone()).ok()).unwrap_or_default();
    (list("preferred"), list("excluded"))
}

/// torrents allowed: None = never asked
pub fn torrents(c: &rusqlite::Connection) -> Option<bool> {
    store::get_setting(c, "app", "torrents").ok().flatten().and_then(|v| v.as_bool())
}

pub async fn prefs(profile: i64) -> Prefs {
    let (saved, balkan, langs, hdr, torrents, patterns) = store::with(move |c| {
        let (mut pre, mut exc) = user_patterns(c);
        let (ep, ee) = crate::extensions::patterns(c);
        pre.extend(ep);
        exc.extend(ee);
        Ok((
            store::get_setting(c, &format!("profile:{profile}"), "sources")?,
            store::get_setting(c, "app", "balkan_subs")?,
            store::get_setting(c, "app", "default_langs")?,
            store::get_setting(c, "app", "hdr_screen")?,
            torrents(c),
            (pre, exc),
        ))
    })
    .await
    .unwrap_or((None, None, None, None, None, (Vec::new(), Vec::new())));
    let quality = crate::quality::current().await.id.to_owned();
    let display = crate::ranking::screen(hdr.as_ref().and_then(Value::as_str));
    if let Some(mut p) = saved.and_then(|v| serde_json::from_value::<Prefs>(v).ok()) {
        p.quality = quality;
        p.display = display;
        p.torrents = torrents;
        (p.preferred, p.excluded) = patterns;
        return p;
    }
    // a new profile starts from the install's choices (setup's languages, balkan mode)
    let mut p = Prefs { display, ..Prefs::default() };
    if let Some(d) = langs {
        if let Ok(l) = serde_json::from_value::<Vec<String>>(d["languages"].clone()) {
            p.languages = l;
        }
        if let Ok(l) = serde_json::from_value::<Vec<String>>(d["subtitles"].clone()) {
            p.subtitles = l;
        }
    }
    if balkan.and_then(|v| v.as_bool()).unwrap_or(false) && !p.subtitles.iter().any(|l| l == "balkan") {
        p.subtitles.push("balkan".into());
    }
    p.quality = quality;
    p.torrents = torrents;
    (p.preferred, p.excluded) = patterns;
    p
}

/// the sources sheet never needs more than this; big unfiltered configs return thousands
const SHOWN: usize = 80;

pub struct Query {
    pub req: String,
    pub kind: String,
    pub tmdb: i64,
    pub season: Option<i64>,
    pub episode: Option<i64>,
}

#[derive(Serialize)]
struct AddonStatus {
    id: i64,
    name: String,
    state: &'static str, // loading | ok | error
    count: usize,
    ms: u64,
    formatting: Option<&'static str>,
    error: Option<String>,
}

/// asks every enabled stream addon at once; pushes "streams" after each answer
pub async fn streams(profile: i64, q: Query) -> Result<Value> {
    let d = tmdb::details(&q.kind, q.tmdb).await?;
    // the library's own files first; addons need the imdb id
    let local = {
        let (kind, tmdb, season, episode) = (q.kind.clone(), q.tmdb, q.season, q.episode);
        store::with(move |c| crate::library::streams(c, &kind, tmdb, season, episode)).await.unwrap_or_default()
    };
    let imdb = match d.get("imdb").and_then(Value::as_str) {
        Some(i) => i.to_owned(),
        None if !local.is_empty() => String::new(),
        None => anyhow::bail!("no imdb id for this title"),
    };
    let runtime = d.get("runtime").and_then(Value::as_f64);
    let original = d.get("originalLanguage").and_then(Value::as_str).map(str::to_owned);
    let want = ranking::Wanted {
        titles: d.get("titles").and_then(Value::as_array).map(|a| a.iter().filter_map(|t| t.as_str().map(str::to_owned)).collect()).unwrap_or_default(),
        year: d.get("year").and_then(Value::as_i64),
        learned: {
            let title = match (q.season, q.episode) {
                (Some(se), Some(ep)) if q.kind != "movie" => store::episode_key(q.tmdb, se, ep),
                _ => store::movie_key(q.tmdb),
            };
            let show = (q.kind != "movie").then_some(q.tmdb);
            store::with(move |c| crate::matches::learned(c, &title, show)).await.unwrap_or_default()
        },
    };
    let skind = if q.kind == "movie" { "movie" } else { "series" };
    let vid = stremio::video_id(&imdb, q.season, q.episode);

    let prefs = prefs(profile).await;
    let memory: Option<SourceMemory> = if q.kind == "show" {
        let show = q.tmdb;
        store::with(move |c| store::source_memory(c, profile, show)).await.ok().flatten()
    } else {
        None
    };

    let addons: Vec<Row> = list()
        .await?
        .into_iter()
        .filter(|r| !imdb.is_empty() && r.enabled && r.addon.as_ref().is_some_and(|a| a.provides("stream", skind, &vid)))
        .collect();
    let mut status: Vec<AddonStatus> = addons
        .iter()
        .map(|r| AddonStatus { id: r.id, name: r.name.clone(), state: "loading", count: 0, ms: 0, formatting: None, error: None })
        .collect();

    let mut pending: FuturesUnordered<_> = addons
        .into_iter()
        .enumerate()
        .map(|(pos, r)| {
            let (vid, skind) = (vid.clone(), skind.to_owned());
            async move {
                let a = r.addon.expect("filtered");
                let t = Instant::now();
                crate::local::ready(&a.manifest_url).await;
                let res = cached_streams(r.id, &a, &skind, &vid).await.map(|mut list| {
                    for (i, s) in list.iter_mut().enumerate() {
                        s.order = (pos, i);
                    }
                    list
                });
                (r.id, t.elapsed().as_millis() as u64, res)
            }
        })
        .collect();

    // external subtitles per release, looked up next to the addons; a stream list that comes
    // first ranks without them until they're here
    let sub_sets = ranking::expand(&prefs.subtitles, original.as_deref());
    let mut sub_task = (!pending.is_empty()).then(|| tokio::spawn({
        let (imdb, langs, original) = (imdb.clone(), prefs.subtitles.clone(), original.clone());
        let (season, episode) = (q.season, q.episode);
        async move { crate::subtitles::pool(&imdb, season, episode, &langs, original.as_deref()).await }
    }));
    let mut sub_pool: Option<Vec<(String, Value)>> = None;
    let mut fitted = 0;

    let mut all: Vec<Stream> = local;
    let mut ranked = ranking::Ranked::default();
    let asked = prefs.torrents;
    if pending.is_empty() {
        ranked = ranking::rank(all, &prefs, original.as_deref(), memory.as_ref(), runtime, &want);
        let out = json!({ "req": q.req, "done": true, "streams": ranked.streams, "total": ranked.streams.len(), "hidden": ranked.hidden,
                          "torrents": ranked.torrents, "torrentsAllowed": asked, "addons": status });
        return Ok(out);
    }
    while let Some((id, ms, res)) = pending.next().await {
        let st = status.iter_mut().find(|s| s.id == id).expect("addon status");
        st.ms = ms;
        match res {
            Ok(list) => {
                let fmt = stremio::formatting(&list);
                st.state = "ok";
                st.count = list.len();
                st.formatting = Some(fmt);
                record(id, Some(fmt), None).await;
                all.extend(list);
            }
            Err(e) => {
                let msg = redact(&format!("{e:#}"));
                tracing::warn!("streams {}: {msg}", st.name);
                st.state = "error";
                st.error = Some(msg.clone());
                record(id, None, Some(msg)).await;
            }
        }
        let done = pending.is_empty();
        if sub_pool.is_none() && (done || sub_task.as_ref().is_some_and(|t| t.is_finished())) {
            if let Some(t) = sub_task.take() {
                sub_pool = Some(tokio::time::timeout(Duration::from_secs(4), t).await.ok().and_then(Result::ok).unwrap_or_default());
            }
        }
        if let Some(pool) = &sub_pool {
            for s in &mut all[fitted..] {
                s.ext_subs = crate::subtitles::fits(pool, &sub_sets, &crate::subtitles::Release::of(s));
            }
            fitted = all.len();
        }
        ranked = ranking::rank(all.clone(), &prefs, original.as_deref(), memory.as_ref(), runtime, &want);
        let payload = json!({
            "req": q.req,
            "done": done,
            "streams": &ranked.streams[..ranked.streams.len().min(SHOWN)],
            "total": ranked.streams.len(),
            "hidden": ranked.hidden,
            "torrents": ranked.torrents,
            "torrentsAllowed": asked,
            "addons": status,
        });
        if !done {
            app::emit("streams", payload);
        } else {
            return Ok(payload);
        }
    }
    Ok(json!({ "req": q.req, "done": true, "streams": ranked.streams, "total": ranked.streams.len(), "hidden": ranked.hidden, "torrents": ranked.torrents, "torrentsAllowed": asked, "addons": status }))
}

// stream urls carry short-lived tokens: keep them only for a few minutes
async fn cached_streams(row: i64, a: &Addon, kind: &str, vid: &str) -> Result<Vec<Stream>> {
    let key = format!("streams:{row}:{vid}");
    let k = key.clone();
    if let Ok(Some(hit)) = store::with(move |c| store::cache_get(c, &k)).await {
        if let Ok(v) = serde_json::from_str::<Vec<Value>>(&hit) {
            return Ok(v.iter().filter_map(|s| stremio::normalize(&a.name, s)).collect());
        }
    }
    let raw = stremio::raw_streams(a, kind, vid).await?;
    // an empty answer is mostly a scraper that timed out: ask again next time
    if !raw.is_empty() {
        let text = serde_json::to_string(&raw)?;
        let _ = store::with(move |c| store::cache_put(c, &key, &text, 600)).await;
    }
    Ok(raw.iter().filter_map(|s| stremio::normalize(&a.name, s)).collect())
}

pub async fn remember(profile: i64, show: i64, s: &Stream) -> Result<()> {
    let m = SourceMemory {
        provider: s.group.clone(),
        resolution: (s.resolution > 0).then(|| s.resolution.to_string()),
        binge_group: s.binge_group.clone(),
    };
    store::with(move |c| store::set_source_memory(c, profile, show, &m)).await
}
