// a profile's login: "own" = noonix tv signs in (device code) and refreshes it, the token lives
// in the database; "none" = no trakt
use crate::config::{self, keys, PATHS};
use crate::http::{self, Req};
use crate::store;
use anyhow::{anyhow, bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;

const API: &str = "https://api.trakt.tv";
// access tokens live 24 h (old apps since 2025-03) to 7 days (noonix tv's app): the daily keepalive
// refreshes them within 12 h of the end, a call refreshes one that runs out within minutes
const REFRESH_MARGIN: i64 = 12 * 3600;
const CALL_MARGIN: i64 = 600;
// a refresh token works once: one refresh at a time, the next one sees the new token
static REFRESHING: once_cell::sync::Lazy<tokio::sync::Mutex<()>> = once_cell::sync::Lazy::new(|| tokio::sync::Mutex::new(()));

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Token {
    pub access_token: String,
    pub refresh_token: String,
    #[serde(default)]
    pub expires_in: i64,
    #[serde(default)]
    pub created_at: i64,
    #[serde(default)]
    pub expires_at: Option<i64>,
    #[serde(default)]
    pub token_type: Option<String>,
    #[serde(default)]
    pub scope: Option<String>,
    /// the trakt app that issued it (a token only works with its own app)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
}

impl Token {
    pub fn expires(&self) -> i64 {
        self.expires_at.unwrap_or(self.created_at + self.expires_in)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    None,
    Own,
}

impl Mode {
    pub fn parse(s: &str) -> Mode {
        match s {
            "own" => Mode::Own,
            _ => Mode::None,
        }
    }
}

// older builds kept a profile's own login in a file
fn own_token_file(profile: i64) -> PathBuf {
    PATHS.data.join(format!("trakt-{profile}.json"))
}

fn own_token_key(profile: i64) -> String {
    format!("TRAKT_TOKEN_{profile}")
}

pub fn read_token(mode: Mode, profile: i64) -> Option<Token> {
    match mode {
        Mode::Own => {
            if let Some(t) = config::stored(&own_token_key(profile)) {
                return serde_json::from_str(&t).ok();
            }
            let file = own_token_file(profile);
            let mut t: Token = serde_json::from_str(&std::fs::read_to_string(&file).ok()?).ok()?;
            // before built-in keys, only the imported app could have issued it
            if t.client_id.is_none() {
                t.client_id = config::stored(keys::TRAKT_CLIENT_ID);
            }
            if save_token(Mode::Own, profile, &t).is_ok() {
                let _ = std::fs::remove_file(&file);
            }
            Some(t)
        }
        Mode::None => None,
    }
}

fn save_token(mode: Mode, profile: i64, t: &Token) -> Result<()> {
    match mode {
        Mode::Own => config::set_secrets(&[(&own_token_key(profile), Some(serde_json::to_string(t)?))]),
        Mode::None => Ok(()),
    }
}

pub fn forget_token(profile: i64) -> Result<()> {
    let _ = std::fs::remove_file(own_token_file(profile));
    config::set_secrets(&[(&own_token_key(profile), None)])
}

fn dry_run() -> bool {
    std::env::var("NOONIX_TRAKT_DRY_RUN").is_ok_and(|v| v != "0")
}

/// the trakt app for a login: the one that issued the token, else noonix tv's built-in app
fn app_keys(_mode: Mode, token: Option<&Token>) -> Result<(String, String)> {
    let pick = |key: &str| config::secret(key);
    let id = token.and_then(|t| t.client_id.clone()).or_else(|| pick(keys::TRAKT_CLIENT_ID)).ok_or_else(|| anyhow!("no trakt app id"))?;
    // a token from the built-in app needs the built-in secret
    let secret = if config::builtin(keys::TRAKT_CLIENT_ID) == Some(id.as_str()) {
        config::builtin(keys::TRAKT_CLIENT_SECRET).map(str::to_owned)
    } else if config::stored(keys::TRAKT_CLIENT_ID).as_deref() == Some(id.as_str()) {
        config::stored(keys::TRAKT_CLIENT_SECRET)
    } else {
        pick(keys::TRAKT_CLIENT_SECRET)
    };
    Ok((id, secret.unwrap_or_default()))
}

fn client_id() -> Result<String> {
    app_keys(Mode::Own, None).map(|k| k.0)
}

pub struct Account {
    pub profile: i64,
    pub mode: Mode,
}

impl Account {
    pub async fn for_profile(profile: i64) -> Result<Option<Account>> {
        let mode = store::with(move |c| {
            Ok(store::profiles(c)?.into_iter().find(|p| p.id == profile).map(|p| Mode::parse(&p.trakt)))
        })
        .await?
        .unwrap_or(Mode::None);
        if mode == Mode::None || read_token(mode, profile).is_none() {
            return Ok(None);
        }
        Ok(Some(Account { profile, mode }))
    }

    fn token(&self) -> Result<Token> {
        read_token(self.mode, self.profile).ok_or_else(|| anyhow!("trakt token missing"))
    }

    fn req(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> Result<Req> {
        let token = self.token()?;
        let mut r = match body {
            Some(b) => Req::post(format!("{API}{path}"), b),
            None => Req::get(format!("{API}{path}")),
        };
        r.method = method;
        Ok(r.header("trakt-api-version", "2")
            .header("trakt-api-key", &app_keys(self.mode, Some(&token))?.0)
            .header("authorization", &format!("Bearer {}", token.access_token))
            .header("content-type", "application/json"))
    }

    /// logins refresh themselves shortly before they run out
    async fn fresh(&self, margin: i64) {
        if self.mode == Mode::Own {
            if let Err(e) = refresh_within(Mode::Own, self.profile, margin).await {
                tracing::warn!("trakt refresh: {e:#}");
                // trakt refused the login itself (revoked, expired for good): this profile signs in again
                if e.downcast_ref::<http::HttpError>().is_some_and(|h| matches!(h.status(), 400 | 401)) {
                    let profile = self.profile;
                    let _ = store::with(move |c| store::set_setting(c, &format!("profile:{profile}"), "trakt_relogin", &serde_json::json!(true))).await;
                }
            }
        }
    }

    /// one more try after a 401 with a refreshed token
    async fn send(&self, method: reqwest::Method, path: &str, body: Option<Value>, ttl: i64) -> Result<Value> {
        self.fresh(CALL_MARGIN).await;
        let key = format!("trakt:{}:{path}", self.profile);
        let key = &key;
        let once = |req: Req| async move { if ttl > 0 { http::cached_json(key, ttl, req).await } else { http::json(&req).await } };
        match once(self.req(method.clone(), path, body.clone())?).await {
            Err(e) if self.mode == Mode::Own && e.downcast_ref::<http::HttpError>().is_some_and(|h| h.status() == 401) => {
                self.fresh(i64::MAX).await;
                once(self.req(method, path, body)?).await
            }
            r => r,
        }
    }

    async fn get(&self, path: &str, ttl: i64) -> Result<Value> {
        self.send(reqwest::Method::GET, path, None, ttl).await
    }

    async fn post(&self, path: &str, body: Value) -> Result<Value> {
        if dry_run() {
            tracing::info!("trakt dry run: POST {path} {body}");
            return Ok(json!({ "dry_run": true }));
        }
        self.send(reqwest::Method::POST, path, Some(body), 0).await
    }

    /// drop cached lists after our own scrobbles
    pub async fn invalidate(&self) {
        let prefix = format!("trakt:{}:", self.profile);
        let _ = store::with(move |c| store::cache_drop_prefix(c, &prefix)).await;
    }

    // ---- reads

    /// next episode per recently watched show, newest activity first (kodi's up next order:
    /// max(last watched, the next episode's paused_at))
    pub async fn up_next(&self, limit: usize) -> Result<Vec<Value>> {
        let watched = self.get("/sync/watched/shows?extended=noseasons", 600).await?;
        let hidden = self.get("/users/hidden/progress_watched?type=show&limit=1000", 3600).await.unwrap_or(Value::Null);
        let hidden_ids: Vec<i64> = hidden
            .as_array()
            .map(|a| a.iter().filter_map(|h| h.pointer("/show/ids/trakt").and_then(Value::as_i64)).collect())
            .unwrap_or_default();
        let paused = self.get("/sync/playback/episodes?limit=100", 120).await.unwrap_or(Value::Null);

        let mut shows: Vec<&Value> = watched
            .as_array()
            .map(|a| {
                a.iter()
                    .filter(|s| {
                        s.pointer("/show/ids/trakt").and_then(Value::as_i64).is_some_and(|id| !hidden_ids.contains(&id))
                    })
                    .collect()
            })
            .unwrap_or_default();
        shows.sort_by(|a, b| {
            let la = a.get("last_watched_at").and_then(Value::as_str).unwrap_or("");
            let lb = b.get("last_watched_at").and_then(Value::as_str).unwrap_or("");
            lb.cmp(la)
        });
        shows.truncate(limit + 10);

        let jobs: Vec<(i64, Value, String)> = shows
            .iter()
            .map(|s| {
                (
                    s.pointer("/show/ids/trakt").and_then(Value::as_i64).unwrap_or(0),
                    s.get("show").cloned().unwrap_or(Value::Null),
                    s.get("last_watched_at").and_then(Value::as_str).unwrap_or("").to_owned(),
                )
            })
            .collect();
        let found: Vec<(Value, Value, String)> = {
            use futures::stream::{self, StreamExt};
            // bounded so trakt's rate limit is never hit
            let futs: Vec<_> = jobs
                .into_iter()
                .map(|(trakt_id, show, last)| {
                    let path = format!("/shows/{trakt_id}/progress/watched?hidden=false&specials=false&count_specials=false");
                    let req = self.req(reqwest::Method::GET, &path, None);
                    let key = format!("trakt:{}:{path}", self.profile);
                    async move {
                        let p = http::cached_json(&key, 600, req.ok()?).await.ok()?;
                        let next = p.get("next_episode").filter(|n| !n.is_null())?.clone();
                        Some((show, next, last))
                    }
                })
                .collect();
            stream::iter(futs).buffered(6).collect::<Vec<_>>().await.into_iter().flatten().collect()
        };

        let mut out: Vec<(String, Value)> = Vec::new();
        for (show, next, last) in found {
            let season = next.get("season").and_then(Value::as_i64).unwrap_or(0);
            let number = next.get("number").and_then(Value::as_i64).unwrap_or(0);
            let show_trakt = show.pointer("/ids/trakt").and_then(Value::as_i64);
            let paused_at = paused.as_array().and_then(|a| {
                a.iter().find(|p| {
                    p.pointer("/show/ids/trakt").and_then(Value::as_i64) == show_trakt
                        && p.pointer("/episode/season").and_then(Value::as_i64) == Some(season)
                        && p.pointer("/episode/number").and_then(Value::as_i64) == Some(number)
                })
            });
            let sort = paused_at
                .and_then(|p| p.get("paused_at").and_then(Value::as_str))
                .map(str::to_owned)
                .filter(|p| p.as_str() > last.as_str())
                .unwrap_or(last);
            let progress = paused_at.and_then(|p| p.get("progress").and_then(Value::as_f64)).unwrap_or(0.0);
            let when = chrono::DateTime::parse_from_rfc3339(&sort).map(|d| d.timestamp()).unwrap_or(0);
            out.push((
                sort,
                json!({
                    "kind": "episode",
                    "show": show.pointer("/ids/tmdb"),
                    "showImdb": show.pointer("/ids/imdb"),
                    "showTitle": show.get("title"),
                    "year": show.get("year"),
                    "season": season,
                    "episode": number,
                    "episodeTitle": next.get("title"),
                    "imdb": next.pointer("/ids/imdb"),
                    "progress": progress / 100.0,
                    "lastActivity": when,
                }),
            ));
        }
        out.sort_by(|a, b| b.0.cmp(&a.0));
        Ok(out.into_iter().take(limit).map(|(_, v)| v).collect())
    }

    /// shows started but not finished (kodi's "recently played" row)
    pub async fn shows_in_progress(&self, limit: usize) -> Result<Vec<Value>> {
        let watched = self.get("/sync/watched/shows?extended=noseasons", 600).await?;
        let mut v: Vec<&Value> = watched.as_array().map(|a| a.iter().collect()).unwrap_or_default();
        v.sort_by(|a, b| {
            let la = a.get("last_watched_at").and_then(Value::as_str).unwrap_or("");
            let lb = b.get("last_watched_at").and_then(Value::as_str).unwrap_or("");
            lb.cmp(la)
        });
        Ok(v.into_iter()
            .take(limit)
            .map(|s| {
                json!({
                    "kind": "show",
                    "id": s.pointer("/show/ids/tmdb"),
                    "imdb": s.pointer("/show/ids/imdb"),
                    "title": s.pointer("/show/title"),
                    "year": s.pointer("/show/year"),
                })
            })
            .collect())
    }

    /// paused movies + episodes with progress (continue watching)
    pub async fn playback(&self) -> Result<Vec<Value>> {
        let v = self.get("/sync/playback?limit=50", 120).await?;
        Ok(v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|p| {
                        let progress = p.get("progress").and_then(Value::as_f64)? / 100.0;
                        let paused = p.get("paused_at").cloned();
                        let pid = p.get("id").cloned();
                        match p.get("type").and_then(Value::as_str)? {
                            "movie" => Some(json!({
                                "kind": "movie",
                                "id": p.pointer("/movie/ids/tmdb"),
                                "imdb": p.pointer("/movie/ids/imdb"),
                                "title": p.pointer("/movie/title"),
                                "year": p.pointer("/movie/year"),
                                "progress": progress,
                                "pausedAt": paused,
                                "playbackId": pid,
                            })),
                            "episode" => Some(json!({
                                "kind": "episode",
                                "show": p.pointer("/show/ids/tmdb"),
                                "showTitle": p.pointer("/show/title"),
                                "season": p.pointer("/episode/season"),
                                "episode": p.pointer("/episode/number"),
                                "episodeTitle": p.pointer("/episode/title"),
                                "imdb": p.pointer("/episode/ids/imdb"),
                                "progress": progress,
                                "pausedAt": paused,
                                "playbackId": pid,
                            })),
                            _ => None,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    pub async fn watchlist(&self) -> Result<Vec<Value>> {
        let mut all = Vec::new();
        for page in 1..=100 {
            let v = self.get(&format!("/sync/watchlist?sort_by=added&sort_how=desc&page={page}&limit=100"), 600).await?;
            let batch = v.as_array().context("invalid trakt watchlist")?;
            all.extend(batch.iter().cloned());
            if batch.len() < 100 {
                break;
            }
        }
        let v = Value::Array(all);
        Ok(v.as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|w| match w.get("type").and_then(Value::as_str)? {
                        "movie" => Some(json!({"kind": "movie", "id": w.pointer("/movie/ids/tmdb"), "title": w.pointer("/movie/title")})),
                        "show" => Some(json!({"kind": "show", "id": w.pointer("/show/ids/tmdb"), "title": w.pointer("/show/title")})),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    pub async fn history(&self) -> Result<Vec<Value>> {
        let v = self.get("/sync/history?page=1&limit=100", 120).await?;
        Ok(v.as_array().context("invalid trakt history")?.iter().filter_map(history_item).collect())
    }

    /// watched episode numbers of one show: [[season, episode], ...]
    pub async fn watched_episodes(&self, show_tmdb: i64) -> Result<Vec<(i64, i64)>> {
        let found = self.get(&format!("/search/tmdb/{show_tmdb}?type=show"), 86400).await?;
        let trakt = found
            .get(0)
            .and_then(|f| f.pointer("/show/ids/trakt"))
            .and_then(Value::as_i64)
            .context("show not on trakt")?;
        let p = self.get(&format!("/shows/{trakt}/progress/watched?specials=false"), 300).await?;
        let mut out = Vec::new();
        for s in p.get("seasons").and_then(Value::as_array).into_iter().flatten() {
            let sn = s.get("number").and_then(Value::as_i64).unwrap_or(0);
            for e in s.get("episodes").and_then(Value::as_array).into_iter().flatten() {
                if e.get("completed").and_then(Value::as_bool) == Some(true) {
                    out.push((sn, e.get("number").and_then(Value::as_i64).unwrap_or(0)));
                }
            }
        }
        Ok(out)
    }

    // ---- writes

    pub async fn scrobble(&self, action: &str, target: &Value, progress: f64) -> Result<()> {
        let mut body = target.clone();
        body.as_object_mut().context("scrobble target")?.insert("progress".into(), json!((progress * 100.0).clamp(0.0, 100.0)));
        match self.post(&format!("/scrobble/{action}"), body).await {
            Ok(_) => Ok(()),
            // 409 = already scrobbled in the last hour, fine
            Err(e) if e.downcast_ref::<http::HttpError>().is_some_and(|h| h.status() == 409) => Ok(()),
            Err(e) => Err(e),
        }
    }

    /// up next / recently played: hide the show from progress (kodi reads the same list)
    pub async fn hide_show(&self, show_tmdb: i64, hide: bool) -> Result<()> {
        let body = json!({ "shows": [{ "ids": { "tmdb": show_tmdb } }] });
        let path = if hide { "/users/hidden/progress_watched" } else { "/users/hidden/progress_watched/remove" };
        self.post(path, body).await?;
        self.invalidate().await;
        Ok(())
    }

    /// continue watching: drop a paused movie/episode
    pub async fn remove_playback(&self, playback_id: i64) -> Result<()> {
        if dry_run() {
            tracing::info!("trakt dry run: DELETE /sync/playback/{playback_id}");
            return Ok(());
        }
        let req = self.req(reqwest::Method::DELETE, &format!("/sync/playback/{playback_id}"), None)?;
        let (status, _) = http::send(&req).await?;
        if !status.is_success() && status.as_u16() != 404 {
            bail!("trakt answered {status}");
        }
        self.invalidate().await;
        Ok(())
    }

    pub async fn set_watchlist(&self, kind: &str, tmdb: i64, on: bool) -> Result<()> {
        let key = if kind == "movie" { "movies" } else { "shows" };
        let body = json!({ key: [{ "ids": { "tmdb": tmdb } }] });
        self.post(if on { "/sync/watchlist" } else { "/sync/watchlist/remove" }, body).await?;
        self.invalidate().await;
        Ok(())
    }
}

fn history_item(v: &Value) -> Option<Value> {
    let watched = chrono::DateTime::parse_from_rfc3339(v.get("watched_at")?.as_str()?).ok()?.timestamp();
    match v.get("type")?.as_str()? {
        "movie" => Some(json!({ "kind": "movie", "id": v.pointer("/movie/ids/tmdb")?.as_i64()?,
            "title": v.pointer("/movie/title"), "watchedAt": watched })),
        "episode" => Some(json!({ "kind": "episode", "show": v.pointer("/show/ids/tmdb")?.as_i64()?,
            "showTitle": v.pointer("/show/title"), "season": v.pointer("/episode/season")?.as_i64()?,
            "episode": v.pointer("/episode/number")?.as_i64()?, "episodeTitle": v.pointer("/episode/title"), "watchedAt": watched })),
        _ => None,
    }
}

/// trakt scrobble target for a movie or an episode
pub fn target(kind: &str, tmdb: i64, imdb: Option<&str>, season: Option<i64>, episode: Option<i64>) -> Value {
    if kind == "movie" {
        let mut ids = json!({ "tmdb": tmdb });
        if let Some(i) = imdb {
            ids["imdb"] = json!(i);
        }
        json!({ "movie": { "ids": ids } })
    } else {
        json!({
            "show": { "ids": { "tmdb": tmdb } },
            "episode": { "season": season.unwrap_or(0), "number": episode.unwrap_or(0) },
        })
    }
}

// ---- login + refresh

/// registered on noonix tv's trakt app (production apps need https); sign-in is by device code,
/// so nothing ever opens it
const APP_REDIRECT: &str = "https://github.com/dzeliks/noonix-tv";

pub async fn device_code() -> Result<Value> {
    let body = json!({ "client_id": client_id()? });
    http::json(&Req::post(format!("{API}/oauth/device/code"), body).header("content-type", "application/json")).await
}

/// one poll; Ok(None) while the user has not typed the code yet
pub async fn device_poll(profile: i64, device_code: &str) -> Result<Option<Token>> {
    let (id, secret) = app_keys(Mode::Own, None)?;
    let mut body = json!({ "code": device_code, "client_id": id });
    // apps made since 2026-10 have no secret (pkce); older ones still send theirs
    if !secret.is_empty() {
        body["client_secret"] = json!(secret);
    }
    let req = Req::post(format!("{API}/oauth/device/token"), body).header("content-type", "application/json");
    let (status, bytes) = http::send(&req).await?;
    match status.as_u16() {
        200 => {
            let mut t: Token = serde_json::from_slice(&bytes)?;
            t.expires_at = Some(t.created_at + t.expires_in);
            t.client_id = Some(id);
            save_token(Mode::Own, profile, &t)?;
            Ok(Some(t))
        }
        400 | 429 => Ok(None),
        404 => bail!("invalid code"),
        409 => bail!("code already used"),
        410 => bail!("code expired"),
        418 => bail!("denied"),
        s => bail!("trakt answered {s}"),
    }
}

/// refresh when inside the margin; writes back to every store of that token
pub async fn refresh_if_needed(mode: Mode, profile: i64, force: bool) -> Result<bool> {
    refresh_within(mode, profile, if force { i64::MAX } else { REFRESH_MARGIN }).await
}

async fn refresh_within(mode: Mode, profile: i64, margin: i64) -> Result<bool> {
    let _one = REFRESHING.lock().await;
    let token = read_token(mode, profile).context("no trakt token")?;
    // a forced refresh right after another one (two calls got the same 401) has nothing to do
    if token.expires() - store::now() > margin || (margin == i64::MAX && store::now() - token.created_at < 60) {
        return Ok(false);
    }
    wait_for_dns("api.trakt.tv").await;
    let (id, secret) = app_keys(mode, Some(&token))?;
    // a refresh repeats a redirect uri the app has registered: noonix tv's own app has an https one
    let redirect = if config::builtin(keys::TRAKT_CLIENT_ID) == Some(id.as_str()) { APP_REDIRECT } else { "urn:ietf:wg:oauth:2.0:oob" };
    let mut body = json!({
        "refresh_token": token.refresh_token,
        "client_id": id,
        "redirect_uri": redirect,
        "grant_type": "refresh_token",
    });
    if !secret.is_empty() {
        body["client_secret"] = json!(secret);
    }
    let v = http::json(&Req::post(format!("{API}/oauth/token"), body).header("content-type", "application/json")).await?;
    let mut t: Token = serde_json::from_value(v)?;
    t.expires_at = Some(t.created_at + t.expires_in);
    if mode == Mode::Own {
        t.client_id = Some(id);
    }
    save_token(mode, profile, &t)?;
    tracing::info!("trakt token refreshed, valid until {}", t.expires());
    Ok(true)
}

pub async fn wait_for_dns(host: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
    while std::time::Instant::now() < deadline {
        if tokio::net::lookup_host((host, 443)).await.is_ok() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrobble_targets() {
        assert_eq!(target("movie", 603, Some("tt0133093"), None, None), json!({ "movie": { "ids": { "tmdb": 603, "imdb": "tt0133093" } } }));
        assert_eq!(target("movie", 603, None, None, None), json!({ "movie": { "ids": { "tmdb": 603 } } }));
        assert_eq!(
            target("episode", 85552, None, Some(3), Some(4)),
            json!({ "show": { "ids": { "tmdb": 85552 } }, "episode": { "season": 3, "number": 4 } })
        );
    }

    #[test]
    fn history_items() {
        let ep = json!({ "type": "episode", "watched_at": "2026-10-20T21:00:00.000Z",
            "show": { "title": "Euphoria", "ids": { "tmdb": 85552 } }, "episode": { "season": 3, "number": 4, "title": "x" } });
        let it = history_item(&ep).unwrap();
        assert_eq!((it["kind"].as_str(), it["show"].as_i64(), it["season"].as_i64(), it["episode"].as_i64()), (Some("episode"), Some(85552), Some(3), Some(4)));
        assert_eq!(it["watchedAt"].as_i64(), Some(1792530000));
        let mv = json!({ "type": "movie", "watched_at": "2026-10-20T21:00:00Z", "movie": { "title": "M", "ids": { "tmdb": 1 } } });
        assert_eq!(history_item(&mv).unwrap()["id"].as_i64(), Some(1));
        // missing ids or an unknown type: skipped, never a half item
        assert!(history_item(&json!({ "type": "movie", "watched_at": "2026-10-20T21:00:00Z", "movie": {} })).is_none());
        assert!(history_item(&json!({ "type": "show", "watched_at": "2026-10-20T21:00:00Z" })).is_none());
        assert!(history_item(&json!({ "type": "movie", "watched_at": "yesterday", "movie": { "ids": { "tmdb": 1 } } })).is_none());
    }
}
