use crate::store;
use crate::tmdb;
use crate::trakt::Account;
use anyhow::{bail, Result};
use serde_json::{json, Value};

/// the kodi home rows, in kodi's order
pub fn rows() -> Value {
    json!([
        { "id": "upnext",        "title": "Up Next",          "style": "episode" },
        { "id": "continue",      "title": "Continue Watching", "style": "landscape" },
        { "id": "recent",        "title": "Recently Played",  "style": "poster" },
        { "id": "library",       "title": "On This PC",       "style": "poster" },
        { "id": "popular-tv",    "title": "Popular TV Shows", "style": "poster" },
        { "id": "popular-movie", "title": "Popular Movies",   "style": "poster" },
        { "id": "netflix-tv",    "title": "Netflix Shows",    "style": "poster", "brand": "netflix" },
        { "id": "netflix-movie", "title": "Netflix Movies",   "style": "poster", "brand": "netflix" },
        { "id": "max-tv",        "title": "Max Shows",        "style": "poster", "brand": "max" },
        { "id": "max-movie",     "title": "Max Movies",       "style": "poster", "brand": "max" },
    ])
}

pub fn movie_rows() -> Value {
    json!([
        { "id": "continue-movie", "title": "Continue Watching", "style": "landscape" },
        { "id": "library-movie",  "title": "On This PC",        "style": "poster" },
        { "id": "popular-movie",  "title": "Popular",           "style": "poster" },
        { "id": "trending-movie", "title": "Trending",          "style": "poster" },
        { "id": "netflix-movie",  "title": "Netflix",           "style": "poster", "brand": "netflix" },
        { "id": "max-movie",      "title": "Max",               "style": "poster", "brand": "max" },
        { "id": "genre-movie-28", "title": "Action",            "style": "poster" },
        { "id": "genre-movie-35", "title": "Comedy",            "style": "poster" },
        { "id": "genre-movie-53", "title": "Thriller",          "style": "poster" },
        { "id": "genre-movie-878","title": "Science Fiction",   "style": "poster" },
        { "id": "genre-movie-16", "title": "Animation",         "style": "poster" },
    ])
}

pub fn show_rows() -> Value {
    json!([
        { "id": "upnext",        "title": "Up Next",        "style": "episode" },
        { "id": "library-show",  "title": "On This PC",     "style": "poster" },
        { "id": "popular-tv",    "title": "Popular",        "style": "poster" },
        { "id": "trending-tv",   "title": "Trending",       "style": "poster" },
        { "id": "netflix-tv",    "title": "Netflix",        "style": "poster", "brand": "netflix" },
        { "id": "max-tv",        "title": "Max",            "style": "poster", "brand": "max" },
        { "id": "genre-tv-18",   "title": "Drama",          "style": "poster" },
        { "id": "genre-tv-35",   "title": "Comedy",         "style": "poster" },
        { "id": "genre-tv-80",   "title": "Crime",          "style": "poster" },
        { "id": "genre-tv-10765","title": "Sci-Fi & Fantasy","style": "poster" },
        { "id": "genre-tv-16",   "title": "Animation",      "style": "poster" },
    ])
}

pub async fn row(profile: i64, id: &str) -> Result<Value> {
    let kind = |k: &str| if k == "tv" { "show" } else { "movie" };
    if profile == 0 && matches!(id, "upnext" | "continue" | "continue-movie" | "recent") {
        return Ok(json!([]));
    }
    Ok(match id {
        "upnext" => up_next(profile).await?,
        "continue" => continue_watching(profile, None).await?,
        "continue-movie" => continue_watching(profile, Some("movie")).await?,
        "recent" => recently_played(profile).await?,
        "library" => Value::Array(enrich_all(crate::library::items(None).await?).await),
        "library-movie" => Value::Array(enrich_all(crate::library::items(Some("movie")).await?).await),
        "library-show" => Value::Array(enrich_all(crate::library::items(Some("show")).await?).await),
        _ => {
            let parts: Vec<&str> = id.split('-').collect();
            match parts.as_slice() {
                ["popular", k] => tmdb::popular(kind(k), 1).await?,
                ["trending", k] => tmdb::trending(kind(k)).await?,
                ["toprated", k] => tmdb::top_rated(kind(k)).await?,
                // tmdb watch providers: 8 netflix, 1899 max
                ["netflix", k] => tmdb::discover(kind(k), &[8], None, 1).await?,
                ["max", k] => tmdb::discover(kind(k), &[1899], None, 1).await?,
                ["genre", k, g] => tmdb::discover(kind(k), &[], g.parse().ok(), 1).await?,
                _ => bail!("unknown row {id}"),
            }
        }
    })
}

/// still, show art and runtime for an episode card
async fn enrich_episode(mut e: Value) -> Value {
    let Some(show) = e.get("show").and_then(Value::as_i64) else { return e };
    let season = e.get("season").and_then(Value::as_i64).unwrap_or(0);
    let number = e.get("episode").and_then(Value::as_i64).unwrap_or(0);
    let (art, season_v) = tokio::join!(tmdb::art("show", show), tmdb::season(show, season));
    let o = e.as_object_mut().unwrap();
    if let Ok(a) = art {
        for k in ["poster", "backdrop", "genres", "rating", "overview", "title"] {
            if let Some(v) = a.get(k) {
                let key = if k == "title" { "showTitle" } else if k == "overview" { "showOverview" } else { k };
                if o.get(key).is_none_or(Value::is_null) {
                    o.insert(key.into(), v.clone());
                }
            }
        }
    }
    if let Ok(sv) = season_v {
        if let Some(ep) = sv
            .get("episodes")
            .and_then(Value::as_array)
            .and_then(|a| a.iter().find(|x| x.get("episode").and_then(Value::as_i64) == Some(number)))
        {
            for k in ["still", "runtime", "overview", "airDate", "episodeTitle"] {
                if let Some(v) = ep.get(k) {
                    if o.get(k).is_none_or(Value::is_null) {
                        o.insert(k.into(), v.clone());
                    }
                }
            }
        }
    }
    e
}

async fn enrich_all(items: Vec<Value>) -> Vec<Value> {
    use futures::stream::{self, StreamExt};
    stream::iter(items)
        .map(|it| async move {
            let kind = it.get("kind").and_then(Value::as_str).unwrap_or("").to_owned();
            match kind.as_str() {
                "episode" => enrich_episode(it).await,
                "movie" | "show" => enrich_title(&kind, it).await,
                _ => it,
            }
        })
        .buffered(8)
        .collect()
        .await
}

async fn enrich_title(kind: &str, mut it: Value) -> Value {
    let Some(id) = it.get("id").and_then(Value::as_i64) else { return it };
    if let Ok(a) = tmdb::art(kind, id).await {
        let o = it.as_object_mut().unwrap();
        for (k, v) in a {
            if o.get(&k).is_none_or(Value::is_null) {
                o.insert(k, v);
            }
        }
    }
    it
}

/// local progress overrides trakt's (it is newer while noonix tv is the player)
fn merge_local(items: &mut [Value], local: &[store::Progress]) {
    for it in items.iter_mut() {
        let key = match it.get("kind").and_then(Value::as_str) {
            Some("episode") => store::episode_key(
                it.get("show").and_then(Value::as_i64).unwrap_or(0),
                it.get("season").and_then(Value::as_i64).unwrap_or(0),
                it.get("episode").and_then(Value::as_i64).unwrap_or(0),
            ),
            Some("movie") => store::movie_key(it.get("id").and_then(Value::as_i64).unwrap_or(0)),
            _ => continue,
        };
        if let Some(p) = local.iter().find(|p| p.key == key) {
            if p.duration > 0.0 {
                it["progress"] = json!(p.position / p.duration);
                it["position"] = json!(p.position);
                it["duration"] = json!(p.duration);
            }
        }
    }
}

async fn dismissed(profile: i64) -> Vec<String> {
    store::with(move |c| store::get_setting(c, &format!("profile:{profile}"), "dismissed"))
        .await
        .ok()
        .flatten()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default()
}

fn dismiss_key(it: &Value) -> String {
    match it.get("kind").and_then(Value::as_str) {
        Some("episode") => format!("show:{}", it.get("show").and_then(Value::as_i64).unwrap_or(0)),
        Some(k) => format!("{k}:{}", it.get("id").and_then(Value::as_i64).unwrap_or(0)),
        None => String::new(),
    }
}

pub async fn up_next(profile: i64) -> Result<Value> {
    let local = store::with(move |c| store::in_progress(c, profile, 200)).await?;
    let gone = dismissed(profile).await;
    let mut items = match Account::for_profile(profile).await? {
        Some(acc) => acc.up_next(20).await?,
        None => local_up_next(profile).await?,
    };
    items.retain(|it| !gone.contains(&dismiss_key(it)));
    merge_local(&mut items, &local);
    // the show watched last comes first: trakt's watch / pause or noonix tv's own play, whichever is newer
    let recent = store::with(move |c| store::recent_shows(c, profile, 200)).await.unwrap_or_default();
    for it in items.iter_mut() {
        let show = it.get("show").and_then(Value::as_i64).unwrap_or(0);
        let ours = recent.iter().find(|r| r.0 == show).map(|r| r.3).unwrap_or(0);
        let theirs = it.get("lastActivity").and_then(Value::as_i64).unwrap_or(0);
        it["lastActivity"] = json!(ours.max(theirs));
    }
    items.sort_by_key(|it| std::cmp::Reverse(it.get("lastActivity").and_then(Value::as_i64).unwrap_or(0)));
    Ok(Value::Array(enrich_all(items).await))
}

/// next unwatched episode of locally watched shows (profiles without trakt)
async fn local_up_next(profile: i64) -> Result<Vec<Value>> {
    let recent = store::with(move |c| store::recent_shows(c, profile, 20)).await?;
    let mut out = Vec::new();
    for (show, season, episode, _) in recent {
        let key = store::episode_key(show, season, episode);
        let done = store::with(move |c| Ok(store::get_progress(c, profile, &key)?.is_some_and(|p| p.completed))).await?;
        let (s, e) = if done { next_episode(show, season, episode).await.unwrap_or((0, 0)) } else { (season, episode) };
        if s > 0 {
            out.push(json!({ "kind": "episode", "show": show, "season": s, "episode": e }));
        }
    }
    Ok(out)
}

/// next aired episode after s/e, rolling into the next season
pub async fn next_episode(show: i64, season: i64, episode: i64) -> Option<(i64, i64)> {
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let aired = |e: &Value| e.get("airDate").and_then(Value::as_str).is_some_and(|d| d <= today.as_str());
    let cur = tmdb::season(show, season).await.ok()?;
    if let Some(n) = cur
        .get("episodes")
        .and_then(Value::as_array)?
        .iter()
        .find(|e| e.get("episode").and_then(Value::as_i64) == Some(episode + 1) && aired(e))
    {
        return Some((season, n.get("episode").and_then(Value::as_i64)?));
    }
    let next = tmdb::season(show, season + 1).await.ok()?;
    let first = next.get("episodes").and_then(Value::as_array)?.first()?;
    aired(first).then_some((season + 1, first.get("episode").and_then(Value::as_i64)?))
}

pub async fn continue_watching(profile: i64, only: Option<&str>) -> Result<Value> {
    let local = store::with(move |c| store::in_progress(c, profile, 50)).await?;
    let gone = dismissed(profile).await;
    let mut items: Vec<Value> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // local first: noonix tv's own plays are the freshest
    for p in &local {
        let it = if p.kind == "movie" {
            json!({ "kind": "movie", "id": p.tmdb, "progress": p.position / p.duration.max(1.0), "position": p.position, "duration": p.duration })
        } else {
            json!({ "kind": "episode", "show": p.tmdb, "season": p.season, "episode": p.episode,
                    "progress": p.position / p.duration.max(1.0), "position": p.position, "duration": p.duration })
        };
        if seen.insert(p.key.clone()) {
            items.push(it);
        }
    }
    if let Some(acc) = Account::for_profile(profile).await? {
        for it in acc.playback().await.unwrap_or_default() {
            let key = match it.get("kind").and_then(Value::as_str) {
                Some("movie") => store::movie_key(it.get("id").and_then(Value::as_i64).unwrap_or(0)),
                _ => store::episode_key(
                    it.get("show").and_then(Value::as_i64).unwrap_or(0),
                    it.get("season").and_then(Value::as_i64).unwrap_or(0),
                    it.get("episode").and_then(Value::as_i64).unwrap_or(0),
                ),
            };
            if seen.insert(key) {
                items.push(it);
            }
        }
    }
    // trakt keeps old paused episodes forever: drop the ones behind the show's up next
    let next: Vec<(i64, i64, i64)> = up_next(profile)
        .await
        .ok()
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|e| Some((e.get("show")?.as_i64()?, e.get("season")?.as_i64()?, e.get("episode")?.as_i64()?)))
        .collect();
    items.retain(|it| {
        if it.get("kind").and_then(Value::as_str) != Some("episode") {
            return true;
        }
        let (show, s, e) = (
            it.get("show").and_then(Value::as_i64).unwrap_or(0),
            it.get("season").and_then(Value::as_i64).unwrap_or(0),
            it.get("episode").and_then(Value::as_i64).unwrap_or(0),
        );
        !next.iter().any(|(ns, nse, nep)| *ns == show && (s, e) < (*nse, *nep))
    });
    items.retain(|it| {
        let p = it.get("progress").and_then(Value::as_f64).unwrap_or(0.0);
        (0.02..0.92).contains(&p)
            && !gone.contains(&dismiss_key(it))
            && only.is_none_or(|k| it.get("kind").and_then(Value::as_str) == Some(k))
    });
    items.truncate(20);
    Ok(Value::Array(enrich_all(items).await))
}

pub async fn recently_played(profile: i64) -> Result<Value> {
    let gone = dismissed(profile).await;
    let mut items = match Account::for_profile(profile).await? {
        Some(acc) => acc.shows_in_progress(20).await?,
        None => {
            let recent = store::with(move |c| store::recent_shows(c, profile, 20)).await?;
            recent.into_iter().map(|(show, ..)| json!({ "kind": "show", "id": show })).collect()
        }
    };
    items.retain(|it| !gone.contains(&dismiss_key(it)));
    Ok(Value::Array(enrich_all(items).await))
}

/// remove from up next / recently played / continue watching (trakt + local)
pub async fn dismiss(profile: i64, item: &Value, undo: bool, sync: bool) -> Result<()> {
    let key = dismiss_key(item);
    let mut gone = dismissed(profile).await;
    if undo {
        gone.retain(|k| k != &key);
    } else if !gone.contains(&key) {
        gone.push(key);
    }
    let v = json!(gone);
    store::with(move |c| store::set_setting(c, &format!("profile:{profile}"), "dismissed", &v)).await?;
    // the ui commits to trakt only once its undo window has passed
    if !sync {
        return Ok(());
    }
    if let Some(acc) = Account::for_profile(profile).await? {
        if let Some(pid) = item.get("playbackId").and_then(Value::as_i64) {
            if !undo {
                acc.remove_playback(pid).await?;
            }
        } else if let Some(show) = item.get("show").and_then(Value::as_i64).or_else(|| {
            (item.get("kind").and_then(Value::as_str) == Some("show")).then(|| item.get("id").and_then(Value::as_i64)).flatten()
        }) {
            acc.hide_show(show, !undo).await?;
        }
    }
    Ok(())
}

/// in the library = noonix tv's watchlist or the profile's trakt watchlist
pub async fn in_library(profile: i64, kind: &str, tmdb: i64) -> Result<bool> {
    validate_library_target(kind, tmdb)?;
    let kind = kind.to_owned();
    let k = kind.clone();
    let local = store::with(move |c| store::watchlist(c, profile)).await?;
    if local.iter().any(|(lk, id)| *lk == k && *id == tmdb) {
        return Ok(true);
    }
    if let Some(acc) = Account::for_profile(profile).await? {
        let list = acc.watchlist().await?;
        return Ok(list.iter().any(|w| w.get("kind").and_then(Value::as_str) == Some(&kind) && w.get("id").and_then(Value::as_i64) == Some(tmdb)));
    }
    Ok(false)
}

/// trakt first: when it refuses, nothing changes here either
pub async fn set_library(profile: i64, kind: &str, tmdb: i64, on: bool) -> Result<()> {
    validate_library_target(kind, tmdb)?;
    if let Some(acc) = Account::for_profile(profile).await? {
        acc.set_watchlist(kind, tmdb, on).await?;
    }
    let kind = kind.to_owned();
    store::with(move |c| store::set_watchlist(c, profile, &kind, tmdb, on)).await?;
    Ok(())
}

fn validate_library_target(kind: &str, tmdb: i64) -> Result<()> {
    if !matches!(kind, "movie" | "show") || tmdb <= 0 {
        bail!("invalid library title");
    }
    Ok(())
}

pub async fn library(profile: i64, section: &str) -> Result<Value> {
    let mut items = match section {
        "watchlist" => store::with(move |c| store::watchlist(c, profile))
            .await?
            .into_iter()
            .map(|(kind, id)| json!({ "kind": kind, "id": id }))
            .collect(),
        "history" => store::with(move |c| store::history(c, profile, 100)).await?,
        // the files on this pc: no trakt side
        "files" => return Ok(json!({ "items": enrich_all(crate::library::items(None).await?).await, "traktUnavailable": false })),
        _ => bail!("unknown library section"),
    };
    let mut unavailable = false;
    if let Some(acc) = Account::for_profile(profile).await? {
        let remote = if section == "history" { acc.history().await } else { acc.watchlist().await };
        match remote {
            Ok(remote) => items.extend(remote),
            Err(e) if items.is_empty() => return Err(e),
            Err(_) => unavailable = true,
        }
    }
    let items = merge_library(items, section == "history");
    Ok(json!({ "items": enrich_all(items).await, "traktUnavailable": unavailable }))
}

fn merge_library(mut items: Vec<Value>, history: bool) -> Vec<Value> {
    if history {
        items.sort_by_key(|it| std::cmp::Reverse(it.get("watchedAt").and_then(Value::as_i64).unwrap_or(0)));
    }
    let mut seen = std::collections::HashSet::new();
    items.retain(|it| {
        let kind = it.get("kind").and_then(Value::as_str).unwrap_or("");
        let id = it.get(if kind == "episode" { "show" } else { "id" }).and_then(Value::as_i64).unwrap_or(0);
        let s = it.get("season").and_then(Value::as_i64).unwrap_or(0);
        let e = it.get("episode").and_then(Value::as_i64).unwrap_or(0);
        id > 0 && matches!(kind, "movie" | "show" | "episode") && seen.insert((kind.to_owned(), id, s, e))
    });
    if history {
        items.truncate(100);
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_keeps_media_types_and_distinct_episodes() {
        let items = vec![
            json!({"kind":"show","id":1}), json!({"kind":"movie","id":1}),
            json!({"kind":"show","id":1}), json!({"kind":"show","id":null}),
            json!({"kind":"episode","show":1,"season":1,"episode":1,"watchedAt":5}),
            json!({"kind":"episode","show":1,"season":1,"episode":1,"watchedAt":10}),
            json!({"kind":"episode","show":1,"season":1,"episode":2,"watchedAt":7}),
        ];
        let merged = merge_library(items, true);
        assert_eq!(merged.len(), 4);
        assert_eq!(merged[0]["watchedAt"], 10);
        assert_eq!(merged[1]["episode"], 2);
        assert!(validate_library_target("episode", 1).is_err());
        assert!(validate_library_target("show", 0).is_err());
    }

    #[test]
    fn local_progress_wins() {
        let p = |key: &str, position: f64, duration: f64| store::Progress {
            key: key.into(), kind: String::new(), tmdb: 0, imdb: None, season: None, episode: None, title: None,
            position, duration, completed: false, updated: 0,
        };
        let mut items = vec![
            json!({ "kind": "episode", "show": 85552, "season": 3, "episode": 4, "progress": 0.1 }),
            json!({ "kind": "movie", "id": 603, "progress": 0.2 }),
            json!({ "kind": "movie", "id": 604, "progress": 0.3 }),
            json!({ "kind": "show", "id": 1 }),
        ];
        let local = vec![p(&store::episode_key(85552, 3, 4), 1800.0, 3600.0), p(&store::movie_key(603), 10.0, 0.0)];
        merge_local(&mut items, &local);
        assert_eq!(items[0]["progress"], json!(0.5));
        assert_eq!(items[0]["position"], json!(1800.0));
        // no duration yet: keep trakt's
        assert_eq!(items[1]["progress"], json!(0.2));
        assert_eq!(items[2]["progress"], json!(0.3));
        assert!(items[3].get("progress").is_none());
    }

    #[test]
    fn dismiss_keys() {
        // an episode hides its whole show from the row
        assert_eq!(dismiss_key(&json!({ "kind": "episode", "show": 85552, "season": 3 })), "show:85552");
        assert_eq!(dismiss_key(&json!({ "kind": "movie", "id": 603 })), "movie:603");
        assert_eq!(dismiss_key(&json!({})), "");
    }
}
