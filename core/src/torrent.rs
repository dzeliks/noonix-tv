// torrent sources (only once the user allowed them): a p2p stream plays through a small torrent
// client inside the app, handed to the player over loopback http (range requests, so seeking
// works). it only downloads, never uploads. one torrent at a time; what it downloaded is deleted
// when playback stops, and leftovers on the next start
use crate::config::PATHS;
use anyhow::{bail, Context, Result};
use librqbit::{AddTorrent, AddTorrentOptions, ManagedTorrent, Session, SessionOptions};
use once_cell::sync::Lazy;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, OnceCell};

static SESSION: OnceCell<Arc<Session>> = OnceCell::const_new();
static PORT: OnceCell<u16> = OnceCell::const_new();
/// the torrent playing now: (info hash, handle, file)
type Playing = (String, Arc<ManagedTorrent>, usize);
static CURRENT: Lazy<Mutex<Option<Playing>>> = Lazy::new(|| Mutex::new(None));

fn dir() -> std::path::PathBuf {
    PATHS.cache.join("torrents")
}

pub(crate) async fn session() -> Result<Arc<Session>> {
    SESSION
        .get_or_try_init(|| async {
            let d = dir();
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d)?;
            // no listening port, no upnp, no uploading: only outgoing connections that download
            let opts = SessionOptions { disable_local_service_discovery: true, disable_upload: true, ..Default::default() };
            Session::new_with_opts(d, opts).await.context("couldn't start the torrent client")
        })
        .await
        .cloned()
}

pub(crate) const VIDEO: &[&str] = &["mkv", "mp4", "m4v", "avi", "ts", "m2ts", "webm", "mov", "wmv"];

/// a loopback address the player can open for this torrent's file (the addon's file index, else
/// the biggest video). waits for the torrent's metadata
pub async fn url_for(info_hash: &str, file_idx: Option<i64>, sources: &[String]) -> Result<String> {
    let hash = info_hash.to_lowercase();
    if hash.len() != 40 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("this torrent has no valid hash");
    }
    let s = session().await?;
    let port = server().await?;
    stop().await;
    let mut magnet = format!("magnet:?xt=urn:btih:{hash}");
    for t in sources.iter().filter_map(|s| s.strip_prefix("tracker:")) {
        magnet.push_str("&tr=");
        magnet.push_str(&urlencoding::encode(t));
    }
    let opts = AddTorrentOptions { paused: true, overwrite: true, ..Default::default() };
    let added = tokio::time::timeout(Duration::from_secs(60), s.add_torrent(AddTorrent::from_url(magnet), Some(opts)))
        .await
        .map_err(|_| anyhow::anyhow!("nobody is sharing this torrent right now"))??;
    let handle = added.into_handle().context("torrent wasn't added")?;
    let file = handle.with_metadata(|m| {
        let files = &m.file_infos;
        let video = |i: usize| {
            let name = files[i].relative_filename.to_string_lossy().to_lowercase();
            VIDEO.iter().any(|e| name.ends_with(&format!(".{e}")))
        };
        match file_idx.map(|i| i as usize).filter(|i| *i < files.len()) {
            Some(i) => Some(i),
            None => (0..files.len()).filter(|i| video(*i)).max_by_key(|i| files[*i].len),
        }
    })?;
    let file = file.context("this torrent has no video")?;
    tokio::time::timeout(Duration::from_secs(60), handle.wait_until_initialized())
        .await
        .map_err(|_| anyhow::anyhow!("the torrent didn't start"))??;
    // only the one file comes down, the rest of a season pack stays where it is
    s.update_only_files(&handle, &HashSet::from([file])).await?;
    s.unpause(&handle).await?;
    *CURRENT.lock().await = Some((hash.clone(), handle, file));
    tracing::info!("torrent {hash} file {file}");
    Ok(format!("http://127.0.0.1:{port}/{hash}/{file}"))
}

/// the info hash playing in the app now
pub(crate) async fn playing() -> Option<String> {
    CURRENT.lock().await.as_ref().map(|(h, _, _)| h.clone())
}

/// the torrent stops and its files go (unless a tv streams it through this computer too)
pub async fn stop() {
    let Some((hash, handle, _)) = CURRENT.lock().await.take() else { return };
    if crate::tvserver::holds(&hash) {
        return;
    }
    if let Some(s) = SESSION.get() {
        if let Err(e) = s.delete(handle.id().into(), true).await {
            tracing::warn!("torrent {hash}: {e:#}");
        }
    }
}

async fn server() -> Result<u16> {
    PORT.get_or_try_init(|| async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let port = listener.local_addr()?.port();
        tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                tokio::spawn(async move {
                    if let Err(e) = serve(sock).await {
                        tracing::debug!("torrent http: {e:#}");
                    }
                });
            }
        });
        Ok::<u16, anyhow::Error>(port)
    })
    .await
    .copied()
}

/// one request per connection: GET or HEAD /<hash>/<file>, with or without a range
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
    let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    let range = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("range"))
        .map(|(_, v)| v.trim().to_owned());

    let found = {
        let cur = CURRENT.lock().await;
        cur.as_ref().filter(|(h, _, f)| path == format!("/{h}/{f}")).map(|(_, h, f)| (h.clone(), *f))
    };
    let Some((handle, file)) = found else {
        sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    };
    let len = handle.with_metadata(|m| m.file_infos[file].len)?;
    let (start, end) = parse_range(range.as_deref(), len);
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
    if method == "HEAD" {
        return Ok(());
    }
    let mut stream = handle.stream(file).await?;
    stream.seek(std::io::SeekFrom::Start(start)).await?;
    tokio::io::copy(&mut stream.take(count), &mut sock).await?;
    Ok(())
}

/// "bytes=a-b" / "bytes=a-" / "bytes=-n" -> inclusive (start, end) inside len
pub(crate) fn parse_range(range: Option<&str>, len: u64) -> (u64, u64) {
    let last = len.saturating_sub(1);
    let Some(spec) = range.and_then(|r| r.strip_prefix("bytes=")).and_then(|r| r.split(',').next()) else { return (0, last) };
    let (a, b) = spec.split_once('-').unwrap_or((spec, ""));
    match (a.trim().parse::<u64>().ok(), b.trim().parse::<u64>().ok()) {
        (Some(a), Some(b)) => (a, b.min(last)),
        (Some(a), None) => (a, last),
        (None, Some(n)) => (len.saturating_sub(n), last),
        (None, None) => (0, last),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn ranges() {
        use super::parse_range;
        assert_eq!(parse_range(None, 100), (0, 99));
        assert_eq!(parse_range(Some("bytes=10-"), 100), (10, 99));
        assert_eq!(parse_range(Some("bytes=10-19"), 100), (10, 19));
        assert_eq!(parse_range(Some("bytes=-10"), 100), (90, 99));
        assert_eq!(parse_range(Some("bytes=50-500"), 100), (50, 99));
    }
}

#[cfg(test)]
mod live {
    // a real torrent (sintel, cc-by, webtorrent's test file): cargo test torrent::live -- --ignored
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn streams_sintel() {
        let url = super::url_for("08ada5a7a6183aae1e09d831df6748d566095a10", None, &["tracker:wss://tracker.webtorrent.dev".into(), "tracker:udp://tracker.opentrackr.org:1337/announce".into(), "tracker:udp://tracker.openbittorrent.com:6969/announce".into()]).await.unwrap();
        let c = reqwest::Client::new();
        let r = c.get(&url).header("range", "bytes=1000000-1065535").send().await.unwrap();
        assert_eq!(r.status().as_u16(), 206);
        assert_eq!(r.bytes().await.unwrap().len(), 65536);
        println!("{url}");
        super::stop().await;
    }
}
