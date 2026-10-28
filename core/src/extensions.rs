// noonix extensions: one json file (from an address or a file) that bundles a setup someone made:
// stremio addon addresses (which may carry a debrid key, written {torbox}), whether its sources
// are torrents, and release patterns. nothing comes installed; installing shows exactly what it
// adds and the user confirms; removing it removes all of it. a plain stremio addon address goes
// through the same preview. docs/extensions.md describes the format
use crate::config;
use crate::store;
use crate::stremio;
use anyhow::{bail, Context, Result};
use once_cell::sync::Lazy;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

pub const FORMAT: u32 = 1;
const MAX_BYTES: usize = 256 * 1024;
const MAX_ADDONS: usize = 20;
const MAX_PATTERNS: usize = 50;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Patterns {
    pub preferred: Vec<String>,
    pub excluded: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub noonix: u32,
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub author: String,
    /// stremio addon addresses; {torbox}, {realdebrid}, {alldebrid} stand for the user's key
    #[serde(default)]
    pub addons: Vec<String>,
    /// its sources answer with torrents
    #[serde(default)]
    pub torrents: bool,
    #[serde(default)]
    pub patterns: Patterns,
}

/// the debrid ids an address asks for
fn placeholders(template: &str) -> Vec<&'static str> {
    config::DEBRIDS.iter().filter(|d| template.contains(&format!("{{{}}}", d.0))).map(|d| d.0).collect()
}

impl Manifest {
    /// the debrid services it needs a key for
    pub fn needs(&self) -> Vec<&'static str> {
        let mut out: Vec<&'static str> = Vec::new();
        for a in &self.addons {
            for id in placeholders(a) {
                if !out.contains(&id) {
                    out.push(id);
                }
            }
        }
        out
    }
}

/// an address with the keys filled in; None while one of them is missing
pub fn render(template: &str, key: impl Fn(&str) -> Option<String>) -> Option<String> {
    let mut url = template.to_owned();
    for id in placeholders(template) {
        url = url.replace(&format!("{{{id}}}"), &urlencoding::encode(&key(id)?));
    }
    Some(url)
}

fn host(template: &str) -> String {
    let probe = config::DEBRIDS.iter().fold(template.replace("stremio://", "https://"), |u, d| u.replace(&format!("{{{}}}", d.0), "x"));
    url::Url::parse(&probe).ok().and_then(|u| u.host_str().map(str::to_owned)).unwrap_or_else(|| "?".into())
}

pub fn parse(text: &str) -> Result<Manifest> {
    let m: Manifest = serde_json::from_str(text).context("This isn't a Noonix TV extension")?;
    if m.noonix != FORMAT {
        bail!("This extension needs a newer Noonix TV");
    }
    let id_ok = !m.id.is_empty() && m.id.len() <= 80 && m.id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b));
    if !id_ok {
        bail!("The extension's id isn't valid");
    }
    if m.name.trim().is_empty() || m.name.len() > 80 {
        bail!("The extension has no name");
    }
    if m.addons.len() > MAX_ADDONS || m.patterns.preferred.len() + m.patterns.excluded.len() > MAX_PATTERNS {
        bail!("The extension is too big");
    }
    for a in &m.addons {
        let probe = config::DEBRIDS.iter().fold(a.replace("stremio://", "https://"), |u, d| u.replace(&format!("{{{}}}", d.0), "x"));
        if probe.contains('{') || probe.contains('}') {
            bail!("An address in the extension asks for something Noonix TV doesn't have");
        }
        stremio::check_url(&probe)?;
    }
    for p in m.patterns.preferred.iter().chain(&m.patterns.excluded) {
        if p.trim().is_empty() || crate::ranking::pattern(p).is_none() {
            bail!("The extension has a pattern that doesn't work: {p}");
        }
    }
    Ok(m)
}

// ---- preview, then install

enum Pending {
    Extension { m: Manifest, source: String },
    Addon { url: String },
}

static PENDING: Lazy<Mutex<HashMap<String, Pending>>> = Lazy::new(Default::default);

async fn fetch(url: &str) -> Result<String> {
    let u = stremio::check_url(&url.trim().replace("stremio://", "https://"))?;
    let quiet = |e: reqwest::Error| {
        tracing::debug!("extension fetch: {}", config::redact(&e.to_string()));
        anyhow::anyhow!("That address didn't answer")
    };
    let mut res = crate::http::CLIENT.get(u.as_str()).timeout(std::time::Duration::from_secs(15)).send().await.map_err(quiet)?.error_for_status().map_err(quiet)?;
    let mut out = Vec::new();
    while let Some(c) = res.chunk().await.map_err(quiet)? {
        out.extend_from_slice(&c);
        if out.len() > MAX_BYTES {
            bail!("That's too big for an extension or an addon");
        }
    }
    Ok(String::from_utf8_lossy(&out).into_owned())
}

fn read_file(path: &str) -> Result<String> {
    let path = path.strip_prefix("file://").map(|p| urlencoding::decode(p).map(|c| c.into_owned()).unwrap_or_else(|_| p.to_owned())).unwrap_or_else(|| path.to_owned());
    // windows: file:///C:/...
    let path = if cfg!(windows) { path.trim_start_matches('/').to_owned() } else { path };
    let meta = std::fs::metadata(&path).context("Couldn't open that file")?;
    if meta.len() as usize > MAX_BYTES {
        bail!("That file is too big for an extension");
    }
    std::fs::read_to_string(&path).context("Couldn't read that file")
}

fn token() -> String {
    let mut b = [0u8; 8];
    let _ = getrandom::fill(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// what an address or a file would add, for the confirm sheet. {url} or {path}
pub async fn preview(args: &Value) -> Result<Value> {
    let (text, source) = if let Some(p) = args.get("path").and_then(Value::as_str) {
        (read_file(p)?, "file".to_owned())
    } else {
        let url = args.get("url").and_then(Value::as_str).context("Missing address")?.trim().to_owned();
        match fetch(&url).await {
            Ok(t) => (t, url),
            // an addon address without /manifest.json
            Err(_) if !url.ends_with(".json") => (String::new(), url),
            Err(e) => return Err(e),
        }
    };
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    if v.get("noonix").is_some() {
        let m = parse(&text)?;
        return Ok(describe_extension(m, source));
    }
    if source == "file" {
        bail!("This isn't a Noonix TV extension");
    }
    // a stremio addon: its manifest decides
    let a = stremio::load_manifest(&source).await.map_err(|e| {
        tracing::debug!("addon manifest: {}", config::redact(&format!("{e:#}")));
        anyhow::anyhow!("That address didn't answer")
    })?;
    anyhow::ensure!(
        a.resources.iter().any(|r| matches!(r.as_str(), "Stream" | "catalog" | "meta" | "subtitles")),
        "This addon doesn't offer anything Noonix TV can use"
    );
    let t = token();
    let out = json!({
        "token": t, "kind": "addon", "name": a.name, "version": a.version,
        "description": v.get("description").and_then(Value::as_str).unwrap_or(""),
        "hosts": [host(&a.manifest_url)],
        "resources": a.resources, "types": a.types,
        "keys": [], "torrents": false, "patterns": Patterns::default(),
        "installed": store::with({ let u = a.manifest_url.clone(); move |c| Ok(c.query_row("select 1 from addons where manifest_url = ?1", params![u], |_| Ok(())).optional()?.is_some()) }).await?,
    });
    PENDING.lock().unwrap().insert(t, Pending::Addon { url: a.manifest_url });
    Ok(out)
}

fn key_lines(m: &Manifest) -> Vec<Value> {
    m.needs()
        .iter()
        .filter_map(|id| config::DEBRIDS.iter().find(|d| d.0 == *id))
        .map(|(id, key, name)| {
            let mut hosts: Vec<String> = m.addons.iter().filter(|a| placeholders(a).contains(id)).map(|a| host(a)).collect();
            hosts.sort();
            hosts.dedup();
            json!({ "id": id, "key": key, "name": name, "set": config::has_secret(key), "hosts": hosts })
        })
        .collect()
}

// the hosts its addresses go to, each once
fn hosts(m: &Manifest) -> Vec<String> {
    let mut out: Vec<String> = m.addons.iter().map(|a| host(a)).collect();
    out.sort();
    out.dedup();
    out
}

fn describe_extension(m: Manifest, source: String) -> Value {
    let t = token();
    let hosts = hosts(&m);
    let installed = store::DB.lock().ok().and_then(|c| c.query_row("select version from extensions where id = ?1", params![m.id], |r| r.get::<_, String>(0)).optional().ok().flatten());
    let out = json!({
        "token": t, "kind": "extension", "id": m.id, "name": m.name, "version": m.version,
        "description": m.description, "author": m.author,
        "addons": m.addons.len(), "hosts": hosts, "keys": key_lines(&m),
        "torrents": m.torrents, "patterns": m.patterns,
        "installed": installed.is_some(), "installedVersion": installed,
        "source": if source == "file" { "file".to_owned() } else { config::preview(&source) },
    });
    PENDING.lock().unwrap().insert(t, Pending::Extension { m, source });
    out
}

/// the user said yes on the sheet
pub async fn install(token: &str) -> Result<Value> {
    let p = PENDING.lock().unwrap().remove(token).context("That preview is gone: add it again")?;
    match p {
        Pending::Addon { url } => {
            let row = crate::addons::add(&url).await?;
            Ok(json!({ "kind": "addon", "id": row.id, "name": row.name }))
        }
        Pending::Extension { m, source } => {
            let (id, name, torrents) = (m.id.clone(), m.name.clone(), m.torrents);
            let text = serde_json::to_string(&m)?;
            let row = (m.id.clone(), m.name.clone(), m.version.clone());
            store::with(move |c| {
                c.execute(
                    "insert into extensions (id, name, version, source, manifest, enabled, added) values (?1, ?2, ?3, ?4, ?5, 1, ?6)
                     on conflict(id) do update set name = excluded.name, version = excluded.version, source = excluded.source, manifest = excluded.manifest",
                    params![row.0, row.1, row.2, source, text, store::now()],
                )?;
                Ok(())
            })
            .await?;
            let added = sync(&id).await?;
            let needs: Vec<Value> = key_lines(&m).into_iter().filter(|k| k["set"] == false).collect();
            Ok(json!({ "kind": "extension", "id": id, "name": name, "addons": added, "torrents": torrents, "needKeys": needs }))
        }
    }
}

fn manifests(c: &Connection, only_enabled: bool) -> Result<Vec<(String, bool, String, Manifest)>> {
    let mut st = c.prepare("select id, enabled, source, manifest from extensions order by added")?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? != 0, r.get::<_, String>(2)?, r.get::<_, String>(3)?)))?;
    let mut out = Vec::new();
    for row in rows {
        let (id, on, source, text) = row?;
        if only_enabled && !on {
            continue;
        }
        if let Ok(m) = serde_json::from_str::<Manifest>(&text) {
            out.push((id, on, source, m));
        }
    }
    Ok(out)
}

/// the extension's addon rows follow what it lists and the keys there are: one row per address
/// that has its keys, the rest waits for them. returns how many it has now
pub async fn sync(id: &str) -> Result<usize> {
    let id = id.to_owned();
    let found = store::with({
        let id = id.clone();
        move |c| Ok(manifests(c, false)?.into_iter().find(|x| x.0 == id))
    })
    .await?;
    let Some((_, on, _, m)) = found else { return Ok(0) };
    let wanted: Vec<String> = m.addons.iter().filter_map(|a| render(&a.replace("stremio://", "https://"), config::debrid_key)).collect();
    let mut kept = Vec::new();
    for url in &wanted {
        let url = if url.ends_with("manifest.json") { url.clone() } else { format!("{}/manifest.json", url.trim_end_matches('/')) };
        let exists = store::with({
            let u = url.clone();
            move |c| Ok(c.query_row("select id from addons where manifest_url = ?1", params![u], |r| r.get::<_, i64>(0)).optional()?)
        })
        .await?;
        if exists.is_none() {
            match crate::addons::add(&url).await {
                Ok(_) => {}
                Err(e) => {
                    tracing::warn!("extension {id}: {}", config::redact(&format!("{e:#}")));
                    continue;
                }
            }
        }
        kept.push(url);
    }
    let n = kept.len();
    store::with(move |c| {
        for u in &kept {
            c.execute("update addons set extension = ?2, enabled = ?3 where manifest_url = ?1", params![u, id, on as i64])?;
        }
        // addresses it no longer lists, or whose key is gone
        let mut st = c.prepare("select id, manifest_url from addons where extension = ?1")?;
        let rows: Vec<(i64, String)> = st.query_map(params![id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        for (row, url) in rows {
            if !kept.contains(&url) {
                c.execute("delete from addons where id = ?1", params![row])?;
                store::cache_drop_prefix(c, &format!("streams:{row}:"))?;
            }
        }
        Ok(())
    })
    .await?;
    Ok(n)
}

/// a debrid key changed: the extensions that use it follow
pub async fn key_changed(key: &str) {
    let Some(id) = config::DEBRIDS.iter().find(|d| d.1 == key).map(|d| d.0) else { return };
    let list = store::with(|c| manifests(c, false)).await.unwrap_or_default();
    for (ext, _, _, m) in list {
        if m.needs().contains(&id) {
            if let Err(e) = sync(&ext).await {
                tracing::warn!("extension {ext}: {e:#}");
            }
        }
    }
}

pub async fn remove(id: &str) -> Result<()> {
    let id = id.to_owned();
    store::with(move |c| {
        let mut st = c.prepare("select id from addons where extension = ?1")?;
        let rows: Vec<i64> = st.query_map(params![id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        for row in rows {
            c.execute("delete from addons where id = ?1", params![row])?;
            store::cache_drop_prefix(c, &format!("streams:{row}:"))?;
        }
        c.execute("delete from extensions where id = ?1", params![id])?;
        Ok(())
    })
    .await
}

pub async fn set_enabled(id: &str, on: bool) -> Result<()> {
    let id = id.to_owned();
    store::with(move |c| {
        c.execute("update extensions set enabled = ?2 where id = ?1", params![id, on as i64])?;
        c.execute("update addons set enabled = ?2 where extension = ?1", params![id, on as i64])?;
        store::cache_drop_prefix(c, "streams:")?;
        Ok(())
    })
    .await
}

/// what settings lists
pub async fn list() -> Result<Value> {
    let rows = store::with(|c| {
        let all = manifests(c, false)?;
        let mut out = Vec::new();
        for (id, on, source, m) in all {
            let count: i64 = c.query_row("select count(*) from addons where extension = ?1", params![id], |r| r.get(0))?;
            out.push((id, on, source, m, count));
        }
        Ok(out)
    })
    .await?;
    Ok(Value::Array(
        rows.into_iter()
            .map(|(id, on, source, m, count)| {
                let missing: Vec<Value> = key_lines(&m).into_iter().filter(|k| k["set"] == false).collect();
                json!({
                    "id": id, "name": m.name, "version": m.version, "description": m.description, "author": m.author,
                    "enabled": on, "addons": count, "listed": m.addons.len(), "hosts": hosts(&m), "keys": key_lines(&m), "missingKeys": missing,
                    "torrents": m.torrents, "patterns": m.patterns,
                    "source": if source == "file" { "file".to_owned() } else { config::preview(&source) },
                    "updatable": source != "file",
                })
            })
            .collect(),
    ))
}

/// fetches it again from where it came from: the sheet shows what the new version adds
pub async fn update(id: &str) -> Result<Value> {
    let id = id.to_owned();
    let source = store::with(move |c| Ok(c.query_row("select source from extensions where id = ?1", params![id], |r| r.get::<_, String>(0)).optional()?))
        .await?
        .context("No such extension")?;
    if source == "file" {
        bail!("This one came from a file: open the new file instead");
    }
    preview(&json!({ "url": source })).await
}

/// release patterns of the extensions that are on (preferred, excluded)
pub fn patterns(c: &Connection) -> (Vec<String>, Vec<String>) {
    let mut out = (Vec::new(), Vec::new());
    for (_, _, _, m) in manifests(c, true).unwrap_or_default() {
        out.0.extend(m.patterns.preferred);
        out.1.extend(m.patterns.excluded);
    }
    out
}

/// what the installed extensions (and anything the build brings along) ask of the user: the debrid
/// services they need, torrents
pub fn wants(c: &Connection) -> (Vec<&'static str>, bool) {
    let (mut debrids, mut torrents) = crate::local::wants();
    for (_, _, _, m) in manifests(c, false).unwrap_or_default() {
        for id in m.needs() {
            if !debrids.contains(&id) {
                debrids.push(id);
            }
        }
        torrents |= m.torrents;
    }
    (debrids, torrents)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
        "noonix": 1, "id": "example.remux-first", "name": "Remux first", "version": "1.0.0",
        "addons": ["https://addon.example.com/{torbox}/manifest.json", "https://other.example.org/manifest.json"],
        "patterns": { "preferred": ["REMUX", "/\\bITA\\b/"], "excluded": ["HC"] }
    }"#;

    #[test]
    fn parses_and_renders() {
        let m = parse(SAMPLE).unwrap();
        assert_eq!(m.needs(), vec!["torbox"]);
        assert_eq!(render(&m.addons[0], |_| None), None);
        assert_eq!(render(&m.addons[0], |id| (id == "torbox").then(|| "a b".into())).as_deref(), Some("https://addon.example.com/a%20b/manifest.json"));
        assert_eq!(render(&m.addons[1], |_| None).as_deref(), Some("https://other.example.org/manifest.json"));
        assert_eq!(host(&m.addons[0]), "addon.example.com");
    }

    #[test]
    fn refuses_what_it_cant_trust() {
        assert!(parse(&SAMPLE.replace("\"noonix\": 1", "\"noonix\": 2")).is_err());
        assert!(parse(&SAMPLE.replace("example.remux-first", "Bad Id")).is_err());
        assert!(parse(&SAMPLE.replace("https://other", "http://other")).is_err());
        assert!(parse(&SAMPLE.replace("{torbox}", "{premiumize}")).is_err());
        assert!(parse(&SAMPLE.replace("\"HC\"", "\"/(/\"")).is_err());
        assert!(parse("{\"name\": \"x\"}").is_err());
    }
}
