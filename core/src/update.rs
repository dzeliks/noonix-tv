// app updates from github releases. an appimage updates itself: the new file is downloaded
// next to it, checked against SHA256SUMS and renamed over it; the running copy keeps going
// until the next launch (or update.relaunch). on windows the installed app downloads the new
// installer, which runs quietly once the app is gone
use crate::app;
use crate::config::{self, PATHS};
use crate::http::CLIENT;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::AsyncWriteExt;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
// a build of its own can follow its own releases
const REPO: &str = match option_env!("NOONIX_UPDATE_REPO") {
    Some(r) => r,
    None => "dzeliks/noonix-tv",
};
// SHA256SUMS comes signed (minisign, SHA256SUMS.minisig): the sums alone only catch a damaged
// download, not a swapped release. a build following a repo of its own brings its own key or none
const SIGNING_KEY: Option<&str> = match (option_env!("NOONIX_UPDATE_KEY"), option_env!("NOONIX_UPDATE_REPO")) {
    (Some(k), _) => Some(k),
    (None, None) => Some("RWTxrm/6vwTDc8vqK2CrSQ1YXbYOr8hE2Y6LBYJNkqZjWg0X5eC2l+59"),
    (None, Some(_)) => None,
};

/// the sums file as signed by the release key
fn signed(sums: &str, sig: &str, key: &str) -> Result<()> {
    let key = minisign_verify::PublicKey::from_base64(key).map_err(|e| anyhow::anyhow!("release key: {e}"))?;
    let sig = minisign_verify::Signature::decode(sig).map_err(|e| anyhow::anyhow!("SHA256SUMS.minisig: {e}"))?;
    key.verify(sums.as_bytes(), &sig, false).map_err(|_| anyhow::anyhow!("SHA256SUMS isn't signed by the Noonix TV release key"))
}
#[cfg(all(unix, target_arch = "aarch64"))]
const ARCH_SUFFIX: &str = "-aarch64.AppImage";
#[cfg(all(unix, not(target_arch = "aarch64")))]
const ARCH_SUFFIX: &str = "-x86_64.AppImage";
#[cfg(windows)]
const ARCH_SUFFIX: &str = "-windows-x64-setup.exe";
#[cfg(unix)]
const NO_ASSET: &str = "This release has no AppImage yet";
#[cfg(windows)]
const NO_ASSET: &str = "This release has no Windows installer yet";
#[cfg(unix)]
const NOT_UPDATABLE: &str = "Built from source: update with git pull and a new build";
#[cfg(windows)]
const NOT_UPDATABLE: &str = "Only the installed app can update itself";
// a day between automatic checks
const AUTO_EVERY: i64 = 20 * 3600;

static INSTALLING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// "0.2.0" > "0.1.9"; "1.0.0" > "1.0.0-rc.1"; a leading v is fine
pub fn newer(candidate: &str, current: &str) -> bool {
    fn parse(v: &str) -> (Vec<u64>, Option<String>) {
        let v = v.trim().trim_start_matches('v');
        let (core, pre) = match v.split_once('-') {
            Some((c, p)) => (c, Some(p.to_owned())),
            None => (v, None),
        };
        (core.split('.').map(|p| p.parse().unwrap_or(0)).collect(), pre)
    }
    let (a, ap) = parse(candidate);
    let (b, bp) = parse(current);
    let n = a.len().max(b.len());
    for i in 0..n {
        let (x, y) = (a.get(i).copied().unwrap_or(0), b.get(i).copied().unwrap_or(0));
        if x != y {
            return x > y;
        }
    }
    match (ap, bp) {
        (None, Some(_)) => true,
        (Some(x), Some(y)) => x > y,
        _ => false,
    }
}

/// the hash for `name` in a SHA256SUMS file (sha256sum output)
pub fn sum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let (hash, file) = l.split_once(char::is_whitespace)?;
        (file.trim().trim_start_matches('*') == name && hash.len() == 64).then(|| hash.to_ascii_lowercase())
    })
}

/// the private repo needs a login: NOONIX_GITHUB_TOKEN, or GITHUB_TOKEN in the database
fn token() -> Option<String> {
    std::env::var("NOONIX_GITHUB_TOKEN").ok().filter(|t| !t.is_empty()).or_else(|| config::secret("GITHUB_TOKEN"))
}

fn api(url: &str, accept: &str, token: &Option<String>) -> reqwest::RequestBuilder {
    // reqwest drops authorization when a download redirects to another host
    let rb = CLIENT.get(url).header("accept", accept).header("x-github-api-version", "2022-11-28");
    match token {
        Some(t) => rb.bearer_auth(t),
        None => rb,
    }
}

/// what gets replaced: the appimage, or on windows the installed app (its uninstaller sits next to it)
#[cfg(unix)]
fn updatable() -> Option<PathBuf> {
    std::env::var_os("APPIMAGE").map(PathBuf::from).filter(|p| p.is_file())
}

#[cfg(windows)]
fn updatable() -> Option<PathBuf> {
    std::env::current_exe().ok().filter(|e| e.with_file_name("uninstall.exe").is_file())
}

fn state_path() -> PathBuf {
    PATHS.state.join("update.json")
}

fn load_state() -> Value {
    std::fs::read(state_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null)
}

fn save_state(v: &Value) {
    let _ = std::fs::create_dir_all(&PATHS.state);
    let _ = std::fs::write(state_path(), v.to_string());
}

/// the latest release as {version, notes, url, appimage: {id, name, size}, sums: id}
async fn latest() -> Result<Value> {
    let token = tokio::task::spawn_blocking(token).await.ok().flatten();
    let res = api(&format!("https://api.github.com/repos/{REPO}/releases/latest"), "application/vnd.github+json", &token)
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .context("couldn't reach GitHub")?;
    match res.status().as_u16() {
        200 => {}
        404 if token.is_none() => bail!("No public release yet"),
        404 => bail!("No releases yet"),
        401 | 403 => bail!("GitHub refused the sign-in ({})", res.status()),
        s => bail!("GitHub answered {s}"),
    }
    let rel: Value = res.json().await?;
    let assets = rel["assets"].as_array().cloned().unwrap_or_default();
    let find = |pred: &dyn Fn(&str) -> bool| {
        assets.iter().find(|a| a["name"].as_str().is_some_and(pred)).map(|a| json!({ "id": a["id"], "name": a["name"], "size": a["size"] }))
    };
    Ok(json!({
        "version": rel["tag_name"].as_str().unwrap_or("").trim_start_matches('v'),
        "notes": rel["body"],
        "url": rel["html_url"],
        "appimage": find(&|n| n.ends_with(ARCH_SUFFIX)),
        "sums": find(&|n| n == "SHA256SUMS"),
        "sig": find(&|n| n == "SHA256SUMS.minisig"),
    }))
}

/// {current, latest, available, canInstall, why}. auto = at most once a day, quietly
pub async fn check(auto: bool) -> Result<Value> {
    let now = chrono::Utc::now().timestamp();
    let mut st = load_state();
    if auto && now - st["checked"].as_i64().unwrap_or(0) < AUTO_EVERY {
        if let Some(rel) = st.get("latest").filter(|v| v.is_object()) {
            return Ok(report(rel));
        }
        return Ok(json!({ "current": VERSION, "available": false }));
    }
    let rel = latest().await?;
    st = json!({ "checked": now, "latest": rel });
    save_state(&st);
    Ok(report(&rel))
}

fn report(rel: &Value) -> Value {
    let v = rel["version"].as_str().unwrap_or("");
    let available = !v.is_empty() && newer(v, VERSION);
    let why = if updatable().is_none() {
        Some(NOT_UPDATABLE)
    } else if rel["appimage"].is_null() || rel["sums"].is_null() {
        Some(NO_ASSET)
    } else {
        None
    };
    json!({
        "current": VERSION,
        "latest": v,
        "available": available,
        "canInstall": available && why.is_none(),
        "why": why,
        "notes": rel["notes"],
        "url": rel["url"],
    })
}

/// downloads the latest appimage over the running one (windows: the installer); pushes update.progress {pct}
pub async fn install() -> Result<Value> {
    use std::sync::atomic::Ordering;
    if INSTALLING.swap(true, Ordering::SeqCst) {
        bail!("Already updating");
    }
    let r = install_inner().await;
    INSTALLING.store(false, Ordering::SeqCst);
    r
}

async fn install_inner() -> Result<Value> {
    let target = updatable().context(NOT_UPDATABLE)?;
    let rel = latest().await?;
    let version = rel["version"].as_str().unwrap_or("").to_owned();
    if !newer(&version, VERSION) {
        return Ok(json!({ "installed": false, "current": VERSION }));
    }
    let (Some(asset), Some(sums)) = (rel["appimage"].as_object(), rel["sums"].as_object()) else {
        bail!(NO_ASSET);
    };
    let name = asset["name"].as_str().unwrap_or("").to_owned();
    let token = tokio::task::spawn_blocking(token).await.ok().flatten();
    let asset_url = |id: &Value| format!("https://api.github.com/repos/{REPO}/releases/assets/{id}");

    let sums_text = api(&asset_url(&sums["id"]), "application/octet-stream", &token)
        .timeout(Duration::from_secs(30))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    if let Some(key) = SIGNING_KEY {
        let sig = rel["sig"].as_object().context("This release isn't signed: update it from the releases page")?;
        let sig_text = api(&asset_url(&sig["id"]), "application/octet-stream", &token)
            .timeout(Duration::from_secs(30))
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        signed(&sums_text, &sig_text, key)?;
    }
    let want = sum_for(&sums_text, &name).with_context(|| format!("SHA256SUMS has no line for {name}"))?;

    #[cfg(unix)]
    let dir = target.parent().context("AppImage has no folder")?.to_owned();
    #[cfg(windows)]
    let dir = std::env::temp_dir().join("noonix-tv-update");
    #[cfg(windows)]
    tokio::fs::create_dir_all(&dir).await?;
    let part = dir.join(format!(".{name}.part"));
    let mut res = api(&asset_url(&asset["id"]), "application/octet-stream", &token)
        .timeout(Duration::from_secs(3600))
        .send()
        .await?
        .error_for_status()?;
    let total = res.content_length().or(asset["size"].as_u64()).unwrap_or(0);
    let mut file = tokio::fs::File::create(&part).await.with_context(|| format!("can't write in {}", dir.display()))?;
    let mut hash = Sha256::new();
    let (mut got, mut shown) = (0u64, 0u64);
    let result: Result<()> = async {
        while let Some(chunk) = res.chunk().await? {
            hash.update(&chunk);
            file.write_all(&chunk).await?;
            got += chunk.len() as u64;
            let pct = (got * 100).checked_div(total).unwrap_or(0);
            if pct > shown {
                shown = pct;
                app::emit("update.progress", json!({ "pct": pct, "version": version }));
            }
        }
        file.flush().await?;
        file.sync_all().await?;
        Ok(())
    }
    .await;
    if let Err(e) = result {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(e);
    }
    let have: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if have != want {
        let _ = tokio::fs::remove_file(&part).await;
        bail!("The download was damaged (checksum mismatch), nothing was changed");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&part, std::fs::Permissions::from_mode(0o755)).await?;
        // same folder, so this is atomic; the running copy stays mounted from the old inode
        tokio::fs::rename(&part, &target).await?;
    }
    #[cfg(windows)]
    {
        // the installer replaces the app at relaunch, when nothing holds its files
        let setup = dir.join(&name);
        tokio::fs::rename(&part, &setup).await?;
        *SETUP.lock().unwrap() = Some(setup);
    }
    tracing::info!("updated {} -> {version}", VERSION);
    Ok(json!({ "installed": true, "version": version, "path": target }))
}

#[cfg(windows)]
static SETUP: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

/// starts the (updated) appimage once this process is gone; the ui quits right after
#[cfg(unix)]
pub fn relaunch() -> Result<Value> {
    use std::os::unix::process::CommandExt;
    let target = updatable().context("Only the AppImage can restart itself")?;
    let pid = std::process::id().to_string();
    std::process::Command::new("sh")
        .args(["-c", r#"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec "$2""#, "noonix-relaunch", &pid])
        .arg(&target)
        .env_remove("APPDIR")
        .env_remove("APPIMAGE")
        .env_remove("LD_LIBRARY_PATH")
        .process_group(0)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(json!({ "ok": true }))
}

/// once this process is gone: the downloaded installer quietly, then the app again
#[cfg(windows)]
pub fn relaunch() -> Result<Value> {
    use std::os::windows::process::CommandExt;
    let target = updatable().context("Only the installed app can restart itself")?;
    let setup = SETUP.lock().unwrap().clone();
    let quote = |p: &std::path::Path| p.display().to_string().replace('\'', "''");
    let mut script = format!("Wait-Process -Id {} -ErrorAction SilentlyContinue; ", std::process::id());
    if let Some(setup) = &setup {
        script += &format!("Start-Process -Wait -FilePath '{}' -ArgumentList '/S'; ", quote(setup));
        script += &format!("Remove-Item -LiteralPath '{}' -ErrorAction SilentlyContinue; ", quote(setup));
    }
    script += &format!("Start-Process -FilePath '{}'", quote(&target));
    std::process::Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", &script])
        .creation_flags(0x0800_0000)   // no console window
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(json!({ "ok": true }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions() {
        assert!(newer("0.2.0", "0.1.9"));
        assert!(newer("v0.10.0", "0.9.0"));
        assert!(newer("1.0.0", "1.0.0-rc.1"));
        assert!(newer("1.0.0-rc.2", "1.0.0-rc.1"));
        assert!(newer("0.1.1", "0.1"));
        assert!(!newer("0.1.0", "0.1.0"));
        assert!(!newer("0.1.0-rc.1", "0.1.0"));
        assert!(!newer("0.1.0", "0.2.0"));
        assert!(!newer("", "0.1.0"));
    }

    #[test]
    fn sums() {
        let h = "a".repeat(64);
        let text = format!("{h}  Noonix-TV-0.2.0-x86_64.AppImage\n{}  *other.tar\n", "b".repeat(64));
        assert_eq!(sum_for(&text, "Noonix-TV-0.2.0-x86_64.AppImage"), Some(h));
        assert_eq!(sum_for(&text, "other.tar"), Some("b".repeat(64)));
        assert_eq!(sum_for(&text, "missing"), None);
        assert_eq!(sum_for("short  x\n", "x"), None);
    }

    #[test]
    fn signature() {
        // signed with the release key (rsign sign -t "noonix-tv test"), as the release workflow does
        let sums = "abc  Noonix-TV-x86_64.AppImage\n";
        let sig = "untrusted comment: signature from rsign secret key\nRUTxrm/6vwTDc56ZHJjvwW6U6W2KJXg0SO9Qr7vO/Pn1b7gJiEtd5CaY+LBK8yz38KptFClMxlggTP2DyOCzBmYh8BoruO5jnQw=\ntrusted comment: noonix-tv test\njyI09nGyJ5py5+oeEuzwYHtF1V7wHw09P3LiJTNgfHbFqOt2eJkG1xgItYMggO0g++tfV8oqgz3yWxqGpaeOCA==\n";
        let key = SIGNING_KEY.unwrap();
        assert!(signed(sums, sig, key).is_ok());
        assert!(signed("abd  Noonix-TV-x86_64.AppImage\n", sig, key).is_err());
        assert!(signed(sums, "not a signature", key).is_err());
    }
}
