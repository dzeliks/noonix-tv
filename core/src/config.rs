// secrets live in the app's own database (table secrets): typed in setup / settings, never looked
// up anywhere else. app keys (tmdb, trakt app) can be built in: NOONIX_* at compile time
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

pub struct Paths {
    pub config: PathBuf,
    pub data: PathBuf,
    pub cache: PathBuf,
    pub state: PathBuf,
}

#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "android")))]
fn xdg(var: &str, fallback: &str) -> PathBuf {
    match std::env::var_os(var) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => home().join(fallback),
    }
}

pub fn home() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

#[cfg(all(unix, not(target_vendor = "apple"), not(target_os = "android")))]
fn paths() -> Paths {
    Paths {
        config: xdg("XDG_CONFIG_HOME", ".config").join("noonix-tv"),
        data: xdg("XDG_DATA_HOME", ".local/share").join("noonix-tv"),
        cache: xdg("XDG_CACHE_HOME", ".cache").join("noonix-tv"),
        state: xdg("XDG_STATE_HOME", ".local/state").join("noonix-tv"),
    }
}

// apple's places: application support (config + data), caches, logs (ios: the app's own container).
// NOONIX_HOME moves it all
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn paths() -> Paths {
    let lib = home().join("Library");
    if let Some(base) = std::env::var_os("NOONIX_HOME").map(PathBuf::from) {
        return Paths { config: base.join("config"), data: base.join("data"), cache: base.join("cache"), state: base.join("state") };
    }
    let support = lib.join("Application Support/Noonix TV");
    Paths { config: support.join("config"), data: support.clone(), cache: lib.join("Caches/Noonix TV"), state: lib.join("Logs/Noonix TV") }
}

// apple tv: an app keeps nothing but its caches (the system may clear them when space runs low;
// the app keeps a copy of the settings in its defaults, TVStore.swift)
#[cfg(target_os = "tvos")]
fn paths() -> Paths {
    if let Some(base) = std::env::var_os("NOONIX_HOME").map(PathBuf::from) {
        return Paths { config: base.join("config"), data: base.join("data"), cache: base.join("cache"), state: base.join("state") };
    }
    let base = home().join("Library/Caches/Noonix TV");
    Paths { config: base.join("config"), data: base.join("data"), cache: base.join("cache"), state: base.join("state") }
}

// the app's private files folder (qt points HOME at it). NOONIX_HOME moves it all
#[cfg(target_os = "android")]
fn paths() -> Paths {
    let base = std::env::var_os("NOONIX_HOME").map(PathBuf::from).unwrap_or_else(home);
    Paths { config: base.join("config"), data: base.join("data"), cache: base.join("cache"), state: base.join("state") }
}

// everything per user and local (caches get big: never roaming).
// NOONIX_HOME moves it all, for tests
#[cfg(windows)]
fn paths() -> Paths {
    let base = std::env::var_os("NOONIX_HOME")
        .or_else(|| std::env::var_os("LOCALAPPDATA").map(|l| PathBuf::from(l).join("Noonix TV").into_os_string()))
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("AppData/Local/Noonix TV"));
    Paths { config: base.join("config"), data: base.join("data"), cache: base.join("cache"), state: base.join("state") }
}

pub static PATHS: Lazy<Paths> = Lazy::new(|| {
    let p = paths();
    for d in [&p.config, &p.data, &p.cache, &p.state] {
        let _ = fs::create_dir_all(d);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&p.config, fs::Permissions::from_mode(0o700));
    }
    p
});

pub mod keys {
    pub const TMDB_API_KEY: &str = "TMDB_API_KEY";
    pub const TMDB_READ_TOKEN: &str = "TMDB_READ_TOKEN";
    pub const TRAKT_CLIENT_ID: &str = "TRAKT_CLIENT_ID";
    pub const TRAKT_CLIENT_SECRET: &str = "TRAKT_CLIENT_SECRET";
    pub const TORBOX_API_KEY: &str = "TORBOX_API_KEY";
    pub const REALDEBRID_API_KEY: &str = "REALDEBRID_API_KEY";
    pub const ALLDEBRID_API_KEY: &str = "ALLDEBRID_API_KEY";
    pub const OPENSUBTITLES_API_KEY: &str = "OPENSUBTITLES_API_KEY";
}

// a copy of the table: secret() is called everywhere, also from sync code
static SECRETS: Lazy<RwLock<BTreeMap<String, String>>> = Lazy::new(|| RwLock::new(load_secrets()));

/// loads them now: the first read takes the db lock, so it must not happen inside a db call
/// custom avatars: on ios where the files app reaches (the app's documents), else the data dir
pub fn avatars() -> PathBuf {
    #[cfg(target_os = "ios")]
    return home().join("Documents").join("Avatars");
    #[cfg(not(target_os = "ios"))]
    PATHS.data.join("avatars")
}

pub fn init_secrets() {
    Lazy::force(&SECRETS);
}

#[cfg(test)]
fn load_secrets() -> BTreeMap<String, String> {
    BTreeMap::new()
}

#[cfg(not(test))]
fn load_secrets() -> BTreeMap<String, String> {
    let Ok(conn) = crate::store::DB.lock() else { return BTreeMap::new() };
    crate::store::secrets(&conn).unwrap_or_default()
}

/// noonix tv's own app keys, built into release builds (github secrets -> env at compile time)
pub fn builtin(key: &str) -> Option<&'static str> {
    match key {
        keys::TMDB_API_KEY => option_env!("NOONIX_TMDB_API_KEY"),
        keys::TMDB_READ_TOKEN => option_env!("NOONIX_TMDB_READ_TOKEN"),
        keys::TRAKT_CLIENT_ID => option_env!("NOONIX_TRAKT_CLIENT_ID"),
        keys::TRAKT_CLIENT_SECRET => option_env!("NOONIX_TRAKT_CLIENT_SECRET"),
        _ => None,
    }
    .filter(|v| !v.is_empty())
}

/// what setup stored, without the built-in fallback
pub fn stored(key: &str) -> Option<String> {
    SECRETS.read().ok()?.get(key).filter(|v| !v.is_empty()).cloned()
}

/// the built-in app key first, then what setup stored. tmdb the other way round: your own key
/// works even if the built-in one is revoked (trakt tokens belong to the app that issued them)
pub fn secret(key: &str) -> Option<String> {
    match key {
        keys::TMDB_API_KEY | keys::TMDB_READ_TOKEN => stored(key).or_else(|| builtin(key).map(str::to_owned)),
        _ => builtin(key).map(str::to_owned).or_else(|| stored(key)),
    }
}

pub fn has_secret(key: &str) -> bool {
    secret(key).is_some()
}

/// debrid services an extension can ask for: (id, key, name). the id is the placeholder in its
/// addresses ({torbox}), the key never leaves this pc except to the addresses the user approved
pub const DEBRIDS: &[(&str, &str, &str)] = &[
    ("torbox", keys::TORBOX_API_KEY, "TorBox"),
    ("realdebrid", keys::REALDEBRID_API_KEY, "Real-Debrid"),
    ("alldebrid", keys::ALLDEBRID_API_KEY, "AllDebrid"),
];

pub fn debrid_key(id: &str) -> Option<String> {
    DEBRIDS.iter().find(|d| d.0 == id).and_then(|d| secret(d.1))
}

pub fn set_secrets(changes: &[(&str, Option<String>)]) -> Result<()> {
    let mut map = SECRETS.write().map_err(|_| anyhow::anyhow!("secrets lock poisoned"))?;
    #[cfg(not(test))]
    {
        let conn = crate::store::DB.lock().map_err(|_| anyhow::anyhow!("db lock poisoned"))?;
        let tx = conn.unchecked_transaction()?;
        for (k, v) in changes {
            crate::store::set_secret(&tx, k, v.as_deref())?;
        }
        tx.commit()?;
    }
    for (k, v) in changes {
        match v {
            Some(v) => map.insert((*k).to_owned(), v.clone()),
            None => map.remove(*k),
        };
    }
    Ok(())
}

pub fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut opts, 0o600);
        let mut f = opts.open(&tmp).with_context(|| format!("open {}", tmp.display()))?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
    Ok(())
}

static REDACT_RE: Lazy<regex::Regex> = Lazy::new(|| {
    regex::Regex::new(
        r#"(?i)(bearer\s+|basic\s+|api[_-]?key=|token=|apikey=|key=)[^\s&"']+|eyJ[A-Za-z0-9+/=_%\-]{10,}|[A-Za-z0-9_\-=%.]{24,}"#,
    )
    .unwrap()
});

// keeps the host so logs stay useful
pub fn redact(s: &str) -> String {
    REDACT_RE
        .replace_all(s, |c: &regex::Captures| match c.get(1) {
            Some(prefix) => format!("{}<redacted>", prefix.as_str()),
            None => "<redacted>".to_owned(),
        })
        .into_owned()
}

pub fn preview(secret: &str) -> String {
    let s = secret.trim();
    if let Ok(u) = url::Url::parse(s) {
        if let Some(host) = u.host_str() {
            return format!("{}://{host}/…", u.scheme());
        }
    }
    let n = s.chars().count();
    if n <= 8 {
        return "•".repeat(n);
    }
    let head: String = s.chars().take(4).collect();
    let tail: String = s.chars().skip(n - 4).collect();
    format!("{head}…{tail}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_tokens_and_manifests() {
        let s = "GET https://addon.example/stremio/0a1b2c3d-1111-2222-3333-444455556666/eyJpIjoiYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoifQ/manifest.json?api_key=abc123";
        let r = redact(s);
        assert!(r.contains("addon.example"));
        assert!(!r.contains("eyJpIjoi"));
        assert!(!r.contains("abc123"));
        assert!(redact("Authorization: Bearer abcdef").contains("Bearer <redacted>"));
        // plain base64 configs (some addons) break into short runs at + and /
        let r = redact("GET /eyJkZWJyaWQiOlt7ImFwaUtleSI6Ij+xMjM0/NTY3OCJ9XX0=/stream/series/tt1:1:1.json - 200");
        assert!(!r.contains("xMjM0") && !r.contains("NTY3OCJ9"));
        assert!(r.contains("- 200"));
    }

    #[test]
    fn previews() {
        assert_eq!(preview("e6fde6173adf3c6af8fd1b0694b9b84d"), "e6fd…b84d");
        assert_eq!(preview("https://host.example/secret/path"), "https://host.example/…");
        assert_eq!(preview("abc"), "•••");
    }
}
