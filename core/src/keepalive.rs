// keeping logins alive while nobody opens noonix tv: the profiles' trakt tokens, the opensubtitles key (purged after 60 days
// without a download), a torbox check. run by a daily systemd user timer (on unless turned off
// in setup; a task scheduler task on windows) and by the app itself while it's open, so a pc without
// systemd stays signed in too
use crate::config::{self, keys};
use crate::http;
use crate::store;
use crate::trakt::{self, Mode};
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::path::PathBuf;

const OPENSUB_EVERY: i64 = 25 * 86400;
const APP_EVERY: i64 = 20 * 3600;

/// the command the scheduler runs: an appimage's own path (its mount is gone after exit), else
/// the cli next to the binary
fn cli_command() -> Result<String> {
    if let Some(img) = std::env::var_os("APPIMAGE") {
        return Ok(format!("\"{}\" --cli keepalive.run \"{{}}\"", PathBuf::from(img).display()));
    }
    let cli = std::env::current_exe()?.with_file_name(if cfg!(windows) { "noonix-tv-cli.exe" } else { "noonix-tv-cli" });
    http::ensure(cli.is_file(), "noonix-tv-cli is not next to noonix-tv")?;
    // cmd hands {} through as it is, json needs no quotes there
    Ok(if cfg!(windows) { format!("\"{}\" keepalive.run {{}}", cli.display()) } else { format!("\"{}\" keepalive.run \"{{}}\"", cli.display()) })
}

pub fn status() -> Value {
    json!({ "installed": timer::installed(), "scheduler": timer::available() })
}

/// while the app is open: a run when the last one is older than 20 h, and a timer whose
/// appimage moved gets the new path
pub async fn in_app() {
    if timer::installed() && !own_db() {
        if cli_command().is_ok_and(|c| !timer::command().contains(&c)) {
            match tokio::task::spawn_blocking(install).await {
                Ok(Ok(_)) => tracing::info!("keepalive timer points at this copy now"),
                Ok(Err(e)) => tracing::warn!("keepalive timer: {e:#}"),
                Err(_) => {}
            }
        }
    }
    loop {
        let last = store::with(|c| store::get_setting(c, "app", "keepalive_last")).await.ok().flatten().and_then(|v| v.as_i64()).unwrap_or(0);
        if store::now() - last >= APP_EVERY {
            // a minute in: the start itself has enough to do
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            if let Err(e) = run().await {
                tracing::warn!("{e:#}");
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(3600)).await;
    }
}

pub async fn run() -> Result<Value> {
    let mut done = Vec::new();
    let mut failed = Vec::new();

    // trakt: only tokens noonix tv owns
    let profiles = store::with(store::profiles).await?;
    for p in profiles.iter().filter(|p| Mode::parse(&p.trakt) == Mode::Own) {
        match trakt::refresh_if_needed(Mode::Own, p.id, false).await {
            Ok(true) => done.push(format!("trakt {}: refreshed", p.name)),
            Ok(false) => done.push(format!("trakt {}: still fresh", p.name)),
            Err(e) => failed.push(format!("trakt {}: {e:#}", p.name)),
        }
    }

    // opensubtitles: monthly
    if config::has_secret(keys::OPENSUBTITLES_API_KEY) {
        let last = store::with(|c| store::get_setting(c, "app", "opensub_keepalive")).await?.and_then(|v| v.as_i64()).unwrap_or(0);
        if store::now() - last >= OPENSUB_EVERY {
            match crate::subtitles::keepalive().await {
                Ok(m) => {
                    let now = store::now();
                    store::with(move |c| store::set_setting(c, "app", "opensub_keepalive", &json!(now))).await?;
                    done.push(format!("opensubtitles: {m}"));
                }
                Err(e) => failed.push(format!("opensubtitles: {e:#}")),
            }
        }
    }

    // the debrid keys: a dead one is better found here than at the next play
    for (id, key, _) in config::DEBRIDS {
        if let Some(value) = config::stored(key) {
            match crate::setup::check_debrid(key, &value).await {
                Ok(_) => done.push(format!("{id}: key works")),
                Err(e) => failed.push(format!("{id}: {e:#}")),
            }
        }
    }

    for d in &done {
        tracing::info!("keepalive {d}");
    }
    let now = store::now();
    store::with(move |c| store::set_setting(c, "app", "keepalive_last", &json!(now))).await?;
    if !failed.is_empty() {
        // the timer's unit fails loudly: a silent keepalive is how keys got purged before
        bail!("keepalive failed: {}", failed.join("; "));
    }
    Ok(json!({ "done": done }))
}

/// a copy on its own db (a dev or test run) leaves the installed one's timer alone
fn own_db() -> bool {
    std::env::var_os("NOONIX_DB").is_some()
}

/// daily run of `keepalive.run`
pub fn install() -> Result<Value> {
    if own_db() {
        tracing::info!("keepalive timer: left alone (own db)");
    } else {
        timer::install(&cli_command()?)?;
    }
    Ok(status())
}

pub fn remove() -> Result<Value> {
    if !own_db() {
        timer::remove()?;
    }
    Ok(status())
}

// a systemd user timer
#[cfg(unix)]
mod timer {
    use crate::config;
    use anyhow::{bail, Context, Result};
    use std::path::PathBuf;
    use std::process::Command;

    // $XDG_CONFIG_HOME/systemd/user, like systemd itself (a scratch config never touches the real one)
    fn unit_dir() -> PathBuf {
        config::PATHS.config.parent().map(|p| p.join("systemd/user")).unwrap_or_else(|| config::home().join(".config/systemd/user"))
    }

    fn systemctl(args: &[&str]) -> bool {
        Command::new("systemctl").arg("--user").args(args).status().is_ok_and(|s| s.success())
    }

    pub fn available() -> bool {
        Command::new("systemctl").args(["--user", "is-system-running"]).output().is_ok_and(|o| !o.stdout.is_empty())
    }

    pub fn installed() -> bool {
        unit_dir().join("noonix-tv-keepalive.timer").is_file()
            && Command::new("systemctl").args(["--user", "is-enabled", "--quiet", "noonix-tv-keepalive.timer"]).status().is_ok_and(|s| s.success())
    }

    pub fn command() -> String {
        std::fs::read_to_string(unit_dir().join("noonix-tv-keepalive.service")).unwrap_or_default()
    }

    pub fn install(cmd: &str) -> Result<()> {
        let dir = unit_dir();
        std::fs::create_dir_all(&dir)?;
        std::fs::write(
            dir.join("noonix-tv-keepalive.service"),
            format!(
                "[Unit]\nDescription=Noonix TV: keep logins alive\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart={cmd}\nTimeoutStartSec=600\n"
            ),
        )?;
        std::fs::write(
            dir.join("noonix-tv-keepalive.timer"),
            "[Unit]\nDescription=Noonix TV: keep logins alive daily\n\n[Timer]\nOnCalendar=daily\nRandomizedDelaySec=1h\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n",
        )?;
        if !(systemctl(&["daemon-reload"]) && systemctl(&["enable", "--now", "noonix-tv-keepalive.timer"])) {
            bail!("systemctl refused the timer");
        }
        Ok(())
    }

    pub fn remove() -> Result<()> {
        systemctl(&["disable", "--now", "noonix-tv-keepalive.timer"]);
        let dir = unit_dir();
        for f in ["noonix-tv-keepalive.timer", "noonix-tv-keepalive.service"] {
            let p = dir.join(f);
            if p.exists() {
                std::fs::remove_file(&p).with_context(|| format!("removing {}", p.display()))?;
            }
        }
        systemctl(&["daemon-reload"]);
        Ok(())
    }
}

// a task scheduler task for this user, daily at a random-ish hour and caught up after a missed
// day (the task xml's StartWhenAvailable); schtasks can't set that, so the task is imported as xml
#[cfg(windows)]
mod timer {
    use anyhow::{bail, Result};
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    const TASK: &str = "Noonix TV keepalive";
    const NO_WINDOW: u32 = 0x0800_0000;

    fn schtasks(args: &[&str]) -> std::io::Result<std::process::Output> {
        Command::new("schtasks").args(args).creation_flags(NO_WINDOW).output()
    }

    pub fn available() -> bool {
        true
    }

    pub fn installed() -> bool {
        schtasks(&["/Query", "/TN", TASK]).is_ok_and(|o| o.status.success())
    }

    pub fn command() -> String {
        schtasks(&["/Query", "/TN", TASK, "/XML"])
            .map(|o| String::from_utf8_lossy(&o.stdout).replace("&quot;", "\"").replace("&amp;", "&"))
            .unwrap_or_default()
    }

    fn xml_escape(s: &str) -> String {
        s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
    }

    pub fn install(cmd: &str) -> Result<()> {
        // the cli is a console program: a headless console keeps a window from flashing up
        let (exe, args) = ("conhost.exe", format!("--headless {cmd}"));
        let xml = format!(
            r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Noonix TV: keep logins alive</Description></RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T12:00:00</StartBoundary>
      <RandomDelay>PT1H</RandomDelay>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>{}</Command><Arguments>{}</Arguments></Exec></Actions>
</Task>
"#,
            xml_escape(exe),
            xml_escape(&args)
        );
        let path = std::env::temp_dir().join(format!("noonix-tv-keepalive-{}.xml", std::process::id()));
        // schtasks wants utf-16 with a bom for an xml that says so
        let mut bytes = vec![0xFF, 0xFE];
        bytes.extend(xml.encode_utf16().flat_map(u16::to_le_bytes));
        std::fs::write(&path, bytes)?;
        let out = schtasks(&["/Create", "/TN", TASK, "/XML", &path.to_string_lossy(), "/F"]);
        let _ = std::fs::remove_file(&path);
        match out {
            Ok(o) if o.status.success() => Ok(()),
            Ok(o) => bail!("task scheduler refused the task: {}", String::from_utf8_lossy(&o.stderr).trim()),
            Err(e) => bail!("task scheduler: {e}"),
        }
    }

    pub fn remove() -> Result<()> {
        if installed() {
            let o = schtasks(&["/Delete", "/TN", TASK, "/F"])?;
            if !o.status.success() {
                bail!("task scheduler: {}", String::from_utf8_lossy(&o.stderr).trim());
            }
        }
        Ok(())
    }
}
