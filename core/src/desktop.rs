// the app menu entry and open at login, as xdg desktop files. an appimage points them at its own
// file (its mount is gone after exit); a source install or a package already has its menu entry
use crate::config::{self, PATHS};
use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

// files we wrote, so a packaged entry is never overwritten or removed
const MARK: &str = "X-Noonix-Managed=true";

fn home_of(p: &std::path::Path, fallback: &str) -> PathBuf {
    p.parent().map(|d| d.to_owned()).unwrap_or_else(|| config::home().join(fallback))
}

fn menu_file() -> PathBuf {
    home_of(&PATHS.data, ".local/share").join("applications/noonix-tv.desktop")
}

fn login_file() -> PathBuf {
    home_of(&PATHS.config, ".config").join("autostart/noonix-tv.desktop")
}

fn icon_file() -> PathBuf {
    home_of(&PATHS.data, ".local/share").join("icons/hicolor/scalable/apps/noonix-tv.svg")
}

/// what the entries run: the appimage itself, else this binary
fn exec() -> Result<String> {
    let path = match std::env::var_os("APPIMAGE") {
        Some(p) => PathBuf::from(p),
        None => std::env::current_exe()?,
    };
    Ok(format!("\"{}\"", path.display()))
}

fn entry(exec: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Noonix TV\nComment=Movies and shows on the TV\nExec={exec}\nIcon=noonix-tv\nCategories=AudioVideo;Video;Player;TV;\n{MARK}\n"
    )
}

fn ours(path: &PathBuf) -> bool {
    fs::read_to_string(path).is_ok_and(|t| t.contains(MARK))
}

pub fn status() -> Value {
    let menu = menu_file();
    json!({
        "menu": menu.is_file(),
        // installed with the app (cmake, a package): nothing to switch
        "menuFixed": menu.is_file() && !ours(&menu),
        "login": login_file().is_file(),
    })
}

fn write(path: &PathBuf) -> Result<()> {
    fs::create_dir_all(path.parent().context("no parent")?)?;
    fs::write(path, entry(&exec()?)).with_context(|| format!("writing {}", path.display()))
}

pub fn set_menu(on: bool) -> Result<Value> {
    let path = menu_file();
    if path.is_file() && !ours(&path) {
        return Ok(status());
    }
    if on {
        // the icon from the app's own files (appimage: usr/share/icons inside the mount)
        let shipped = std::env::current_exe()?.parent().map(|b| b.join("../share/icons/hicolor/scalable/apps/noonix-tv.svg"));
        if let Some(src) = shipped.filter(|p| p.is_file()) {
            let dst = icon_file();
            fs::create_dir_all(dst.parent().context("no parent")?)?;
            fs::copy(src, &dst)?;
        }
        write(&path)?;
    } else if path.is_file() {
        fs::remove_file(&path)?;
        let _ = fs::remove_file(icon_file());
    }
    Ok(status())
}

pub fn set_login(on: bool) -> Result<Value> {
    let path = login_file();
    if on {
        write(&path)?;
    } else if path.is_file() {
        fs::remove_file(&path)?;
    }
    Ok(status())
}

/// at start: entries we wrote follow the appimage when it moved
pub fn refresh() {
    let Ok(want) = exec() else { return };
    for path in [menu_file(), login_file()] {
        if ours(&path) && fs::read_to_string(&path).is_ok_and(|t| !t.contains(&format!("Exec={want}\n"))) {
            match write(&path) {
                Ok(()) => tracing::info!("{} points at this copy now", path.display()),
                Err(e) => tracing::warn!("{e:#}"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn entry_is_marked() {
        let e = super::entry("\"/home/a/Noonix TV.AppImage\"");
        assert!(e.contains("Exec=\"/home/a/Noonix TV.AppImage\"\n"));
        assert!(e.contains(super::MARK));
    }
}
