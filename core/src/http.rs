use crate::config::redact;
use crate::store;
use anyhow::{anyhow, bail, Result};
use once_cell::sync::Lazy;
use reqwest::{header::HeaderMap, Client, Method, StatusCode};
use serde_json::Value;
use std::time::Duration;

pub static CLIENT: Lazy<Client> = Lazy::new(|| {
    builder()
        .user_agent(concat!("NoonixTV/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(6))
        .timeout(Duration::from_secs(20))
        .pool_idle_timeout(Duration::from_secs(60))
        .gzip(true)
        .brotli(true)
        .build()
        .expect("http client")
});

/// android: the system's certificate store. rustls' platform verifier needs a java side the qt
/// app doesn't ship
#[cfg(target_os = "android")]
pub(crate) fn builder() -> reqwest::ClientBuilder {
    static ROOTS: Lazy<Vec<reqwest::Certificate>> = Lazy::new(|| {
        // the updatable store (android 14+) first, then the image's own
        let dir = ["/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"]
            .into_iter()
            .find(|d| std::path::Path::new(d).is_dir())
            .unwrap_or("/system/etc/security/cacerts");
        let roots: Vec<_> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|pem| reqwest::Certificate::from_pem_bundle(&pem).ok())
            .flatten()
            .collect();
        tracing::info!("tls: {} roots from {dir}", roots.len());
        roots
    });
    Client::builder().tls_certs_only(ROOTS.iter().cloned())
}

#[cfg(not(target_os = "android"))]
pub(crate) fn builder() -> reqwest::ClientBuilder {
    Client::builder()
}

#[derive(Debug, thiserror::Error)]
pub enum HttpError {
    #[error("http {status} from {url}")]
    Status { status: u16, url: String, body: String },
}

impl HttpError {
    pub fn status(&self) -> u16 {
        match self {
            HttpError::Status { status, .. } => *status,
        }
    }
}

pub struct Req {
    pub method: Method,
    pub url: String,
    pub headers: HeaderMap,
    pub body: Option<Value>,
    pub form: Option<Vec<(String, String)>>,
    pub timeout: Option<Duration>,
    pub retries: u32,
}

impl Req {
    pub fn get(url: impl Into<String>) -> Self {
        Req {
            method: Method::GET,
            url: url.into(),
            headers: HeaderMap::new(),
            body: None,
            form: None,
            timeout: None,
            retries: 2,
        }
    }
    pub fn post(url: impl Into<String>, body: Value) -> Self {
        Req { method: Method::POST, body: Some(body), retries: 0, ..Req::get(url) }
    }
    pub fn header(mut self, k: &'static str, v: &str) -> Self {
        if let Ok(v) = v.parse() {
            self.headers.insert(k, v);
        }
        self
    }
    pub fn timeout(mut self, secs: u64) -> Self {
        self.timeout = Some(Duration::from_secs(secs));
        self
    }
    pub fn retries(mut self, n: u32) -> Self {
        self.retries = n;
        self
    }
}

/// bytes of the response; retries timeouts, 429 and 5xx with backoff
pub async fn send(req: &Req) -> Result<(StatusCode, bytes::Bytes)> {
    let mut attempt = 0;
    loop {
        let mut rb = CLIENT.request(req.method.clone(), &req.url).headers(req.headers.clone());
        if let Some(b) = &req.body {
            rb = rb.json(b);
        }
        if let Some(f) = &req.form {
            rb = rb.form(f);
        }
        if let Some(t) = req.timeout {
            rb = rb.timeout(t);
        }
        let res = rb.send().await;
        let retry_after = match &res {
            Ok(r) if r.status() == StatusCode::TOO_MANY_REQUESTS || r.status().is_server_error() => r
                .headers()
                .get("retry-after")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .map(|s| Duration::from_secs(s.min(10)))
                .or(Some(Duration::from_millis(600 * (attempt as u64 + 1)))),
            Err(e) if e.is_timeout() || e.is_connect() => Some(Duration::from_millis(500 * (attempt as u64 + 1))),
            _ => None,
        };
        if let (Some(wait), true) = (retry_after, attempt < req.retries) {
            attempt += 1;
            tracing::debug!("retry {} in {:?}: {}", attempt, wait, redact(&req.url));
            tokio::time::sleep(wait).await;
            continue;
        }
        let res = res.map_err(|e| anyhow!("{}: {}", redact(&req.url), redact(&e.to_string())))?;
        let status = res.status();
        let bytes = res.bytes().await?;
        return Ok((status, bytes));
    }
}

/// some apis (opensubtitles) put raw control characters inside strings
pub fn parse_lenient(bytes: &[u8]) -> Result<Value> {
    match serde_json::from_slice(bytes) {
        Ok(v) => Ok(v),
        Err(_) => {
            let cleaned: String = String::from_utf8_lossy(bytes)
                .chars()
                .map(|c| if c.is_control() && c != '\n' && c != '\r' && c != '\t' { ' ' } else { c })
                .collect();
            let escaped = escape_newlines_in_strings(&cleaned);
            Ok(serde_json::from_str(&escaped)?)
        }
    }
}

fn escape_newlines_in_strings(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let (mut in_str, mut esc) = (false, false);
    for c in s.chars() {
        if in_str {
            if esc {
                esc = false;
            } else if c == '\\' {
                esc = true;
            } else if c == '"' {
                in_str = false;
            } else if c == '\n' || c == '\r' || c == '\t' {
                out.push(' ');
                continue;
            }
        } else if c == '"' {
            in_str = true;
        }
        out.push(c);
    }
    out
}

pub async fn json(req: &Req) -> Result<Value> {
    let (status, bytes) = send(req).await?;
    if !status.is_success() {
        return Err(HttpError::Status {
            status: status.as_u16(),
            url: redact(&req.url),
            body: redact(&String::from_utf8_lossy(&bytes[..bytes.len().min(300)])),
        }
        .into());
    }
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    parse_lenient(&bytes)
}

/// cached json: fresh hit, else network, else stale copy when offline
pub async fn cached_json(cache_key: &str, ttl_secs: i64, req: Req) -> Result<Value> {
    let key = cache_key.to_owned();
    let k = key.clone();
    if let Ok(Some(hit)) = store::with(move |c| store::cache_get(c, &k)).await {
        if let Ok(v) = serde_json::from_str(&hit) {
            return Ok(v);
        }
    }
    match json(&req).await {
        Ok(v) => {
            let text = v.to_string();
            let k = key.clone();
            let _ = store::with(move |c| store::cache_put(c, &k, &text, ttl_secs)).await;
            Ok(v)
        }
        Err(e) => {
            let not_found = e.downcast_ref::<HttpError>().is_some_and(|h| h.status() == 404);
            if !not_found {
                let k = key.clone();
                if let Ok(Some(stale)) = store::with(move |c| store::cache_get_stale(c, &k)).await {
                    tracing::warn!("using stale cache for {key}: {e:#}");
                    return Ok(serde_json::from_str(&stale)?);
                }
            }
            Err(e)
        }
    }
}

pub fn ensure(cond: bool, msg: &str) -> Result<()> {
    if !cond {
        bail!("{msg}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn lenient_json() {
        let raw = b"{\"comments\":\"line one\nline two\",\"n\":1}";
        let v = super::parse_lenient(raw).unwrap();
        assert_eq!(v["n"], 1);
    }
}
