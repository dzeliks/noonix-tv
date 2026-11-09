// setup's choices (languages, balkan mode) and the keys typed in setup / settings, each checked
// with its service before it's kept
use crate::config::{self, keys, preview};
use crate::store;
use anyhow::{bail, Context, Result};
use crate::http::{self, Req};
use serde_json::{json, Value};

pub async fn set_languages(languages: Vec<String>, subtitles: Vec<String>) -> Result<()> {
    anyhow::ensure!(!languages.is_empty() && !subtitles.is_empty(), "pick at least one language");
    let profiles = store::with(store::profiles).await?;
    let d = json!({ "languages": languages, "subtitles": subtitles });
    store::with(move |c| store::set_setting(c, "app", "default_langs", &d)).await?;
    for p in profiles {
        let mut prefs = crate::addons::prefs(p.id).await;
        prefs.languages = languages.clone();
        prefs.subtitles = subtitles.clone();
        let id = p.id;
        store::with(move |c| store::set_setting(c, &format!("profile:{id}"), "sources", &json!(prefs))).await?;
    }
    Ok(())
}

/// balkan mode on or off for the whole install: every profile, and new ones start with it
pub async fn set_balkan(on: bool) -> Result<()> {
    let profiles = store::with(store::profiles).await?;
    store::with(move |c| store::set_setting(c, "app", "balkan_subs", &json!(on))).await?;
    for p in profiles {
        let mut prefs = crate::addons::prefs(p.id).await;
        let has = prefs.subtitles.iter().any(|l| l == "balkan" || crate::ranking::BALKAN.contains(&l.as_str()));
        if on && !has {
            prefs.subtitles.push("balkan".into());
        } else if !on && has {
            prefs.subtitles.retain(|l| l != "balkan" && !crate::ranking::BALKAN.contains(&l.as_str()));
            if prefs.subtitles.is_empty() {
                prefs.subtitles.push("en".into());
            }
        } else {
            continue;
        }
        let id = p.id;
        store::with(move |c| store::set_setting(c, &format!("profile:{id}"), "sources", &json!(prefs))).await?;
    }
    Ok(())
}

// ---- keys typed in setup / settings

/// what is set up, for the setup and settings lines (previews only, never values). the debrid
/// services and torrents show up once an extension asks for them (or a key / choice exists)
pub fn accounts() -> Value {
    let pv = |k: &str| config::stored(k).map(|v| preview(&v));
    let (wanted, torrent_ext, torrents) = store::DB
        .lock()
        .map(|c| {
            let (d, t) = crate::extensions::wants(&c);
            (d, t, crate::addons::torrents(&c))
        })
        .unwrap_or((Vec::new(), false, None));
    json!({
        "tmdb": { "builtin": config::builtin(keys::TMDB_API_KEY).is_some() || config::builtin(keys::TMDB_READ_TOKEN).is_some(),
                  "set": config::has_secret(keys::TMDB_API_KEY) || config::has_secret(keys::TMDB_READ_TOKEN),
                  "own": config::stored(keys::TMDB_API_KEY).map(|v| preview(&v)),
                  "refused": crate::tmdb::REFUSED.load(std::sync::atomic::Ordering::SeqCst) },
        "trakt": { "builtin": config::builtin(keys::TRAKT_CLIENT_ID).is_some(), "set": config::has_secret(keys::TRAKT_CLIENT_ID) },
        "torbox": { "set": config::has_secret(keys::TORBOX_API_KEY), "preview": pv(keys::TORBOX_API_KEY) },
        // each debrid's key, "wanted" when an installed extension uses it
        "debrids": config::DEBRIDS.iter().map(|(id, key, name)| json!({ "id": id, "key": key, "name": name, "set": config::has_secret(key), "preview": pv(key), "wanted": wanted.contains(id) })).collect::<Vec<_>>(),
        // allowed: true / false / null (never asked); wanted: an extension's sources are torrents
        "torrents": { "allowed": torrents, "wanted": torrent_ext },
        "opensubtitles": { "set": config::has_secret(keys::OPENSUBTITLES_API_KEY), "preview": pv(keys::OPENSUBTITLES_API_KEY),
                           "user": config::stored(crate::subtitles::OS_USERNAME) },
    })
}

/// the keys setup may store, and how each is checked
const TYPED: &[&str] = &[
    keys::TORBOX_API_KEY, keys::REALDEBRID_API_KEY, keys::ALLDEBRID_API_KEY, keys::TMDB_API_KEY, keys::OPENSUBTITLES_API_KEY, "OPENSUBTITLES_LOGIN",
];

/// torrents on or off for the whole install (the user said yes or no on the sheet)
pub async fn set_torrents(on: bool) -> Result<()> {
    store::with(move |c| {
        store::set_setting(c, "app", "torrents", &json!(on))?;
        store::cache_drop_prefix(c, "streams:")?;
        Ok(())
    })
    .await?;
    if !on {
        crate::torrent::stop().await;
    }
    crate::tvserver::apply().await;
    crate::local::changed("torrents");
    Ok(())
}

/// a debrid key checked with its service: a line for the ui, an error when it's refused
pub async fn check_debrid(key: &str, value: &str) -> Result<String> {
    let bearer = format!("Bearer {value}");
    match key {
        keys::TORBOX_API_KEY => {
            let r = Req::get("https://api.torbox.app/v1/api/user/me").header("authorization", &bearer).timeout(12).retries(1);
            let (status, body) = http::send(&r).await?;
            let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            if !status.is_success() || v.get("success").and_then(Value::as_bool) != Some(true) {
                bail!("TorBox didn't accept that key");
            }
            let plan = v.pointer("/data/plan").and_then(Value::as_i64).unwrap_or(0);
            Ok(if plan > 0 { "TorBox works".into() } else { "TorBox works, but the free plan can't stream".into() })
        }
        keys::REALDEBRID_API_KEY => {
            let r = Req::get("https://api.real-debrid.com/rest/1.0/user").header("authorization", &bearer).timeout(12).retries(1);
            let (status, body) = http::send(&r).await?;
            let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            if !status.is_success() || v.get("id").is_none() {
                bail!("Real-Debrid didn't accept that key");
            }
            Ok(if v.get("type").and_then(Value::as_str) == Some("premium") { "Real-Debrid works".into() } else { "Real-Debrid works, but streaming needs premium".into() })
        }
        keys::ALLDEBRID_API_KEY => {
            let r = Req::get("https://api.alldebrid.com/v4/user?agent=noonixtv").header("authorization", &bearer).timeout(12).retries(1);
            let (status, body) = http::send(&r).await?;
            let v: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            if !status.is_success() || v.get("status").and_then(Value::as_str) != Some("success") {
                bail!("AllDebrid didn't accept that key");
            }
            Ok(if v.pointer("/data/user/isPremium").and_then(Value::as_bool) == Some(true) { "AllDebrid works".into() } else { "AllDebrid works, but streaming needs premium".into() })
        }
        _ => bail!("unknown key"),
    }
}

async fn verify(key: &str, value: &str) -> Result<String> {
    match key {
        keys::TORBOX_API_KEY | keys::REALDEBRID_API_KEY | keys::ALLDEBRID_API_KEY => check_debrid(key, value).await,
        keys::TMDB_API_KEY => {
            let (status, _) = http::send(&Req::get(format!("https://api.themoviedb.org/3/configuration?api_key={}", urlencoding::encode(value))).timeout(12).retries(1)).await?;
            if !status.is_success() {
                bail!("TMDB didn't accept that key");
            }
            Ok("TMDB works".into())
        }
        keys::OPENSUBTITLES_API_KEY | "OPENSUBTITLES_LOGIN" => {
            let v = crate::subtitles::check().await?;
            // %1 = the count, filled in by the ui after it translated the line
            Ok(match v.get("downloads").and_then(Value::as_i64) {
                Some(n) => format!("Signed in: %1 subtitles a day|{n}"),
                None => "OpenSubtitles works".into(),
            })
        }
        _ => bail!("unknown key"),
    }
}

/// stores one typed key after checking it with its service; the old value comes back if the
/// check fails. OPENSUBTITLES_LOGIN = {"username", "password"}; an empty value removes it
pub async fn set_credential(key: &str, value: &Value) -> Result<Value> {
    if !TYPED.contains(&key) {
        bail!("unknown key");
    }
    let pairs: Vec<(&str, Option<String>)> = if key == "OPENSUBTITLES_LOGIN" {
        let user = value.get("username").and_then(Value::as_str).unwrap_or("").trim().to_owned();
        let pass = value.get("password").and_then(Value::as_str).unwrap_or("").to_owned();
        let some = |s: String| (!s.is_empty()).then_some(s);
        vec![(crate::subtitles::OS_USERNAME, some(user)), (crate::subtitles::OS_PASSWORD, some(pass))]
    } else if key == keys::TMDB_API_KEY {
        // your own key replaces an older key pair; cleared = the built-in key again
        vec![(key, value.as_str().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())), (keys::TMDB_READ_TOKEN, None)]
    } else {
        vec![(key, value.as_str().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty()))]
    };
    let before: Vec<(&str, Option<String>)> = pairs.iter().map(|(k, _)| (*k, config::stored(k))).collect();
    config::set_secrets(&pairs)?;
    if pairs.iter().all(|(_, v)| v.is_none()) {
        crate::extensions::key_changed(key).await;
        return Ok(json!({ "ok": true, "message": "Removed" }));
    }
    match verify(key, &pairs[0].1.clone().unwrap_or_default()).await {
        Ok(line) => {
            let (message, count) = match line.split_once('|') {
                Some((m, n)) => (m.to_owned(), n.parse::<i64>().ok()),
                None => (line, None),
            };
            if key == keys::TMDB_API_KEY {
                crate::tmdb::REFUSED.store(false, std::sync::atomic::Ordering::SeqCst);
            }
            if config::DEBRIDS.iter().any(|d| d.1 == key) {
                // the extensions that use it get their addresses with the new key
                crate::extensions::key_changed(key).await;
                crate::local::changed("debrid key");
            }
            Ok(json!({ "ok": true, "message": message, "count": count }))
        }
        Err(e) => {
            config::set_secrets(&before).context("couldn't restore the old key")?;
            Ok(json!({ "ok": false, "message": format!("{e:#}") }))
        }
    }
}
