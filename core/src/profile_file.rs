// a profile as a .noonix file, to take it to another noonix tv: its name, colour, picture and
// languages, the install's addons, extensions and release patterns, and its watch history if the
// user wants it. keys only when the user ticks them; a trakt login never (its refresh token works
// once: two installs would sign each other out). importing adds a new profile, it never replaces one
use crate::config::{self, keys};
use crate::extensions::{self, Manifest, Patterns};
use crate::store;
use anyhow::{bail, Context, Result};
use base64::Engine;
use once_cell::sync::Lazy;
use rusqlite::types::{Value as Sql, ValueRef};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

const MAX_BYTES: u64 = 32 * 1024 * 1024;
const MAX_PICTURE: usize = 4 * 1024 * 1024;

// the tables a profile's watch history lives in, and the columns that travel (the profile's id doesn't)
const PROGRESS: &[&str] = &["key", "kind", "tmdb", "imdb", "season", "episode", "title", "position", "duration", "completed", "updated"];
const HISTORY: &[&str] = &["key", "kind", "tmdb", "season", "episode", "watched_at"];
const WATCHLIST: &[&str] = &["kind", "tmdb", "added"];
const SOURCES: &[&str] = &["show", "provider", "resolution", "binge_group", "updated"];
// install-wide: the sources and subtitles rated in the player
const MATCHES: &[&str] = &["title", "show", "release", "release_group", "sub", "sub_lang", "sub_name", "provider", "sub_src", "verdict", "reason", "offset_ms", "updated"];

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct File {
    noonix: u32,
    kind: String,
    name: String,
    color: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    picture: Option<Picture>,
    /// languages, subtitles and the rest of the profile's source settings
    prefs: Value,
    patterns: Patterns,
    extensions: Vec<Ext>,
    addons: Vec<Addon>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    keys: BTreeMap<String, String>,
    /// it had a trakt login: it signs in again on the other side
    trakt: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    watch: Option<Watch>,
    app: String,
    exported: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Picture {
    name: String,
    data: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Ext {
    manifest: Manifest,
    /// the address it updates from; None = a file
    source: Option<String>,
    enabled: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct Addon {
    address: String,
    enabled: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct Watch {
    progress: Vec<Value>,
    history: Vec<Value>,
    watchlist: Vec<Value>,
    sources: Vec<Value>,
    matches: Vec<Value>,
    dismissed: Value,
}

/// the keys a file may carry: the user's own (never the built-in ones, never a trakt login)
const KEYS: &[&str] = &[
    keys::TORBOX_API_KEY,
    keys::REALDEBRID_API_KEY,
    keys::ALLDEBRID_API_KEY,
    keys::OPENSUBTITLES_API_KEY,
    crate::subtitles::OS_USERNAME,
    crate::subtitles::OS_PASSWORD,
    keys::TMDB_API_KEY,
    keys::TMDB_READ_TOKEN,
];

fn key_name(k: &str) -> &'static str {
    match k {
        keys::TORBOX_API_KEY => "TorBox",
        keys::REALDEBRID_API_KEY => "Real-Debrid",
        keys::ALLDEBRID_API_KEY => "AllDebrid",
        keys::TMDB_API_KEY | keys::TMDB_READ_TOKEN => "TMDB",
        _ => "OpenSubtitles",
    }
}

// each service once, in the order above
fn key_names<'a>(ks: impl Iterator<Item = &'a String>) -> Vec<&'static str> {
    let ks: Vec<&String> = ks.collect();
    let mut out: Vec<&'static str> = Vec::new();
    for k in KEYS.iter().filter(|k| ks.iter().any(|x| x == *k)) {
        if !out.contains(&key_name(k)) {
            out.push(key_name(k));
        }
    }
    out
}

/// an address with settings in it (anything between the host and manifest.json, or a query) may
/// hold someone's key: it goes into a file only with the keys
pub fn may_hold_key(address: &str) -> bool {
    let Ok(u) = url::Url::parse(address) else { return true };
    u.query().is_some() || !u.username().is_empty() || u.password().is_some() || !u.path().trim_end_matches("manifest.json").trim_matches('/').is_empty()
}

// ---- rows as json and back

fn dump(c: &Connection, table: &str, cols: &[&str], profile: Option<i64>) -> Result<Vec<Value>> {
    let filter = if profile.is_some() { " where profile = ?1" } else { "" };
    let mut st = c.prepare(&format!("select {} from {table}{filter}", cols.join(", ")))?;
    let read = |r: &rusqlite::Row| {
        let mut m = Map::new();
        for (i, col) in cols.iter().enumerate() {
            let v = match r.get_ref(i)? {
                ValueRef::Integer(x) => json!(x),
                ValueRef::Real(x) => json!(x),
                ValueRef::Text(t) => json!(String::from_utf8_lossy(t)),
                ValueRef::Null | ValueRef::Blob(_) => continue,
            };
            m.insert((*col).to_owned(), v);
        }
        Ok(Value::Object(m))
    };
    let rows = match profile {
        Some(p) => st.query_map(params![p], read)?.collect::<rusqlite::Result<Vec<_>>>()?,
        None => st.query_map([], read)?.collect::<rusqlite::Result<Vec<_>>>()?,
    };
    Ok(rows)
}

// rows that break the table's rules are left out; what's here already stays
fn load(c: &Connection, table: &str, cols: &[&str], rows: &[Value], profile: Option<i64>) -> Result<usize> {
    let mut names: Vec<&str> = cols.to_vec();
    if profile.is_some() {
        names.insert(0, "profile");
    }
    let marks: Vec<String> = (1..=names.len()).map(|i| format!("?{i}")).collect();
    let mut st = c.prepare(&format!("insert or ignore into {table} ({}) values ({})", names.join(", "), marks.join(", ")))?;
    let mut n = 0;
    for r in rows {
        let mut vals: Vec<Sql> = profile.map(|p| vec![Sql::Integer(p)]).unwrap_or_default();
        for col in cols {
            vals.push(match r.get(*col) {
                Some(Value::Number(x)) if x.is_i64() => Sql::Integer(x.as_i64().unwrap_or(0)),
                Some(Value::Number(x)) => Sql::Real(x.as_f64().unwrap_or(0.0)),
                Some(Value::String(t)) => Sql::Text(t.clone()),
                Some(Value::Bool(b)) => Sql::Integer(*b as i64),
                _ => Sql::Null,
            });
        }
        n += st.execute(rusqlite::params_from_iter(vals))?;
    }
    Ok(n)
}

fn language_names(list: &Value) -> Vec<String> {
    let codes: Vec<&str> = list.as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let all = [crate::ranking::language_options(false, true), crate::ranking::language_options(true, true)];
    codes
        .iter()
        .map(|code| all.iter().filter_map(Value::as_array).flatten().find(|o| o["code"] == *code).and_then(|o| o["name"].as_str()).unwrap_or(code).to_owned())
        .collect()
}

// watched or started, each title once
fn titles(w: &Watch) -> usize {
    let mut keys: Vec<&str> = w.progress.iter().chain(&w.history).filter_map(|r| r["key"].as_str()).collect();
    keys.sort_unstable();
    keys.dedup();
    keys.len()
}

fn avatar_dir() -> PathBuf {
    config::PATHS.data.join("avatars")
}

// ---- export

/// what goes into the file, for the export sheet
pub async fn summary(id: i64) -> Result<Value> {
    let f = build(id, true, true).await?;
    let (clean, keyed): (Vec<&Addon>, Vec<&Addon>) = f.addons.iter().partition(|a| !may_hold_key(&a.address));
    let w = f.watch.as_ref();
    Ok(json!({
        "id": id, "name": f.name, "color": f.color,
        "image": f.picture.as_ref().map(|p| avatar_dir().join(&p.name).to_string_lossy().into_owned()),
        "languages": language_names(&f.prefs["languages"]),
        "subtitles": language_names(&f.prefs["subtitles"]),
        "extensions": f.extensions.iter().map(|e| e.manifest.name.clone()).collect::<Vec<_>>(),
        "addons": clean.iter().map(|a| extensions::host(&a.address)).collect::<Vec<_>>(),
        "keyedAddons": keyed.iter().map(|a| extensions::host(&a.address)).collect::<Vec<_>>(),
        "patterns": f.patterns.preferred.len() + f.patterns.excluded.len(),
        "keys": key_names(f.keys.keys()),
        "trakt": f.trakt,
        "watch": { "titles": w.map_or(0, titles), "list": w.map_or(0, |w| w.watchlist.len()) },
    }))
}

async fn build(id: i64, watch: bool, with_keys: bool) -> Result<File> {
    let mut f = store::with(move |c| {
        let p = store::profiles(c)?.into_iter().find(|p| p.id == id).context("unknown profile")?;
        let scope = format!("profile:{id}");
        let picture = store::get_setting(c, &scope, "avatar")?.and_then(|v| v.as_str().map(str::to_owned)).and_then(|name| {
            let data = std::fs::read(avatar_dir().join(&name)).ok().filter(|d| d.len() <= MAX_PICTURE)?;
            Some(Picture { name, data: base64::engine::general_purpose::STANDARD.encode(data) })
        });
        let (preferred, excluded) = crate::addons::user_patterns(c);
        let exts = extensions::manifests(c, false)?
            .into_iter()
            .map(|(_, on, source, manifest)| Ext { manifest, source: (source != "file").then_some(source), enabled: on })
            .collect();
        let mut st = c.prepare("select manifest_url, enabled from addons where extension is null order by position, id")?;
        let addons = st.query_map([], |r| Ok(Addon { address: r.get(0)?, enabled: r.get::<_, i64>(1)? != 0 }))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let watch = if watch {
            Some(Watch {
                progress: dump(c, "progress", PROGRESS, Some(id))?,
                history: dump(c, "history", HISTORY, Some(id))?,
                watchlist: dump(c, "watchlist", WATCHLIST, Some(id))?,
                sources: dump(c, "source_memory", SOURCES, Some(id))?,
                matches: dump(c, "match_marks", MATCHES, None)?,
                dismissed: store::get_setting(c, &scope, "dismissed")?.unwrap_or(Value::Null),
            })
        } else {
            None
        };
        Ok(File {
            noonix: extensions::FORMAT,
            kind: "profile".into(),
            name: p.name,
            color: p.color,
            picture,
            prefs: Value::Null,
            patterns: Patterns { preferred, excluded },
            extensions: exts,
            addons,
            keys: BTreeMap::new(),
            trakt: p.trakt == "own",
            watch,
            app: env!("CARGO_PKG_VERSION").into(),
            exported: store::now(),
        })
    })
    .await?;
    // what the profile uses, the install's defaults included
    f.prefs = json!(crate::addons::prefs(id).await);
    if with_keys {
        f.keys = KEYS.iter().filter_map(|k| config::stored(k).map(|v| ((*k).to_owned(), v))).collect();
    } else {
        f.addons.retain(|a| !may_hold_key(&a.address));
        for e in &mut f.extensions {
            if e.source.as_deref().is_some_and(may_hold_key) {
                e.source = None;
            }
        }
    }
    Ok(f)
}

/// writes <folder>/<name>.noonix (a free name next to older ones), the downloads folder unless the
/// ui names one; the path it wrote
pub async fn export(id: i64, folder: Option<&str>, watch: bool, with_keys: bool) -> Result<Value> {
    let f = build(id, watch, with_keys).await?;
    let dir = match folder {
        Some(d) => PathBuf::from(extensions::local_path(d)),
        None => PathBuf::from(std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).context("Couldn't write there")?).join("Downloads"),
    };
    std::fs::create_dir_all(&dir).context("Couldn't write there")?;
    let base: String = f.name.chars().map(|ch| if ch.is_alphanumeric() || " -_".contains(ch) { ch } else { '_' }).collect();
    let base = if base.trim().is_empty() { "Profile".to_owned() } else { base.trim().to_owned() };
    let path = (1..)
        .map(|i| dir.join(if i == 1 { format!("{base}.noonix") } else { format!("{base} {i}.noonix") }))
        .find(|p| !p.exists())
        .context("Couldn't write there")?;
    let text = serde_json::to_string_pretty(&f)?;
    let path2 = path.clone();
    tokio::task::spawn_blocking(move || -> Result<()> {
        std::fs::write(&path2, text).context("Couldn't write there")?;
        // keys inside: only the user reads it
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if with_keys {
                let _ = std::fs::set_permissions(&path2, std::fs::Permissions::from_mode(0o600));
            }
        }
        Ok(())
    })
    .await??;
    Ok(json!({ "path": path.to_string_lossy(), "file": path.file_name().map(|n| n.to_string_lossy().into_owned()) }))
}

// ---- import: a preview first, then the user's yes

static PENDING: Lazy<Mutex<Option<(String, File)>>> = Lazy::new(Default::default);

fn read(path: &str) -> Result<File> {
    let path = extensions::local_path(path);
    let meta = std::fs::metadata(&path).context("Couldn't open that file")?;
    if meta.len() > MAX_BYTES {
        bail!("That file is too big for a profile");
    }
    let text = std::fs::read_to_string(&path).context("Couldn't read that file")?;
    let f: File = serde_json::from_str(&text).context("This isn't a Noonix TV profile")?;
    if f.kind != "profile" {
        bail!("This isn't a Noonix TV profile");
    }
    if f.noonix != extensions::FORMAT {
        bail!("This profile needs a newer Noonix TV");
    }
    if f.name.trim().is_empty() {
        bail!("This isn't a Noonix TV profile");
    }
    Ok(f)
}

/// what importing the file would do, for the import sheet. {path}
pub async fn preview(path: &str) -> Result<Value> {
    let path = path.to_owned();
    let mut f = tokio::task::spawn_blocking(move || read(&path)).await??;
    // only what this install can trust: valid extensions and addresses, known keys
    f.extensions.retain(|e| serde_json::to_string(&e.manifest).ok().and_then(|t| extensions::parse(&t).ok()).is_some());
    f.addons.retain(|a| crate::stremio::check_url(&a.address).is_ok());
    f.keys.retain(|k, v| KEYS.contains(&k.as_str()) && !v.trim().is_empty());
    let here = store::with(|c| {
        let exts: Vec<String> = extensions::manifests(c, false)?.into_iter().map(|e| e.0).collect();
        let mut st = c.prepare("select manifest_url from addons")?;
        let addons: Vec<String> = st.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok((exts, addons))
    })
    .await?;
    let new_ext: Vec<&Ext> = f.extensions.iter().filter(|e| !here.0.contains(&e.manifest.id)).collect();
    let new_addons: Vec<&Addon> = f.addons.iter().filter(|a| !here.1.contains(&a.address)).collect();
    let (fill, kept): (Vec<&String>, Vec<&String>) = f.keys.keys().partition(|k| config::stored(k).is_none());
    let w = f.watch.as_ref();
    let token = extensions::token();
    let out = json!({
        "token": token, "name": f.name, "color": f.color,
        // the picture as a data url (it isn't on this disk yet)
        "image": f.picture.as_ref().and_then(|p| {
            let ext = Path::new(&p.name).extension()?.to_str()?.to_ascii_lowercase();
            let mime = match ext.as_str() { "png" => "png", "webp" => "webp", "jpg" | "jpeg" => "jpeg", _ => return None };
            Some(format!("data:image/{mime};base64,{}", p.data))
        }),
        "languages": language_names(&f.prefs["languages"]),
        "subtitles": language_names(&f.prefs["subtitles"]),
        "extensions": new_ext.iter().map(|e| e.manifest.name.clone()).collect::<Vec<_>>(),
        "addons": new_addons.iter().map(|a| extensions::host(&a.address)).collect::<Vec<_>>(),
        "torrents": new_ext.iter().any(|e| e.manifest.torrents),
        "patterns": f.patterns.preferred.len() + f.patterns.excluded.len(),
        "keys": key_names(fill.into_iter()),
        "keptKeys": key_names(kept.into_iter()),
        "trakt": f.trakt,
        "watch": w.map(|w| json!({ "titles": titles(w), "list": w.watchlist.len() })),
        "app": f.app,
    });
    *PENDING.lock().unwrap() = Some((token, f));
    Ok(out)
}

/// the user said yes: a new profile with what the file holds; the install gets the sources and
/// keys it doesn't have yet (its own ones stay)
pub async fn import(token: &str) -> Result<Value> {
    let f = match PENDING.lock().unwrap().take() {
        Some((t, f)) if t == token => f,
        _ => bail!("That preview is gone: open the file again"),
    };
    // keys first: the extensions' addresses need them
    let keys: Vec<(&str, Option<String>)> = f.keys.iter().filter(|(k, _)| config::stored(k).is_none()).filter_map(|(k, v)| KEYS.iter().find(|x| **x == k.as_str()).map(|k| (*k, Some(v.clone())))).collect();
    if !keys.is_empty() {
        config::set_secrets(&keys)?;
    }
    let here: Vec<String> = store::with(|c| Ok(extensions::manifests(c, false)?.into_iter().map(|e| e.0).collect())).await?;
    let mut added = 0;
    let mut failed: Vec<String> = Vec::new();
    for e in f.extensions.iter().filter(|e| !here.contains(&e.manifest.id)) {
        let Ok(m) = serde_json::to_string(&e.manifest).map_err(anyhow::Error::from).and_then(|t| extensions::parse(&t)) else { continue };
        match extensions::add(&m, e.source.as_deref().unwrap_or("file"), e.enabled).await {
            Ok(_) => added += 1,
            Err(err) => {
                tracing::warn!("profile import, extension {}: {}", m.id, config::redact(&format!("{err:#}")));
                failed.push(m.name.clone());
            }
        }
    }
    for a in &f.addons {
        let url = a.address.clone();
        let exists = store::with(move |c| Ok(c.query_row("select 1 from addons where manifest_url = ?1", params![url], |_| Ok(())).optional()?.is_some())).await?;
        if exists || crate::stremio::check_url(&a.address).is_err() {
            continue;
        }
        match crate::addons::add(&a.address).await {
            Ok(row) => {
                added += 1;
                if !a.enabled {
                    crate::addons::set_enabled(row.id, false).await?;
                }
            }
            Err(err) => {
                tracing::warn!("profile import, addon: {}", config::redact(&format!("{err:#}")));
                failed.push(extensions::host(&a.address));
            }
        }
    }
    for (k, _) in &keys {
        crate::extensions::key_changed(k).await;
    }

    // the picture: next to the others, under a free name unless it's the same file
    let picture = f.picture.as_ref().and_then(|p| {
        let data = base64::engine::general_purpose::STANDARD.decode(&p.data).ok().filter(|d| d.len() <= MAX_PICTURE)?;
        let name = Path::new(&p.name).file_name()?.to_str()?.to_owned();
        let ext = Path::new(&name).extension()?.to_str()?.to_ascii_lowercase();
        if !matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "webp") {
            return None;
        }
        let dir = avatar_dir();
        let _ = std::fs::create_dir_all(&dir);
        let stem = Path::new(&name).file_stem()?.to_str()?.to_owned();
        for i in 1.. {
            let candidate = if i == 1 { name.clone() } else { format!("{stem} {i}.{ext}") };
            let path = dir.join(&candidate);
            match std::fs::read(&path) {
                Ok(old) if old == data => return Some(candidate),
                Ok(_) => continue,
                Err(_) => return std::fs::write(&path, &data).ok().map(|_| candidate),
            }
        }
        None
    });

    let name = f.name.trim().to_owned();
    let (id, name) = store::with(move |c| {
        let taken: Vec<String> = store::profiles(c)?.into_iter().map(|p| p.name).collect();
        let name = (1..).map(|i| if i == 1 { name.clone() } else { format!("{name} {i}") }).find(|n| !taken.contains(n)).unwrap_or(name);
        let tx = c.unchecked_transaction()?;
        let color = if f.color.is_empty() { "green".to_owned() } else { f.color.clone() };
        let id = store::add_profile(&tx, &name, &color, "none")?;
        let scope = format!("profile:{id}");
        if let Some(p) = &picture {
            store::set_setting(&tx, &scope, "avatar", &json!(p))?;
        }
        if f.prefs.is_object() {
            store::set_setting(&tx, &scope, "sources", &f.prefs)?;
        }
        // it had a trakt login: it asks to sign in once more
        if f.trakt {
            store::set_setting(&tx, &scope, "trakt_relogin", &json!(true))?;
        }
        // release patterns join the install's
        let (mut pre, mut exc) = crate::addons::user_patterns(&tx);
        for (to, from) in [(&mut pre, &f.patterns.preferred), (&mut exc, &f.patterns.excluded)] {
            for p in from {
                if to.len() < 50 && !to.contains(p) && crate::ranking::pattern(p).is_some() {
                    to.push(p.clone());
                }
            }
        }
        store::set_setting(&tx, "app", "patterns", &json!({ "preferred": pre, "excluded": exc }))?;
        if let Some(w) = &f.watch {
            load(&tx, "progress", PROGRESS, &w.progress, Some(id))?;
            load(&tx, "history", HISTORY, &w.history, Some(id))?;
            load(&tx, "watchlist", WATCHLIST, &w.watchlist, Some(id))?;
            load(&tx, "source_memory", SOURCES, &w.sources, Some(id))?;
            load(&tx, "match_marks", MATCHES, &w.matches, None)?;
            if w.dismissed.is_array() {
                store::set_setting(&tx, &scope, "dismissed", &w.dismissed)?;
            }
        }
        store::cache_drop_prefix(&tx, "streams:")?;
        tx.commit()?;
        Ok((id, name))
    })
    .await?;
    crate::local::changed("profile import");
    Ok(json!({ "id": id, "name": name, "sources": added, "failed": failed }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyed_addresses() {
        assert!(!may_hold_key("https://opensubtitles-v3.strem.io/manifest.json"));
        assert!(!may_hold_key("https://addon.example.com/"));
        assert!(may_hold_key("https://addon.example.com/abc123/manifest.json"));
        assert!(may_hold_key("https://addon.example.com/manifest.json?key=1"));
        assert!(may_hold_key("not a url"));
    }

    #[test]
    fn rows_round_trip() {
        let c = store::open_memory().unwrap();
        c.execute("insert into profiles (id, name, created) values (1, 'a', 0), (2, 'b', 0)", []).unwrap();
        c.execute("insert into progress (profile, key, kind, tmdb, title, position, duration, updated) values (1, 'movie:5', 'movie', 5, 'x', 1.5, 90, 7)", []).unwrap();
        c.execute("insert into watchlist (profile, kind, tmdb, added) values (1, 'show', 9, 3)", []).unwrap();
        let p = dump(&c, "progress", PROGRESS, Some(1)).unwrap();
        let w = dump(&c, "watchlist", WATCHLIST, Some(1)).unwrap();
        assert_eq!(p.len(), 1);
        assert!(p[0].get("imdb").is_none());
        assert_eq!(load(&c, "progress", PROGRESS, &p, Some(2)).unwrap(), 1);
        assert_eq!(load(&c, "watchlist", WATCHLIST, &w, Some(2)).unwrap(), 1);
        // a broken row is left out, not an error
        assert_eq!(load(&c, "watchlist", WATCHLIST, &[json!({ "kind": "show" })], Some(2)).unwrap(), 0);
        let pos: f64 = c.query_row("select position from progress where profile = 2", [], |r| r.get(0)).unwrap();
        assert_eq!(pos, 1.5);
    }
}
