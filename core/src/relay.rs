//! https video through the core on the mac. mpvkit's ffmpeg decrypts tls in plain c (its nettle has
//! none of the arm instructions): a 4k stream kept a core busy with that alone. rustls here uses the
//! cpu's aes, mpv gets the same bytes over loopback http. only a plain file that takes ranges goes
//! through: a playlist's parts are relative to it and would land here

use crate::http::builder;
use anyhow::Result;
use once_cell::sync::Lazy;
use reqwest::{header, Client, Method, Response};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::OnceCell;

struct Upstream {
    url: String,
    headers: Vec<(String, String)>,
    /// where the redirects ended (a debrid link's cdn): asked first, the link itself again once that's refused
    direct: Mutex<String>,
}

static PORT: OnceCell<u16> = OnceCell::const_new();
/// token -> the stream playing now
static SERVED: Lazy<Mutex<HashMap<String, Arc<Upstream>>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// no overall timeout (a film takes hours) and nothing unpacked (the lengths and ranges are the file's)
static CLIENT: Lazy<Client> = Lazy::new(|| {
    builder()
        .user_agent(concat!("NoonixTV/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(30))
        .pool_idle_timeout(Duration::from_secs(90))
        .no_gzip()
        .no_brotli()
        .build()
        .expect("relay client")
});

/// dev: NOONIX_RELAY=0 plays https as it comes
pub fn wanted() -> bool {
    cfg!(target_os = "macos") && std::env::var("NOONIX_RELAY").as_deref() != Ok("0")
}

/// the stream's loopback address, or none to play it as it is
pub async fn url_for(url: &str, headers: &[(String, String)]) -> Option<String> {
    if !url.starts_with("https://") {
        return None;
    }
    let up = Arc::new(Upstream { url: url.to_owned(), headers: headers.to_vec(), direct: Mutex::new(url.to_owned()) });
    // one byte first: a file that takes ranges, or it plays as before
    let r = ask(&up, Method::GET, Some("bytes=0-0")).await.ok()?;
    let kind = r.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).unwrap_or("").to_ascii_lowercase();
    if r.status().as_u16() != 206 || ["mpegurl", "dash", "xml", "json", "html", "text/"].iter().any(|k| kind.contains(k)) {
        return None;
    }
    drop(r);
    register(up).await.ok()
}

async fn register(up: Arc<Upstream>) -> Result<String> {
    let port = server().await?;
    let mut t = [0u8; 16];
    getrandom::fill(&mut t).map_err(|e| anyhow::anyhow!("{e}"))?;
    let token: String = t.iter().map(|b| format!("{b:02x}")).collect();
    SERVED.lock().unwrap().insert(token.clone(), up);
    Ok(format!("http://127.0.0.1:{port}/{token}/stream"))
}

/// playback stopped: its address stops answering
pub fn clear() {
    SERVED.lock().unwrap().clear();
}

/// the source's answer, never with its address in an error (a debrid link carries the key)
async fn ask(up: &Upstream, method: Method, range: Option<&str>) -> Result<Response, reqwest::Error> {
    let send = |url: &str| {
        let own = url == up.url;
        let mut q = CLIENT.request(method.clone(), url);
        for (k, v) in &up.headers {
            // the cdn asked directly gets what a redirect would have left it
            if own || !["authorization", "cookie", "proxy-authorization"].contains(&k.to_ascii_lowercase().as_str()) {
                q = q.header(k, v);
            }
        }
        if let Some(r) = range {
            q = q.header(header::RANGE, r);
        }
        q.send()
    };
    let direct = up.direct.lock().unwrap().clone();
    if direct != up.url {
        if let Ok(r) = send(&direct).await {
            if r.status().is_success() {
                return Ok(r);
            }
        }
    }
    let r = send(&up.url).await.map_err(|e| e.without_url())?;
    if r.status().is_success() {
        *up.direct.lock().unwrap() = r.url().to_string();
    }
    Ok(r)
}

async fn server() -> Result<u16> {
    PORT.get_or_try_init(|| async {
        // on the app's runtime whoever asks first: the listener lives as long as it does
        crate::app::RUNTIME
            .spawn(async {
                let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
                let port = listener.local_addr()?.port();
                tokio::spawn(async move {
                    while let Ok((sock, _)) = listener.accept().await {
                        tokio::spawn(async move {
                            if let Err(e) = serve(sock, port).await {
                                tracing::debug!("relay: {e:#}");
                            }
                        });
                    }
                });
                Ok::<u16, anyhow::Error>(port)
            })
            .await?
    })
    .await
    .copied()
}

/// one request per connection: GET or HEAD /<token>/stream, with or without a range
async fn serve(mut sock: TcpStream, port: u16) -> Result<()> {
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
    let (method, target) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    let field = |name: &str| {
        text.lines().skip(1).filter_map(|l| l.split_once(':')).find(|(k, _)| k.trim().eq_ignore_ascii_case(name)).map(|(_, v)| v.trim().to_owned())
    };
    let token = target.trim_start_matches('/').split('/').next().unwrap_or("");
    let up = SERVED.lock().unwrap().get(token).cloned();
    // the player's own request names this address: a page elsewhere under a rebound name doesn't
    let host = field("host").unwrap_or_default();
    let ours = host == format!("127.0.0.1:{port}") || host == format!("localhost:{port}");
    let Some(up) = up.filter(|_| ours) else {
        sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
        return Ok(());
    };
    let method = if method == "HEAD" { Method::HEAD } else { Method::GET };
    let mut r = match ask(&up, method.clone(), field("range").as_deref()).await {
        Ok(r) => r,
        Err(e) => {
            sock.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await?;
            return Err(e.into());
        }
    };
    let status = r.status();
    let mut h = format!("HTTP/1.1 {} {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n", status.as_u16(), status.canonical_reason().unwrap_or("OK"));
    for k in [header::CONTENT_TYPE, header::CONTENT_LENGTH, header::CONTENT_RANGE] {
        if let Some(v) = r.headers().get(&k).and_then(|v| v.to_str().ok()) {
            h.push_str(&format!("{k}: {v}\r\n"));
        }
    }
    h.push_str("\r\n");
    sock.write_all(h.as_bytes()).await?;
    if method == Method::HEAD {
        return Ok(());
    }
    // the player going away (a seek, a stop) ends the write, and with it the download
    while let Some(chunk) = r.chunk().await.map_err(|e| e.without_url())? {
        sock.write_all(&chunk).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// a source: 1000 bytes (their own index mod 251), with ranges; /gone answers 404
    async fn source() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 4096];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("GET /gone") {
                        sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").await.ok();
                        return;
                    }
                    let body: Vec<u8> = (0..1000u32).map(|i| (i % 251) as u8).collect();
                    let range = text.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("range: bytes=").map(str::to_owned));
                    let (a, b) = match range.as_deref().and_then(|r| r.split_once('-')) {
                        Some((a, b)) => (a.parse().unwrap_or(0), b.parse().unwrap_or(999usize).min(999)),
                        None => (0, 999),
                    };
                    let mut h = format!("HTTP/1.1 {}\r\nContent-Type: video/x-matroska\r\nContent-Length: {}\r\n", if range.is_some() { "206 Partial Content" } else { "200 OK" }, b + 1 - a);
                    if range.is_some() {
                        h.push_str(&format!("Content-Range: bytes {a}-{b}/1000\r\n"));
                    }
                    h.push_str("\r\n");
                    sock.write_all(h.as_bytes()).await.ok();
                    sock.write_all(&body[a..=b]).await.ok();
                });
            }
        });
        base
    }

    async fn through(path: &str) -> String {
        let base = source().await;
        let url = format!("{base}{path}");
        register(Arc::new(Upstream { url: url.clone(), headers: vec![("X-Test".into(), "1".into())], direct: Mutex::new(url) })).await.unwrap()
    }

    #[tokio::test]
    async fn a_range_comes_through_as_the_source_sent_it() {
        let local = through("/film.mkv").await;
        let r = reqwest::Client::new().get(&local).header("range", "bytes=100-199").send().await.unwrap();
        assert_eq!(r.status().as_u16(), 206);
        assert_eq!(r.headers()["content-range"], "bytes 100-199/1000");
        assert_eq!(r.headers()["content-length"], "100");
        assert_eq!(r.headers()["content-type"], "video/x-matroska");
        let body = r.bytes().await.unwrap();
        assert_eq!(body.len(), 100);
        assert_eq!(body[0], 100);
        assert_eq!(body[99], 199);
        // the whole file without one
        let all = reqwest::Client::new().get(&local).send().await.unwrap();
        assert_eq!(all.status().as_u16(), 200);
        assert_eq!(all.bytes().await.unwrap().len(), 1000);
    }

    #[tokio::test]
    async fn only_the_playing_token_under_its_own_name_answers() {
        let local = through("/film.mkv").await;
        let c = reqwest::Client::new();
        let port = local.split(':').nth(2).unwrap().split('/').next().unwrap().to_owned();
        assert_eq!(c.get(format!("http://127.0.0.1:{port}/0123456789abcdef0123456789abcdef/stream")).send().await.unwrap().status().as_u16(), 404);
        // a rebound name (evil.example -> 127.0.0.1)
        assert_eq!(c.get(&local).header("host", "evil.example").send().await.unwrap().status().as_u16(), 404);
        assert_eq!(c.get(&local).send().await.unwrap().status().as_u16(), 200);
    }

    #[tokio::test]
    async fn the_sources_refusal_is_passed_on() {
        let local = through("/gone").await;
        assert_eq!(reqwest::Client::new().get(&local).send().await.unwrap().status().as_u16(), 404);
    }

    #[tokio::test]
    async fn plain_http_and_playlists_play_as_they_are() {
        assert!(url_for("http://192.168.1.4/film.mkv", &[]).await.is_none());
    }
}
