// this computer as a tv's streaming server: noonix tv on lg and samsung tvs has its own small engine,
// but can ask one on the network instead (as stremio can), stremio's way: GET /<info hash>/<file index>, ranges
// for seeking. off until the user turns it on, and only while torrents are allowed. like the app's
// own torrents it only downloads, never uploads; what a tv watched is deleted a while after it stops
use crate::{store, torrent};
use anyhow::{Context, Result};
use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

/// stremio's port: a tv set up for stremio service finds this one the same way
pub const PORT: u16 = 11470;
/// a torrent nobody streamed for this long goes, files and all
const IDLE: Duration = Duration::from_secs(10 * 60);

struct Served {
    handle: Arc<ManagedTorrent>,
    files: HashSet<usize>,
    last: Instant,
    open: usize,
}

static TORRENTS: Lazy<Mutex<HashMap<String, Served>>> = Lazy::new(|| Mutex::new(HashMap::new()));
static RUNNING: Lazy<Mutex<Option<JoinHandle<()>>>> = Lazy::new(|| Mutex::new(None));
/// why it isn't running although it's on (the port is taken: stremio service already is one)
static ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

fn wanted(c: &rusqlite::Connection) -> bool {
    crate::addons::torrents(c) == Some(true)
        && store::get_setting(c, "app", "tvServer").ok().flatten().and_then(|v| v.as_bool()) == Some(true)
}

/// on or off, for the settings line: the address a tv types, or why it can't run
pub async fn state() -> Value {
    let on = store::with(|c| Ok(store::get_setting(c, "app", "tvServer")?.and_then(|v| v.as_bool()) == Some(true))).await.unwrap_or(false);
    let running = RUNNING.lock().map(|r| r.is_some()).unwrap_or(false);
    let error = ERROR.lock().ok().and_then(|e| e.clone());
    json!({ "on": on, "running": running, "address": address().map(|a| format!("{a}:{PORT}")), "error": error })
}

/// the user turned it on or off
pub async fn set(on: bool) -> Result<Value> {
    store::with(move |c| store::set_setting(c, "app", "tvServer", &json!(on))).await?;
    apply().await;
    Ok(state().await)
}

/// running exactly while it's on and torrents are allowed (at start, and after either changes)
pub async fn apply() {
    let want = store::with(|c| Ok(wanted(c))).await.unwrap_or(false);
    let running = RUNNING.lock().map(|r| r.is_some()).unwrap_or(false);
    if want && !running {
        match TcpListener::bind(("0.0.0.0", PORT)).await {
            Ok(listener) => {
                if let Ok(mut e) = ERROR.lock() {
                    *e = None;
                }
                let task = crate::app::RUNTIME.spawn(serve_all(listener));
                if let Ok(mut r) = RUNNING.lock() {
                    *r = Some(task);
                }
                tracing::info!("tv streaming server on port {PORT}");
            }
            Err(e) => {
                tracing::warn!("tv streaming server: {e}");
                if let Ok(mut err) = ERROR.lock() {
                    *err = Some(if e.kind() == std::io::ErrorKind::AddrInUse {
                        "Port 11470 is in use: Stremio Service may already be running here".into()
                    } else {
                        e.to_string()
                    });
                }
            }
        }
    } else if !want && running {
        if let Some(task) = RUNNING.lock().ok().and_then(|mut r| r.take()) {
            task.abort();
        }
        let all: Vec<_> = TORRENTS.lock().map(|mut m| m.drain().map(|(_, s)| s.handle).collect()).unwrap_or_default();
        for h in all {
            drop_torrent(h).await;
        }
        tracing::info!("tv streaming server off");
    }
}

/// this computer's address on the network (the route out, no packet is sent)
fn address() -> Option<std::net::IpAddr> {
    let s = std::net::UdpSocket::bind(("0.0.0.0", 0)).ok()?;
    s.connect(("192.0.2.1", 9)).ok()?;
    s.local_addr().ok().map(|a| a.ip()).filter(|ip| !ip.is_loopback() && !ip.is_unspecified())
}

/// a torrent this server holds (the app's own player leaves it alone)
pub fn holds(hash: &str) -> bool {
    TORRENTS.lock().map(|m| m.contains_key(hash)).unwrap_or(false)
}

async fn drop_torrent(h: Arc<ManagedTorrent>) {
    if torrent::playing().await.as_deref() == Some(&h.info_hash().as_string()) {
        return;
    }
    if let Ok(s) = torrent::session().await {
        if let Err(e) = s.delete(h.id().into(), true).await {
            tracing::debug!("tv server drop: {e:#}");
        }
    }
}

async fn serve_all(listener: TcpListener) {
    // the idle ones go
    crate::app::RUNTIME.spawn(async {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let idle: Vec<_> = TORRENTS
                .lock()
                .map(|mut m| {
                    let gone: Vec<String> = m.iter().filter(|(_, s)| s.open == 0 && s.last.elapsed() > IDLE).map(|(k, _)| k.clone()).collect();
                    gone.into_iter().filter_map(|k| m.remove(&k)).map(|s| s.handle).collect()
                })
                .unwrap_or_default();
            for h in idle {
                drop_torrent(h).await;
            }
            if RUNNING.lock().map(|r| r.is_none()).unwrap_or(true) {
                break;
            }
        }
    });
    while let Ok((sock, _)) = listener.accept().await {
        tokio::spawn(async move {
            if let Err(e) = serve(sock).await {
                tracing::debug!("tv server http: {e:#}");
            }
        });
    }
}

const CORS: &str = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range\r\nAccess-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges\r\n";

async fn reply(sock: &mut TcpStream, status: &str, kind: &str, body: &[u8]) -> Result<()> {
    let h = format!("HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\n{CORS}Connection: close\r\n\r\n", body.len());
    sock.write_all(h.as_bytes()).await?;
    sock.write_all(body).await?;
    Ok(())
}

/// one request per connection
async fn serve(mut sock: TcpStream) -> Result<()> {
    let mut head = Vec::new();
    let mut buf = [0u8; 4096];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") {
        let n = sock.read(&mut buf).await?;
        if n == 0 || head.len() > 32768 {
            return Ok(());
        }
        head.extend_from_slice(&buf[..n]);
    }
    let text = String::from_utf8_lossy(&head).into_owned();
    let mut lines = text.lines();
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, target) = (first.next().unwrap_or("").to_owned(), first.next().unwrap_or("").to_owned());
    let range = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_owned());
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));

    if method == "OPTIONS" {
        return reply(&mut sock, "204 No Content", "text/plain", b"").await;
    }
    // what stremio web and noonix tv ask to see that a server is there
    if path == "/settings" {
        let body = json!({ "options": [], "values": { "serverVersion": concat!("noonix-tv ", env!("CARGO_PKG_VERSION")) } });
        return reply(&mut sock, "200 OK", "application/json", body.to_string().as_bytes()).await;
    }
    if path == "/stats.json" || path == "/heartbeat" {
        return reply(&mut sock, "200 OK", "application/json", b"{}").await;
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let hash = parts.first().map(|h| h.to_lowercase()).unwrap_or_default();
    let idx = parts.get(1).and_then(|i| i.parse::<i64>().ok());
    if hash.len() != 40 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) || idx.is_none() || parts.len() > 3 {
        return reply(&mut sock, "404 Not Found", "text/plain", b"not found").await;
    }
    let trackers: Vec<String> = query
        .split('&')
        .filter_map(|kv| kv.strip_prefix("tr="))
        .filter_map(|v| urlencoding::decode(&v.replace('+', " ")).ok().map(|s| s.into_owned()))
        .collect();
    let (handle, file) = match file_for(&hash, idx.unwrap_or(-1), &trackers).await {
        Ok(v) => v,
        Err(e) => return reply(&mut sock, "502 Bad Gateway", "text/plain", format!("{e:#}").as_bytes()).await,
    };

    let len = handle.with_metadata(|m| m.file_infos[file].len)?;
    let name = handle.with_metadata(|m| m.file_infos[file].relative_filename.to_string_lossy().to_lowercase())?;
    let (start, end) = torrent::parse_range(range.as_deref(), len);
    if start >= len && len > 0 {
        let h = format!("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{len}\r\n{CORS}Connection: close\r\n\r\n");
        sock.write_all(h.as_bytes()).await?;
        return Ok(());
    }
    let count = end + 1 - start;
    let status = if range.is_some() { "206 Partial Content" } else { "200 OK" };
    // a tv's player goes by the type more than a pc's does
    let kind = if name.ends_with(".mp4") || name.ends_with(".m4v") {
        "video/mp4"
    } else if name.ends_with(".webm") {
        "video/webm"
    } else if name.ends_with(".mkv") {
        "video/x-matroska"
    } else {
        "application/octet-stream"
    };
    let mut h = format!("HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nAccept-Ranges: bytes\r\nContent-Length: {count}\r\n{CORS}Connection: close\r\n");
    if range.is_some() {
        h.push_str(&format!("Content-Range: bytes {start}-{end}/{len}\r\n"));
    }
    h.push_str("\r\n");
    sock.write_all(h.as_bytes()).await?;
    if method == "HEAD" {
        return Ok(());
    }
    let _open = Open::new(&hash);
    let mut stream = handle.stream(file).await?;
    stream.seek(std::io::SeekFrom::Start(start)).await?;
    tokio::io::copy(&mut stream.take(count), &mut sock).await?;
    Ok(())
}

/// a stream being read: the torrent isn't idle while one is
struct Open(String);
impl Open {
    fn new(hash: &str) -> Self {
        if let Ok(mut m) = TORRENTS.lock() {
            if let Some(s) = m.get_mut(hash) {
                s.open += 1;
                s.last = Instant::now();
            }
        }
        Open(hash.to_owned())
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        if let Ok(mut m) = TORRENTS.lock() {
            if let Some(s) = m.get_mut(&self.0) {
                s.open = s.open.saturating_sub(1);
                s.last = Instant::now();
            }
        }
    }
}

/// the torrent (added once, then kept) and the file asked for: its index, or the biggest video for -1
async fn file_for(hash: &str, idx: i64, trackers: &[String]) -> Result<(Arc<ManagedTorrent>, usize)> {
    let known = TORRENTS.lock().ok().and_then(|m| m.get(hash).map(|s| s.handle.clone()));
    let handle = match known {
        Some(h) => h,
        None => {
            let s = torrent::session().await?;
            let mut magnet = format!("magnet:?xt=urn:btih:{hash}");
            // stremio sends its sources as they are ("tracker:udp://…", "dht:…"); a plain url is a tracker too
            for t in trackers {
                let t = t.strip_prefix("tracker:").unwrap_or(t);
                if t.contains("://") {
                    magnet.push_str("&tr=");
                    magnet.push_str(&urlencoding::encode(t));
                }
            }
            let opts = AddTorrentOptions { paused: true, overwrite: true, ..Default::default() };
            let added = tokio::time::timeout(Duration::from_secs(60), s.add_torrent(AddTorrent::from_url(magnet), Some(opts)))
                .await
                .map_err(|_| anyhow::anyhow!("nobody is sharing this torrent right now"))??;
            let h = added.into_handle().context("torrent wasn't added")?;
            tokio::time::timeout(Duration::from_secs(60), h.wait_until_initialized())
                .await
                .map_err(|_| anyhow::anyhow!("the torrent didn't start"))??;
            if let Ok(mut m) = TORRENTS.lock() {
                m.entry(hash.to_owned()).or_insert(Served { handle: h.clone(), files: HashSet::new(), last: Instant::now(), open: 0 });
            }
            h
        }
    };
    let file = handle.with_metadata(|m| {
        let files = &m.file_infos;
        match usize::try_from(idx).ok().filter(|i| *i < files.len()) {
            Some(i) => Some(i),
            None => (0..files.len())
                .filter(|i| {
                    let name = files[*i].relative_filename.to_string_lossy().to_lowercase();
                    torrent::VIDEO.iter().any(|e| name.ends_with(&format!(".{e}")))
                })
                .max_by_key(|i| files[*i].len),
        }
    })?;
    let file = file.context("this torrent has no video")?;
    // only the files asked for come down
    let wanted = TORRENTS.lock().ok().and_then(|mut m| {
        let s = m.get_mut(hash)?;
        s.last = Instant::now();
        s.files.insert(file).then(|| s.files.clone())
    });
    if let Some(files) = wanted {
        let s = torrent::session().await?;
        s.update_only_files(&handle, &files).await?;
        s.unpause(&handle).await.ok();
    }
    Ok((handle, file))
}
