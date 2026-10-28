// windows: the installer makes the start menu entry; open at login is the user's run key
use anyhow::{bail, Result};
use serde_json::{json, Value};
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

const RUN: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const NAME: &str = "Noonix TV";
const NO_WINDOW: u32 = 0x0800_0000;

fn reg(args: &[&str]) -> std::io::Result<std::process::Output> {
    Command::new("reg").args(args).creation_flags(NO_WINDOW).output()
}

// the app, also when the cli asks
fn exec() -> Result<String> {
    Ok(format!("\"{}\"", std::env::current_exe()?.with_file_name("noonix-tv.exe").display()))
}

fn login_value() -> Option<String> {
    let o = reg(&["query", RUN, "/v", NAME]).ok().filter(|o| o.status.success())?;
    let text = String::from_utf8_lossy(&o.stdout).into_owned();
    text.lines().find_map(|l| l.split_once("REG_SZ").map(|(_, v)| v.trim().to_owned()))
}

fn menu_file() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join(r"Microsoft\Windows\Start Menu\Programs\Noonix TV.lnk"))
}

pub fn status() -> Value {
    let menu = menu_file().is_some_and(|p| p.is_file());
    json!({ "menu": menu, "menuFixed": true, "login": login_value().is_some() })
}

pub fn set_menu(_on: bool) -> Result<Value> {
    Ok(status())
}

pub fn set_login(on: bool) -> Result<Value> {
    let o = if on {
        reg(&["add", RUN, "/v", NAME, "/t", "REG_SZ", "/d", &exec()?, "/f"])?
    } else if login_value().is_some() {
        reg(&["delete", RUN, "/v", NAME, "/f"])?
    } else {
        return Ok(status());
    };
    if !o.status.success() {
        bail!("the registry refused it: {}", String::from_utf8_lossy(&o.stderr).trim());
    }
    Ok(status())
}

/// at start: open at login follows the app when it moved
pub fn refresh() {
    let Ok(want) = exec() else { return };
    if login_value().is_some_and(|v| v != want) {
        if let Err(e) = set_login(true) {
            tracing::warn!("{e:#}");
        }
    }
}
