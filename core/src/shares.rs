// network shares: smb, webdav and ftp folders as library folders, like other players have them.
// a share is saved with its login (the password in secrets); its folders and files are paths like
// smb://nas/Media/Movies/x.mkv. a file plays through a local http server with ranges (like a
// torrent), so mpv needs nothing of its own on any platform
use crate::store;
use anyhow::{anyhow, bail, Context, Result};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, OnceCell};

/// smb, webdav over http or https, ftp
pub const KINDS: &[&str] = &["smb", "dav", "davs", "ftp"];

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Share {
    pub id: String,
    pub kind: String,
    pub host: String,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub user: String,
    /// the folder on the server it starts at ("" = the server: smb lists its shares)
    #[serde(default)]
    pub base: String,
}

impl Share {
    fn authority(&self) -> String {
        match self.port {
            Some(p) => format!("{}:{p}", self.host),
            None => self.host.clone(),
        }
    }
    pub fn root(&self) -> String {
        let base = self.base.trim_matches('/');
        if base.is_empty() { format!("{}://{}", self.kind, self.authority()) } else { format!("{}://{}/{base}", self.kind, self.authority()) }
    }
    fn label(&self) -> String {
        let who = if self.user.is_empty() { String::new() } else { format!("{}@", self.user) };
        let base = self.base.trim_matches('/');
        let name = match self.kind.as_str() {
            "smb" => "SMB",
            "ftp" => "FTP",
            _ => "WebDAV",
        };
        format!("{name}  ·  {who}{}{}{base}", self.authority(), if base.is_empty() { "" } else { "/" })
    }
}

/// a path inside a share: the share, its password and the part after the server ("Media/Movies")
struct At {
    share: Share,
    password: String,
    rest: String,
}

pub fn is_share(path: &str) -> bool {
    KINDS.iter().any(|k| path.strip_prefix(k).is_some_and(|r| r.starts_with("://")))
}

/// kind, authority and the rest of a share path
fn split(path: &str) -> Option<(&str, &str, &str)> {
    let (kind, r) = path.split_once("://")?;
    let (auth, rest) = r.split_once('/').unwrap_or((r, ""));
    Some((kind, auth, rest.trim_matches('/')))
}

pub async fn list() -> Vec<Share> {
    store::with(|c| store::get_setting(c, "app", "shares"))
        .await
        .ok()
        .flatten()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default()
}

async fn at(path: &str) -> Result<At> {
    let (kind, auth, rest) = split(path).context("That isn't a network share")?;
    let shares = list().await;
    // the share of this server whose folder the path is in (the longest), else any of the server
    let share = shares
        .iter()
        .filter(|s| s.kind == kind && s.authority().eq_ignore_ascii_case(auth))
        .filter(|s| {
            let b = s.base.trim_matches('/');
            b.is_empty() || rest == b || rest.starts_with(&format!("{b}/"))
        })
        .max_by_key(|s| s.base.len())
        .or_else(|| shares.iter().find(|s| s.kind == kind && s.authority().eq_ignore_ascii_case(auth)))
        .cloned()
        .context("That network share isn't saved anymore")?;
    let key = format!("share.{}", share.id);
    let password = store::with(move |c| Ok(store::secrets(c)?.get(&key).cloned().unwrap_or_default())).await?;
    Ok(At { share, password, rest: rest.to_owned() })
}

/// what was typed: an address ("nas.local/Media", "192.168.1.5:2121", "smb://nas/Media", a webdav
/// url) and the kind picked
fn parse(kind: &str, address: &str, user: &str) -> Result<Share> {
    let a = address.trim();
    let (mut kind, rest) = match a.split_once("://") {
        Some((k, r)) => {
            let k = k.to_lowercase();
            let k = match k.as_str() {
                "http" | "webdav" => "dav".to_owned(),
                "https" | "webdavs" => "davs".to_owned(),
                "cifs" => "smb".to_owned(),
                _ => k,
            };
            (k, r)
        }
        None => (kind.to_owned(), a),
    };
    // \\nas\share from windows
    let rest = rest.trim_start_matches(['\\', '/']).replace('\\', "/");
    if !KINDS.contains(&kind.as_str()) {
        bail!("Pick SMB, WebDAV or FTP");
    }
    let (auth, base) = rest.split_once('/').unwrap_or((rest.as_str(), ""));
    // user@host in the address
    let (user_in, auth) = match auth.rsplit_once('@') {
        Some((u, h)) => (Some(u.split(':').next().unwrap_or(u).to_owned()), h),
        None => (None, auth),
    };
    let (host, port) = match auth.rsplit_once(':') {
        Some((h, p)) if !h.contains(':') || h.starts_with('[') => (h.to_owned(), Some(p.parse::<u16>().map_err(|_| anyhow!("That port isn't a number"))?)),
        _ => (auth.to_owned(), None),
    };
    if host.is_empty() {
        bail!("Type the server's name or address");
    }
    if kind == "dav" && port == Some(443) {
        kind = "davs".into();
    }
    let user = if user.trim().is_empty() { user_in.unwrap_or_default() } else { user.trim().to_owned() };
    let mut id = [0u8; 6];
    getrandom::fill(&mut id).ok();
    Ok(Share {
        id: id.iter().map(|b| format!("{b:02x}")).collect(),
        kind,
        host,
        port,
        user,
        base: urlencoding::decode(base.trim_matches('/')).map(|s| s.into_owned()).unwrap_or_else(|_| base.trim_matches('/').to_owned()),
    })
}

/// saves a share once it answers: {path, name} of its first folder
pub async fn add(kind: &str, address: &str, user: &str, password: &str) -> Result<Value> {
    let share = parse(kind, address, user)?;
    let probe = At { share: share.clone(), password: password.to_owned(), rest: share.base.trim_matches('/').to_owned() };
    tokio::time::timeout(Duration::from_secs(20), entries(&probe)).await.map_err(|_| anyhow!("The server didn't answer"))??;
    let mut shares = list().await;
    // the same server and folder again: the new login replaces the old
    shares.retain(|s| !(s.kind == share.kind && s.authority().eq_ignore_ascii_case(&share.authority()) && s.base == share.base));
    shares.push(share.clone());
    let (v, key, pw) = (json!(shares), format!("share.{}", share.id), password.to_owned());
    store::with(move |c| {
        store::set_setting(c, "app", "shares", &v)?;
        store::set_secret(c, &key, if pw.is_empty() { None } else { Some(&pw) })
    })
    .await?;
    forget_client(&share.id).await;
    tracing::info!("share added: {}", share.label());
    Ok(json!({ "path": share.root(), "name": share.host }))
}

/// forgets the share a path is in, and the library folders on it
pub async fn remove(path: &str) -> Result<Value> {
    let a = at(path).await?;
    let root = a.share.root();
    let mut shares = list().await;
    shares.retain(|s| s.id != a.share.id);
    let mut folders = crate::library::folders().await;
    folders.retain(|f| !(f == &root || f.starts_with(&format!("{root}/"))));
    let (v, f, key) = (json!(shares), json!(folders), format!("share.{}", a.share.id));
    store::with(move |c| {
        store::set_setting(c, "app", "shares", &v)?;
        store::set_setting(c, "app", "library_folders", &f)?;
        store::set_secret(c, &key, None)
    })
    .await?;
    forget_client(&a.share.id).await;
    crate::library::scan_later();
    Ok(json!({}))
}

/// the saved shares as places of the folder picker
pub async fn places() -> Vec<Value> {
    list().await.iter().map(|s| json!({ "name": s.host, "path": s.root(), "label": s.label(), "place": "share" })).collect()
}

/// one entry of a share's folder
#[derive(Debug, Clone)]
pub struct Entry {
    pub name: String,
    pub dir: bool,
    pub size: u64,
    pub mtime: i64,
}

async fn entries(a: &At) -> Result<Vec<Entry>> {
    let mut out = match a.share.kind.as_str() {
        "smb" => smb_list(a).await,
        "ftp" => ftp_list(a).await,
        _ => dav_list(a).await,
    }?;
    out.retain(|e| e.name != "." && e.name != ".." && !e.name.is_empty());
    Ok(out)
}

/// a share's folder for the picker, like library::browse
pub async fn browse(path: &str) -> Result<Value> {
    let path = path.trim_end_matches('/');
    let a = at(path).await?;
    let list = tokio::time::timeout(Duration::from_secs(25), entries(&a)).await.map_err(|_| anyhow!("The server didn't answer"))?.map_err(|e| {
        tracing::warn!("share {path}: {e:#}");
        anyhow!("Couldn't open that folder")
    })?;
    let mut folders: Vec<&Entry> = list.iter().filter(|e| e.dir && !e.name.starts_with('.') && !e.name.ends_with('$')).collect();
    folders.sort_by_key(|e| e.name.to_lowercase());
    let videos = list.iter().filter(|e| !e.dir && video(&e.name)).count();
    let root = a.share.root();
    let at_root = path.eq_ignore_ascii_case(&root);
    let parent = if at_root { String::new() } else { path.rsplit_once('/').map(|(p, _)| p.to_owned()).unwrap_or_default() };
    let name = if at_root { a.share.host.clone() } else { path.rsplit('/').next().unwrap_or(path).to_owned() };
    Ok(json!({
        "path": path, "name": name, "label": label(path), "parent": parent,
        "parentLabel": if parent.is_empty() { String::new() } else { label(&parent) }, "videos": videos,
        "folders": folders.iter().map(|e| json!({ "name": e.name, "path": format!("{path}/{}", e.name) })).collect::<Vec<_>>(),
        "files": [], "share": true, "shareRoot": at_root,
    }))
}

/// a share path as people read it (no login in it)
pub fn label(path: &str) -> String {
    match split(path) {
        Some((kind, auth, rest)) => {
            let name = match kind {
                "smb" => "SMB",
                "ftp" => "FTP",
                _ => "WebDAV",
            };
            if rest.is_empty() { format!("{name}  ·  {auth}") } else { format!("{name}  ·  {auth}/{rest}") }
        }
        None => path.to_owned(),
    }
}

fn video(name: &str) -> bool {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    crate::library::VIDEO.contains(&ext.as_str())
}

/// the video files under a library folder on a share, like library::walk: (path, size, mtime)
pub async fn walk(root: &str) -> Result<Vec<(String, u64, i64)>> {
    let root = root.trim_end_matches('/');
    let a = at(root).await?;
    // the folder has to answer; folders inside that don't are skipped
    let first = entries(&a).await?;
    let mut out = Vec::new();
    let mut todo: Vec<(String, usize, Vec<Entry>)> = vec![(root.to_owned(), 0, first)];
    while let Some((dir, depth, list)) = todo.pop() {
        for e in list {
            let lower = e.name.to_lowercase();
            if lower.starts_with('.') {
                continue;
            }
            let path = format!("{dir}/{}", e.name);
            if e.dir {
                if depth < 8 && !crate::library::skipped_dir(&lower) && !lower.ends_with('$') {
                    let sub = At { share: a.share.clone(), password: a.password.clone(), rest: split(&path).map(|s| s.2.to_owned()).unwrap_or_default() };
                    match entries(&sub).await {
                        Ok(l) => todo.push((path, depth + 1, l)),
                        Err(err) => tracing::debug!("share {path}: {err:#}"),
                    }
                }
            } else if video(&e.name) && crate::library::wanted(&lower, e.size) {
                out.push((path, e.size, e.mtime));
            }
        }
    }
    Ok(out)
}

// ---- smb

static SMB: Lazy<Mutex<HashMap<String, Arc<smb::Client>>>> = Lazy::new(|| Mutex::new(HashMap::new()));

async fn forget_client(id: &str) {
    if let Some(c) = SMB.lock().await.remove(id) {
        c.close().await.ok();
    }
}

fn smb_user(a: &At) -> String {
    if a.share.user.is_empty() { "Guest".into() } else { a.share.user.clone() }
}

/// a client for the share's server, with the share of `rest` connected
async fn smb_client(a: &At, share_name: Option<&str>) -> Result<Arc<smb::Client>> {
    let mut map = SMB.lock().await;
    let client = match map.get(&a.share.id) {
        Some(c) => c.clone(),
        None => {
            let mut cfg = smb::ClientConfig::default();
            cfg.connection.port = a.share.port;
            cfg.connection.timeout = Some(Duration::from_secs(15));
            cfg.connection.allow_unsigned_guest_access = true;
            let c = Arc::new(smb::Client::new(cfg));
            map.insert(a.share.id.clone(), c.clone());
            c
        }
    };
    drop(map);
    let unc = match share_name {
        Some(s) => smb::UncPath::new(&a.share.host).map_err(|e| anyhow!("{e}"))?.with_share(s).map_err(|e| anyhow!("{e}"))?,
        None => smb::UncPath::ipc_share(&a.share.host).map_err(|e| anyhow!("{e}"))?,
    };
    // connecting twice is a no-op (a warning in its log)
    if client.get_tree(&unc).await.is_err() {
        let r = match share_name {
            Some(_) => client.share_connect(&unc, &smb_user(a), a.password.clone()).await,
            None => client.ipc_connect(&a.share.host, &smb_user(a), a.password.clone()).await,
        };
        if let Err(e) = r {
            forget_client(&a.share.id).await;
            return Err(smb_error(e));
        }
    }
    Ok(client)
}

fn smb_error(e: smb::Error) -> anyhow::Error {
    let t = e.to_string();
    tracing::debug!("smb: {t}");
    if t.contains("LOGON_FAILURE") || t.contains("ACCESS_DENIED") || t.to_lowercase().contains("logon") {
        anyhow!("The name or password isn't right")
    } else if t.contains("BAD_NETWORK_NAME") {
        anyhow!("That share isn't on the server")
    } else if t.contains("NOT_FOUND") {
        anyhow!("That folder isn't there")
    } else {
        anyhow!("Couldn't reach the server")
    }
}

/// "Media/Movies/x.mkv" -> the share "Media" and "Movies\x.mkv" in it
fn smb_parts(rest: &str) -> (Option<String>, String) {
    match rest.split_once('/') {
        Some((s, p)) => (Some(s.to_owned()), p.replace('/', "\\")),
        None if rest.is_empty() => (None, String::new()),
        None => (Some(rest.to_owned()), String::new()),
    }
}

fn unc(a: &At, share: &str, p: &str) -> Result<smb::UncPath> {
    let u = smb::UncPath::new(&a.share.host).map_err(|e| anyhow!("{e}"))?.with_share(share).map_err(|e| anyhow!("{e}"))?;
    Ok(if p.is_empty() { u } else { u.with_path(p) })
}

async fn smb_list(a: &At) -> Result<Vec<Entry>> {
    use futures::StreamExt;
    let (share, p) = smb_parts(&a.rest);
    let Some(share) = share else {
        // the server: its shares
        let client = smb_client(a, None).await?;
        // samba can't list its shares to this client (ndr64): the share's name has to be typed
        let shares = client.list_shares(&a.share.host).await.map_err(|e| {
            tracing::debug!("smb shares of {}: {e}", a.share.host);
            anyhow!("Add the share's name to the address, like nas.local/Media")
        })?;
        return Ok(shares
            .iter()
            .filter(|s| !s.share_type.special())
            .filter_map(|s| s.netname.as_ref().map(|n| n.to_string()))
            .filter(|n| !n.ends_with('$'))
            .map(|name| Entry { name, dir: true, size: 0, mtime: 0 })
            .collect());
    };
    let client = smb_client(a, Some(&share)).await?;
    let args = smb::FileCreateArgs::make_open_existing(smb::DirAccessMask::new().with_list_directory(true).with_synchronize(true).into());
    let res = client.create_file(&unc(a, &share, &p)?, &args).await.map_err(smb_error)?;
    let smb::Resource::Directory(dir) = res else { bail!("That folder isn't there") };
    let dir = Arc::new(dir);
    let mut out = Vec::new();
    {
        let mut st = smb::Directory::query::<smb::FileDirectoryInformation>(&dir, "*").await.map_err(smb_error)?;
        while let Some(item) = st.next().await {
            let Ok(i) = item else { break };
            let name = String::try_from(i.file_name.clone()).unwrap_or_default();
            let t = *i.last_write_time;
            let mtime = if t == 0 { 0 } else { (t / 10_000_000) as i64 - 11_644_473_600 };
            out.push(Entry { name, dir: i.file_attributes.directory(), size: i.end_of_file, mtime });
        }
    }
    dir.close().await.ok();
    Ok(out)
}

async fn smb_open(a: &At) -> Result<smb::File> {
    let (share, p) = smb_parts(&a.rest);
    let share = share.context("That file isn't there")?;
    let client = smb_client(a, Some(&share)).await?;
    let args = smb::FileCreateArgs::make_open_existing(smb::FileAccessMask::new().with_generic_read(true));
    match client.create_file(&unc(a, &share, &p)?, &args).await.map_err(smb_error)? {
        smb::Resource::File(f) => Ok(f),
        _ => bail!("That isn't a file"),
    }
}

// ---- ftp

type Ftp = suppaftp::tokio::AsyncFtpStream;

async fn ftp_connect(a: &At) -> Result<Ftp> {
    let addr = format!("{}:{}", a.share.host, a.share.port.unwrap_or(21));
    let mut ftp = tokio::time::timeout(Duration::from_secs(10), Ftp::connect(addr.clone())).await.map_err(|_| anyhow!("The server didn't answer"))?.map_err(|e| {
        tracing::debug!("ftp {addr}: {e}");
        anyhow!("Couldn't reach the server")
    })?;
    let user = if a.share.user.is_empty() { "anonymous" } else { a.share.user.as_str() };
    let pass = if a.share.user.is_empty() && a.password.is_empty() { "noonix@" } else { a.password.as_str() };
    ftp.login(user, pass).await.map_err(|e| {
        tracing::debug!("ftp login: {e}");
        anyhow!("The name or password isn't right")
    })?;
    ftp.transfer_type(suppaftp::types::FileType::Binary).await.ok();
    Ok(ftp)
}

/// paths stay under where the login starts ("" = there)
fn ftp_path(rest: &str) -> Option<String> {
    (!rest.is_empty()).then(|| rest.to_owned())
}

async fn ftp_list(a: &At) -> Result<Vec<Entry>> {
    let mut ftp = ftp_connect(a).await?;
    let p = ftp_path(&a.rest);
    let out: Vec<Entry> = match ftp.mlsd(p.as_deref()).await {
        Ok(lines) => lines.iter().filter_map(|l| suppaftp::list::ListParser::parse_mlsd(l).ok()).map(ftp_entry).collect(),
        Err(_) => {
            let lines = ftp.list(p.as_deref()).await.map_err(|e| {
                tracing::debug!("ftp list: {e}");
                anyhow!("Couldn't open that folder")
            })?;
            lines.iter().filter_map(|l| l.parse::<suppaftp::list::File>().ok()).map(ftp_entry).collect()
        }
    };
    ftp.quit().await.ok();
    Ok(out)
}

fn ftp_entry(f: suppaftp::list::File) -> Entry {
    let mtime = f.modified().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    Entry { name: f.name().to_owned(), dir: f.is_directory(), size: f.size() as u64, mtime }
}

// ---- webdav

/// a client without the api client's overall timeout (a stream runs for hours)
static DAV: Lazy<reqwest::Client> = Lazy::new(|| {
    crate::http::builder()
        .user_agent(concat!("NoonixTV/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(30))
        .build()
        .expect("http client")
});

fn dav_url(a: &At, rest: &str) -> String {
    let scheme = if a.share.kind == "davs" { "https" } else { "http" };
    let enc: Vec<String> = rest.split('/').filter(|s| !s.is_empty()).map(|s| urlencoding::encode(s).into_owned()).collect();
    format!("{scheme}://{}/{}", a.share.authority(), enc.join("/"))
}

fn dav_req(a: &At, method: reqwest::Method, url: &str) -> reqwest::RequestBuilder {
    let r = DAV.request(method, url);
    if a.share.user.is_empty() { r } else { r.basic_auth(&a.share.user, Some(&a.password)) }
}

async fn dav_list(a: &At) -> Result<Vec<Entry>> {
    let mut url = dav_url(a, &a.rest);
    if !url.ends_with('/') {
        url.push('/');
    }
    let body = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#;
    let r = dav_req(a, reqwest::Method::from_bytes(b"PROPFIND")?, &url)
        .header("depth", "1")
        .header("content-type", "application/xml")
        .body(body)
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| {
            tracing::debug!("webdav {url}: {e}");
            anyhow!("Couldn't reach the server")
        })?;
    match r.status().as_u16() {
        401 | 403 => bail!("The name or password isn't right"),
        404 => bail!("That folder isn't there"),
        207 => {}
        s => {
            tracing::debug!("webdav {url}: {s}");
            bail!("That doesn't look like a WebDAV address")
        }
    }
    let xml = r.text().await?;
    let own = url::Url::parse(&url)?.path().trim_end_matches('/').to_owned();
    Ok(dav_parse(&xml).into_iter().filter(|(href, _)| href.trim_end_matches('/') != own).map(|(_, e)| e).collect())
}

/// a propfind answer: (href's path, entry) per response
fn dav_parse(xml: &str) -> Vec<(String, Entry)> {
    use quick_xml::events::Event;
    let mut rd = quick_xml::Reader::from_str(xml);
    let (mut out, mut cur, mut field) = (Vec::new(), None::<(String, Entry)>, String::new());
    loop {
        match rd.read_event() {
            Ok(Event::Start(e)) => {
                let n = e.local_name().as_ref().to_lowercase();
                if n == "response" {
                    cur = Some((String::new(), Entry { name: String::new(), dir: false, size: 0, mtime: 0 }));
                } else if n == "collection" {
                    if let Some(c) = cur.as_mut() {
                        c.1.dir = true;
                    }
                }
                field = n;
            }
            Ok(Event::Empty(e)) => {
                if e.local_name().as_ref().eq_ignore_ascii_case("collection") {
                    if let Some(c) = cur.as_mut() {
                        c.1.dir = true;
                    }
                }
            }
            // text comes in pieces: &amp; and the like on their own
            ev @ (Ok(Event::Text(_)) | Ok(Event::GeneralRef(_))) => {
                let Some(c) = cur.as_mut() else { continue };
                let v = match ev {
                    Ok(Event::Text(t)) => t.as_ref().to_owned(),
                    Ok(Event::GeneralRef(r)) => match r.resolve_char_ref() {
                        Ok(Some(ch)) => ch.to_string(),
                        _ => match r.as_ref() {
                            "amp" => "&",
                            "lt" => "<",
                            "gt" => ">",
                            "quot" => "\"",
                            "apos" => "'",
                            _ => "",
                        }
                        .to_owned(),
                    },
                    _ => String::new(),
                };
                match field.as_str() {
                    "href" => c.0.push_str(&v),
                    "getcontentlength" => c.1.size = v.trim().parse().unwrap_or(c.1.size),
                    "getlastmodified" => c.1.mtime = chrono::DateTime::parse_from_rfc2822(v.trim()).map_or(c.1.mtime, |d| d.timestamp()),
                    _ => {}
                }
            }
            Ok(Event::End(e)) => {
                let n = e.local_name().as_ref().to_lowercase();
                if n == "href" {
                    if let Some(c) = cur.as_mut() {
                        c.0 = c.0.trim().to_owned();
                    }
                }
                if e.local_name().as_ref().eq_ignore_ascii_case("response") {
                    if let Some((href, mut entry)) = cur.take() {
                        // a full url or a path, percent-encoded
                        let path = url::Url::parse(&href).map(|u| u.path().to_owned()).unwrap_or(href);
                        let path = urlencoding::decode(&path).map(|s| s.into_owned()).unwrap_or(path);
                        entry.name = path.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_owned();
                        out.push((path, entry));
                    }
                }
                field.clear();
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    out
}

// ---- playing: a local http server

static PORT: OnceCell<u16> = OnceCell::const_new();
/// token -> share path, for the urls handed out
static SERVED: Lazy<std::sync::Mutex<HashMap<String, String>>> = Lazy::new(|| std::sync::Mutex::new(HashMap::new()));

/// a share file as an http url mpv can play (and seek in)
pub async fn url_for(path: &str) -> Result<String> {
    at(path).await?;
    let port = server().await?;
    let token: String = {
        use sha2::Digest;
        sha2::Sha256::digest(path.as_bytes()).iter().take(10).map(|b| format!("{b:02x}")).collect()
    };
    SERVED.lock().unwrap().insert(token.clone(), path.to_owned());
    let name = path.rsplit('/').next().unwrap_or("video");
    Ok(format!("http://127.0.0.1:{port}/{token}/{}", urlencoding::encode(name)))
}

async fn server() -> Result<u16> {
    PORT.get_or_try_init(|| async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                tokio::spawn(async move {
                    if let Err(e) = serve(sock).await {
                        tracing::debug!("share http: {e:#}");
                    }
                });
            }
        });
        Ok::<u16, anyhow::Error>(port)
    })
    .await
    .copied()
}

/// one request per connection: GET or HEAD /<token>/<name>, with or without a range
async fn serve(mut sock: TcpStream) -> Result<()> {
    let mut head = Vec::new();
    let mut buf = [0u8; 2048];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = sock.read(&mut buf).await?;
        if n == 0 || head.len() > 16384 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
    }
    let text = String::from_utf8_lossy(&head);
    let mut lines = text.lines();
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, target) = (first.next().unwrap_or("").to_owned(), first.next().unwrap_or("").to_owned());
    let range = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_owned());
    let token = target.trim_start_matches('/').split('/').next().unwrap_or("").to_owned();
    let path = SERVED.lock().unwrap().get(&token).cloned();
    let Some(path) = path else {
        sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    };
    let a = at(&path).await?;
    let mut src = Source::open(&a).await.inspect_err(|e| tracing::warn!("share {path}: {e:#}"))?;
    let len = src.len();
    let (start, end) = crate::torrent::parse_range(range.as_deref(), len);
    if start >= len && len > 0 {
        let h = format!("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{len}\r\nConnection: close\r\n\r\n");
        sock.write_all(h.as_bytes()).await?;
        return Ok(());
    }
    let count = end + 1 - start;
    let status = if range.is_some() { "206 Partial Content" } else { "200 OK" };
    let mut h = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: {count}\r\nConnection: close\r\n"
    );
    if range.is_some() {
        h.push_str(&format!("Content-Range: bytes {start}-{end}/{len}\r\n"));
    }
    h.push_str("\r\n");
    sock.write_all(h.as_bytes()).await?;
    if method == "HEAD" || count == 0 {
        return Ok(());
    }
    src.copy(&a, start, count, &mut sock).await
}

/// an open share file
enum Source {
    Smb(smb::File, u64),
    Ftp(u64),
    Dav(u64),
}

impl Source {
    async fn open(a: &At) -> Result<Self> {
        match a.share.kind.as_str() {
            "smb" => {
                use smb::GetLen;
                let f = smb_open(a).await?;
                let len = f.get_len().await.map_err(|e| anyhow!("{e}"))?;
                Ok(Source::Smb(f, len))
            }
            "ftp" => {
                let mut ftp = ftp_connect(a).await?;
                let len = ftp.size(&a.rest).await.map_err(|e| anyhow!("That file isn't there ({e})"))? as u64;
                ftp.quit().await.ok();
                Ok(Source::Ftp(len))
            }
            _ => {
                let r = dav_req(a, reqwest::Method::HEAD, &dav_url(a, &a.rest)).timeout(Duration::from_secs(20)).send().await?;
                if !r.status().is_success() {
                    bail!("the server said {}", r.status());
                }
                let len = r.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|v| v.parse().ok()).unwrap_or(0);
                Ok(Source::Dav(len))
            }
        }
    }

    fn len(&self) -> u64 {
        match self {
            Source::Smb(_, l) | Source::Ftp(l) | Source::Dav(l) => *l,
        }
    }

    /// count bytes from start to the socket
    async fn copy(&mut self, a: &At, start: u64, count: u64, sock: &mut TcpStream) -> Result<()> {
        match self {
            Source::Smb(f, _) => {
                // a few reads in flight keep a remote share at full speed
                let r = smb_copy(f, start, count, sock).await;
                f.close().await.ok();
                r
            }
            Source::Ftp(_) => {
                let mut ftp = ftp_connect(a).await?;
                if start > 0 {
                    ftp.resume_transfer(start as usize).await?;
                }
                let mut stream = ftp.retr_as_stream(&a.rest).await.map_err(|e| anyhow!("{e}"))?;
                tokio::io::copy(&mut (&mut stream).take(count), sock).await?;
                // the rest isn't wanted: the connection just goes
                drop(stream);
                Ok(())
            }
            Source::Dav(_) => {
                use futures::StreamExt;
                let end = start + count - 1;
                let r = dav_req(a, reqwest::Method::GET, &dav_url(a, &a.rest)).header("range", format!("bytes={start}-{end}")).send().await?;
                if !r.status().is_success() {
                    bail!("the server said {}", r.status());
                }
                // a server without ranges sends it all from the start
                let mut skip = if r.status().as_u16() == 206 { 0 } else { start };
                let mut left = count;
                let mut body = r.bytes_stream();
                while let Some(chunk) = body.next().await {
                    let mut c = chunk?;
                    if skip > 0 {
                        let n = skip.min(c.len() as u64) as usize;
                        c = c.slice(n..);
                        skip -= n as u64;
                    }
                    let n = left.min(c.len() as u64) as usize;
                    sock.write_all(&c[..n]).await?;
                    left -= n as u64;
                    if left == 0 {
                        break;
                    }
                }
                Ok(())
            }
        }
    }
}

async fn smb_copy(f: &smb::File, start: u64, count: u64, sock: &mut TcpStream) -> Result<()> {
    use futures::stream::{self, StreamExt};
    const BLOCK: u64 = 1 << 20;
    let blocks = count.div_ceil(BLOCK);
    let mut reads = stream::iter(0..blocks)
        .map(|i| async move {
            let pos = start + i * BLOCK;
            let want = BLOCK.min(start + count - pos) as usize;
            let mut buf = vec![0u8; want];
            let mut got = 0;
            while got < want {
                let n = f.read_block(&mut buf[got..], pos + got as u64, None, false).await?;
                if n == 0 {
                    break;
                }
                got += n;
            }
            buf.truncate(got);
            Ok::<_, std::io::Error>(buf)
        })
        .buffered(4);
    while let Some(b) = reads.next().await {
        let b = b?;
        if b.is_empty() {
            break;
        }
        sock.write_all(&b).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_addresses() {
        let s = parse("smb", "nas.local/Media", "").unwrap();
        assert_eq!((s.kind.as_str(), s.host.as_str(), s.port, s.base.as_str()), ("smb", "nas.local", None, "Media"));
        assert_eq!(s.root(), "smb://nas.local/Media");
        let s = parse("smb", r"\\192.168.1.5\Movies", "me").unwrap();
        assert_eq!((s.host.as_str(), s.base.as_str(), s.user.as_str()), ("192.168.1.5", "Movies", "me"));
        let s = parse("smb", "https://cloud.example.com/remote.php/dav/files/me", "").unwrap();
        assert_eq!((s.kind.as_str(), s.base.as_str()), ("davs", "remote.php/dav/files/me"));
        let s = parse("ftp", "me@10.0.0.2:2121", "").unwrap();
        assert_eq!((s.host.as_str(), s.port, s.user.as_str(), s.root()), ("10.0.0.2", Some(2121), "me", "ftp://10.0.0.2:2121".to_owned()));
        assert!(parse("smb", "", "").is_err());
        assert!(is_share("smb://nas/x") && is_share("davs://h/x") && !is_share("/home/x") && !is_share("http://x"));
    }

    #[test]
    fn reads_propfind() {
        let xml = r#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/Movies/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/dav/Movies/Sintel%20(2010)/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>http://h/dav/Movies/a%20b.mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>123</d:getcontentlength>
            <d:getlastmodified>Sat, 07 Nov 2026 10:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response></d:multistatus>"#;
        let r = dav_parse(xml);
        assert_eq!(r.len(), 3);
        assert_eq!((r[1].1.name.as_str(), r[1].1.dir), ("Sintel (2010)", true));
        assert_eq!((r[2].1.name.as_str(), r[2].1.dir, r[2].1.size), ("a b.mkv", false, 123));
        assert!(r[2].1.mtime > 0);
        assert_eq!(r[0].0, "/dav/Movies/");
    }
}

#[cfg(test)]
mod live {
    // against test servers: NOONIX_SHARE_TEST="<share path>|<the same file on disk>;..." (shares
    // already added in this XDG home): cargo test shares::live -- --ignored
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn serves_ranges() {
        let spec = std::env::var("NOONIX_SHARE_TEST").expect("NOONIX_SHARE_TEST");
        let c = reqwest::Client::new();
        for pair in spec.split(';') {
            let (share, local) = pair.split_once('|').unwrap();
            let want = std::fs::read(local).unwrap();
            let url = super::url_for(share).await.unwrap();
            let t = std::time::Instant::now();
            let all = c.get(&url).send().await.unwrap().bytes().await.unwrap();
            assert_eq!(all.len(), want.len(), "{share}");
            assert!(all[..] == want[..], "{share}: whole file differs");
            let full = t.elapsed();
            for (range, from, to) in [("bytes=1000000-1065535", 1000000, 1065536), ("bytes=-1000", want.len() - 1000, want.len()), ("bytes=5000000-", 5000000, want.len())] {
                let r = c.get(&url).header("range", range).send().await.unwrap();
                assert_eq!(r.status().as_u16(), 206, "{share} {range}");
                let b = r.bytes().await.unwrap();
                assert!(b[..] == want[from..to], "{share} {range}");
            }
            println!("{share}: ok, {} MB in {full:?}", want.len() / 1_000_000);
        }
    }
}
