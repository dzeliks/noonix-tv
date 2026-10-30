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
use std::collections::{BTreeMap, HashMap};
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
    /// stremio addon addresses; {torbox}, {realdebrid}, {alldebrid} stand for the user's key. an
    /// entry may also be {url, config}: the config goes into the url's {config} as base64 json
    #[serde(default, deserialize_with = "addresses")]
    pub addons: Vec<String>,
    /// its sources answer with torrents
    #[serde(default)]
    pub torrents: bool,
    #[serde(default)]
    pub patterns: Patterns,
    /// the user's own debrid keys for its addresses ({"torbox": "…"}), for their own devices. used
    /// when the install has none; never stored with the extension
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub keys: BTreeMap<String, String>,
}

/// the debrid ids an address asks for
fn placeholders(template: &str) -> Vec<&'static str> {
    config::DEBRIDS.iter().filter(|d| template.contains(&format!("{{{}}}", d.0))).map(|d| d.0).collect()
}

/// where an address carries its settings (addons that keep them in the path, base64 json):
/// written {base64:<json>} in the stored template
const ENCODED: &str = "{base64:";

/// an addon entry: an address, or an address with its settings
fn addresses<'de, D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Vec<String>, D::Error> {
    use serde::de::Error;
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Entry {
        Url(String),
        Config { url: String, config: Value },
    }
    Vec::<Entry>::deserialize(d)?
        .into_iter()
        .map(|e| match e {
            Entry::Url(u) => Ok(u),
            Entry::Config { url, config } => {
                if url.matches("{config}").count() != 1 || !config.is_object() {
                    return Err(D::Error::custom("an addon with settings needs one {config} in its address"));
                }
                Ok(url.replace("{config}", &format!("{ENCODED}{config}}}")))
            }
        })
        .collect()
}

/// the settings with the keys filled in, as base64 the path can hold: plain base64 (what these
/// addons decode) without / or +. json can spell the same thing many ways (a space after , : { [,
/// a string's character as \u00xx), so the spelling is picked group by group until all are clean
fn encode(config: &Value, key: &impl Fn(&str) -> Option<String>) -> Option<String> {
    use base64::Engine;
    fn fill(v: &Value, key: &impl Fn(&str) -> Option<String>) -> Option<Value> {
        Some(match v {
            Value::String(s) => {
                let mut s = s.clone();
                for id in placeholders(&s) {
                    s = s.replace(&format!("{{{id}}}"), &key(id)?);
                }
                Value::String(s)
            }
            Value::Array(a) => Value::Array(a.iter().map(|x| fill(x, key)).collect::<Option<_>>()?),
            Value::Object(o) => Value::Object(o.iter().map(|(k, x)| Some((k.clone(), fill(x, key)?))).collect::<Option<_>>()?),
            other => other.clone(),
        })
    }
    let text = fill(config, key)?.to_string();
    // each piece of the text with the spellings it may take
    let mut pieces: Vec<Vec<Vec<u8>>> = Vec::new();
    let (mut chars, mut quoted) = (text.chars().peekable(), false);
    while let Some(c) = chars.next() {
        let raw = c.to_string().into_bytes();
        pieces.push(match c {
            '"' => {
                quoted = !quoted;
                vec![raw]
            }
            '\\' if quoted => {
                // an escape stays as it is: \" \\ \n \uxxxx
                let mut e = vec![b'\\'];
                let n = if chars.peek() == Some(&'u') { 5 } else { 1 };
                e.extend(chars.by_ref().take(n).collect::<String>().into_bytes());
                vec![e]
            }
            c if quoted && (c as u32) < 0x10000 => vec![raw, format!("\\u{:04x}", c as u32).into_bytes()],
            ',' | ':' | '{' | '[' if !quoted => vec![raw.clone(), [raw, b" ".to_vec()].concat()],
            _ => vec![raw],
        });
    }
    fn clean(b: &[u8]) -> bool {
        !base64::engine::general_purpose::STANDARD.encode(b).contains(['/', '+'])
    }
    // depth first over the pieces; a group of 3 bytes is final once complete
    fn walk(pieces: &[Vec<Vec<u8>>], i: usize, out: &mut Vec<u8>, budget: &mut u32) -> bool {
        if i == pieces.len() {
            return clean(&out[out.len() - out.len() % 3..]);
        }
        for alt in &pieces[i] {
            if *budget == 0 {
                return false;
            }
            *budget -= 1;
            let start = out.len();
            out.extend_from_slice(alt);
            let done = start - start % 3;
            let whole = out.len() - out.len() % 3;
            if (done..whole).step_by(3).all(|g| clean(&out[g..g + 3])) && walk(pieces, i + 1, out, budget) {
                return true;
            }
            out.truncate(start);
        }
        false
    }
    let mut out = Vec::with_capacity(text.len() * 2);
    walk(&pieces, 0, &mut out, &mut 200_000).then(|| base64::engine::general_purpose::STANDARD.encode(&out))
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
    // the settings part first: its keys go in as they are, then the whole part is encoded
    let (mut url, mut tail) = (String::new(), template);
    if let Some(i) = template.find(ENCODED) {
        let rest = &template[i + ENCODED.len()..];
        let mut it = serde_json::Deserializer::from_str(rest).into_iter::<Value>();
        let config = it.next()?.ok()?;
        let after = rest[it.byte_offset()..].strip_prefix('}')?;
        url.push_str(&template[..i]);
        tail = after;
        url.push_str(&encode(&config, &key)?);
    }
    url.push_str(tail);
    for id in placeholders(&url) {
        url = url.replace(&format!("{{{id}}}"), &urlencoding::encode(&key(id)?));
    }
    Some(url)
}

/// the address with stand-ins for the keys: for checks and the hosts the preview names
fn probe(template: &str) -> Option<String> {
    render(&template.replace("stremio://", "https://"), |_| Some("x".into()))
}

pub fn host(template: &str) -> String {
    probe(template).and_then(|p| url::Url::parse(&p).ok()).and_then(|u| u.host_str().map(str::to_owned)).unwrap_or_else(|| "?".into())
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
        let probe = probe(a).filter(|p| !p.contains(['{', '}']));
        let Some(probe) = probe else { bail!("An address in the extension asks for something Noonix TV doesn't have") };
        stremio::check_url(&probe)?;
    }
    let needs = m.needs();
    if m.keys.iter().any(|(id, v)| !needs.contains(&id.as_str()) || v.trim().is_empty()) {
        bail!("The extension has a key none of its addresses use");
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
    Extension { m: Box<Manifest>, source: String },
    Addon { url: String },
}

static PENDING: Lazy<Mutex<HashMap<String, Pending>>> = Lazy::new(Default::default);

/// a preview waits for its yes; sheets closed without one are dropped once there are many
fn remember(token: String, p: Pending) {
    let mut m = PENDING.lock().unwrap();
    if m.len() >= 16 {
        m.clear();
    }
    m.insert(token, p);
}

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

/// a path or a file:// url (what the ui's file dialogs give)
pub fn local_path(path: &str) -> String {
    let path = path.strip_prefix("file://").map(|p| urlencoding::decode(p).map(|c| c.into_owned()).unwrap_or_else(|_| p.to_owned())).unwrap_or_else(|| path.to_owned());
    // windows: file:///C:/...
    if cfg!(windows) { path.trim_start_matches('/').to_owned() } else { path }
}

fn read_file(path: &str) -> Result<String> {
    let path = local_path(path);
    let meta = std::fs::metadata(&path).context("Couldn't open that file")?;
    if meta.len() as usize > MAX_BYTES {
        bail!("That file is too big for an extension");
    }
    std::fs::read_to_string(&path).context("Couldn't read that file")
}

pub fn token() -> String {
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
    if v.get("kind").and_then(Value::as_str) == Some("profile") {
        bail!("That's a profile: import it in Settings › Profiles");
    }
    if v.get("noonix").is_some() {
        let m = parse(&text)?;
        return describe_extension(m, source).await;
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
    remember(t, Pending::Addon { url: a.manifest_url });
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
            json!({ "id": id, "key": key, "name": name, "set": config::has_secret(key), "bundled": m.keys.contains_key(*id), "hosts": hosts })
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

async fn describe_extension(m: Manifest, source: String) -> Result<Value> {
    let t = token();
    let hosts = hosts(&m);
    let installed = store::with({
        let id = m.id.clone();
        move |c| Ok(c.query_row("select version from extensions where id = ?1", params![id], |r| r.get::<_, String>(0)).optional()?)
    })
    .await?;
    let out = json!({
        "token": t, "kind": "extension", "id": m.id, "name": m.name, "version": m.version,
        "description": m.description, "author": m.author,
        "addons": m.addons.len(), "hosts": hosts, "keys": key_lines(&m),
        "torrents": m.torrents, "patterns": m.patterns,
        "installed": installed.is_some(), "installedVersion": installed,
        "source": if source == "file" { "file".to_owned() } else { config::preview(&source) },
    });
    remember(t, Pending::Extension { m: Box::new(m), source });
    Ok(out)
}

/// the user said yes on the sheet
pub async fn install(token: &str) -> Result<Value> {
    let p = PENDING.lock().unwrap().remove(token).context("That preview is gone: add it again")?;
    match p {
        Pending::Addon { url } => {
            let row = crate::addons::add(&url).await?;
            Ok(json!({ "kind": "addon", "id": row.id, "name": row.name }))
        }
        Pending::Extension { mut m, source } => {
            let (id, name, torrents) = (m.id.clone(), m.name.clone(), m.torrents);
            // its keys where the install has none; one its service refuses is asked for like a missing one
            for (did, value) in std::mem::take(&mut m.keys) {
                let Some(key) = config::DEBRIDS.iter().find(|d| d.0 == did).map(|d| d.1) else { continue };
                if !config::has_secret(key) {
                    if let Err(e) = crate::setup::set_credential(key, &json!(value)).await {
                        tracing::warn!("extension {id}: its key: {e:#}");
                    }
                }
            }
            let added = add(&m, &source, true).await?;
            let needs: Vec<Value> = key_lines(&m).into_iter().filter(|k| k["set"] == false).collect();
            Ok(json!({ "kind": "extension", "id": id, "name": name, "addons": added, "torrents": torrents, "needKeys": needs }))
        }
    }
}

/// stores it (or the newer version of it) and adds its addons; how many it has now
pub async fn add(m: &Manifest, source: &str, on: bool) -> Result<usize> {
    let text = serde_json::to_string(&Manifest { keys: BTreeMap::new(), ..m.clone() })?;
    let row = (m.id.clone(), m.name.clone(), m.version.clone(), source.to_owned());
    store::with(move |c| {
        c.execute(
            "insert into extensions (id, name, version, source, manifest, enabled, added) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             on conflict(id) do update set name = excluded.name, version = excluded.version, source = excluded.source, manifest = excluded.manifest",
            params![row.0, row.1, row.2, row.3, text, on as i64, store::now()],
        )?;
        Ok(())
    })
    .await?;
    sync(&m.id).await
}

pub fn manifests(c: &Connection, only_enabled: bool) -> Result<Vec<(String, bool, String, Manifest)>> {
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
        // a key only for a service its addresses use
        let keyed = |k: &str| SAMPLE.replace("\"noonix\": 1,", &format!("\"noonix\": 1, \"keys\": {{{k}}},"));
        assert_eq!(parse(&keyed("\"torbox\": \"abc\"")).unwrap().keys["torbox"], "abc");
        assert!(parse(&keyed("\"alldebrid\": \"abc\"")).is_err());
        assert!(parse(&keyed("\"torbox\": \" \"")).is_err());
    }

    #[test]
    fn settings_go_into_the_address() {
        use base64::Engine;
        let text = r#"{ "noonix": 1, "id": "example.settings", "name": "Settings",
            "addons": [{ "url": "https://addon.example.com/{config}/manifest.json",
                         "config": { "services": [{ "service": "torbox", "key": "{torbox}" }], "torrents": true } }] }"#;
        let m = parse(text).unwrap();
        assert_eq!(m.needs(), vec!["torbox"]);
        assert_eq!(host(&m.addons[0]), "addon.example.com");
        assert_eq!(render(&m.addons[0], |_| None), None);
        // stored and read back as the same template
        let again: Manifest = serde_json::from_str(&serde_json::to_string(&m).unwrap()).unwrap();
        assert_eq!(again.addons, m.addons);
        for key in ["a\"b/c", "abc", "k+e/y?=="] {
            let url = render(&m.addons[0], |_| Some(key.into())).unwrap();
            let part = url.strip_prefix("https://addon.example.com/").unwrap().strip_suffix("/manifest.json").unwrap();
            assert!(!part.contains(['/', '+']), "{part}");
            let v: Value = serde_json::from_slice(&base64::engine::general_purpose::STANDARD.decode(part).unwrap()).unwrap();
            assert_eq!(v["services"][0]["key"], key);
            assert_eq!(v["torrents"], true);
        }
        // any key fits: uuid-like ones in longer settings
        let long = text.replace("\"torrents\": true", "\"torrents\": true, \"languages\": { \"exclude\": [], \"preferred\": [\"en\", \"sr\"] }, \"maxSize\": 0, \"cachedOnly\": false, \"resultFormat\": [\"all\"]");
        let m = parse(&long).unwrap();
        let mut seed = 7u64;
        for _ in 0..500 {
            let key: String = (0..36).map(|i| {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                if [8, 13, 18, 23].contains(&i) { '-' } else { b"0123456789abcdef"[(seed >> 60) as usize] as char }
            }).collect();
            let url = render(&m.addons[0], |_| Some(key.clone())).unwrap();
            let part = url.strip_prefix("https://addon.example.com/").unwrap().strip_suffix("/manifest.json").unwrap();
            assert!(!part.contains(['/', '+']));
            let v: Value = serde_json::from_slice(&base64::engine::general_purpose::STANDARD.decode(part).unwrap()).unwrap();
            assert_eq!(v["services"][0]["key"], key.as_str());
        }
        assert!(parse(&text.replace("/{config}/", "/")).is_err());
        assert!(parse(&text.replace("\"config\": {", "\"config\": [{").replace("true } }]", "true }] }]")).is_err());
    }
}
