// who's watching and their trakt login: profiles.*, trakt.*
use super::{arg_i64, arg_str, current_profile, parse, request_profile, PROFILE};
use crate::{store, trakt};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;

/// custom avatars: any png / jpg / webp dropped in ~/.local/share/noonix-tv/avatars
fn avatar_files() -> Vec<String> {
    let dir = crate::config::avatars();
    let _ = std::fs::create_dir_all(&dir);
    let mut out: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    p.extension()
                        .and_then(|x| x.to_str())
                        .is_some_and(|x| matches!(x.to_ascii_lowercase().as_str(), "png" | "jpg" | "jpeg" | "webp"))
                })
                .map(|p| p.to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

pub(super) fn trakt_relogin(c: &rusqlite::Connection, profile: i64) -> Result<bool> {
    Ok(store::get_setting(c, &format!("profile:{profile}"), "trakt_relogin")?.and_then(|v| v.as_bool()).unwrap_or(false))
}

/// the profile's picture when its file is still there
fn avatar_of(c: &rusqlite::Connection, id: i64) -> Option<String> {
    let name = store::get_setting(c, &format!("profile:{id}"), "avatar").ok().flatten()?;
    let path = crate::config::avatars().join(name.as_str()?);
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

fn set_avatar(c: &rusqlite::Connection, id: i64, file: &str) -> Result<()> {
    // only the file name is kept: the folder can move with the data dir
    let name = std::path::Path::new(file).file_name().and_then(|n| n.to_str()).unwrap_or("").to_owned();
    store::set_setting(c, &format!("profile:{id}"), "avatar", &json!(name))
}

fn green() -> String {
    "green".into()
}
fn no_trakt() -> String {
    "none".into()
}

#[derive(Deserialize)]
struct NewProfile {
    name: String,
    #[serde(default = "green")]
    color: String,
    #[serde(default = "no_trakt")]
    trakt: String,
    #[serde(default)]
    avatar: String,
}

#[derive(Deserialize)]
struct Changes {
    id: i64,
    name: Option<String>,
    color: Option<String>,
    avatar: Option<String>,
}

#[derive(Deserialize)]
struct Avatar {
    id: i64,
    #[serde(default)]
    file: String,
}

#[derive(Deserialize)]
struct TraktMode {
    id: i64,
    mode: String,
}

#[derive(Deserialize)]
struct Export {
    id: i64,
    folder: Option<String>,
    #[serde(default)]
    watch: bool,
    #[serde(default)]
    keys: bool,
}

pub(super) async fn call(method: &str, args: &Value) -> Result<Value> {
    match method {
        "profiles.setTrakt" => {
            let TraktMode { id, mode } = parse(args)?;
            if !matches!(mode.as_str(), "own" | "none") {
                bail!("unknown trakt mode");
            }
            store::with(move |c| {
                let mut p = store::profiles(c)?.into_iter().find(|p| p.id == id).context("unknown profile")?;
                p.trakt = mode;
                store::update_profile(c, &p)?;
                // the next sign-in asks again
                c.execute("delete from settings where scope = ?1 and key = 'trakt_local'", [format!("profile:{id}")])?;
                Ok(())
            })
            .await?;
            Ok(json!({ "ok": true }))
        }
        "profiles.list" => {
            let current = current_profile().await.unwrap_or(0);
            let list = store::with(|c| {
                Ok(store::profiles(c)?
                    .into_iter()
                    .map(|p| {
                        let mut v = json!(p);
                        if let Some(a) = avatar_of(c, p.id) {
                            v["avatar"] = json!(a);
                        }
                        // its trakt login is gone (refused, or from before): it signs in once more
                        v["traktRelogin"] = json!(trakt_relogin(c, p.id).unwrap_or(false));
                        v
                    })
                    .collect::<Vec<_>>())
            })
            .await?;
            Ok(json!({ "current": current, "profiles": list }))
        }
        "profiles.update" => {
            let ch: Changes = parse(args)?;
            store::with(move |c| {
                let mut p = store::profiles(c)?.into_iter().find(|p| p.id == ch.id).context("unknown profile")?;
                if let Some(n) = ch.name.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                    p.name = n.to_owned();
                }
                if let Some(col) = ch.color {
                    p.color = col;
                }
                store::update_profile(c, &p)?;
                if let Some(f) = ch.avatar {
                    set_avatar(c, ch.id, &f)?;
                }
                Ok(())
            })
            .await?;
            Ok(json!({ "ok": true }))
        }
        "profiles.avatars" => Ok(json!({
            "dir": crate::config::avatars().to_string_lossy(),
            "files": avatar_files(),
        })),
        // a picture picked from a phone's gallery (only those: the rest are the user's own files)
        "profiles.removeAvatar" => {
            let dir = crate::config::avatars();
            let file = std::path::PathBuf::from(arg_str(args, "file")?);
            let picked = file.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("picture-"));
            if picked && file.parent() == Some(dir.as_path()) {
                std::fs::remove_file(&file)?;
            }
            Ok(json!({ "files": avatar_files() }))
        }
        "profiles.setAvatar" => {
            let Avatar { id, file } = parse(args)?;
            store::with(move |c| set_avatar(c, id, &file)).await?;
            Ok(json!({ "ok": true }))
        }
        "profiles.add" => {
            let NewProfile { name, color, trakt, avatar } = parse(args)?;
            let id = store::with(move |c| {
                let id = store::add_profile(c, &name, &color, &trakt)?;
                if !avatar.is_empty() {
                    set_avatar(c, id, &avatar)?;
                }
                Ok(id)
            })
            .await?;
            Ok(json!({ "id": id }))
        }
        // a profile as a .noonix file and back (profile_file.rs)
        "profiles.exportSummary" => crate::profile_file::summary(arg_i64(args, "id")?).await,
        "profiles.export" => {
            let e: Export = parse(args)?;
            crate::profile_file::export(e.id, e.folder.as_deref(), e.watch, e.keys).await
        }
        "profiles.importPreview" => crate::profile_file::preview(arg_str(args, "path")?).await,
        "profiles.import" => crate::profile_file::import(arg_str(args, "token")?).await,
        "profiles.select" => {
            let id = arg_i64(args, "id")?;
            store::with(move |c| {
                if !store::profiles(c)?.iter().any(|p| p.id == id) {
                    bail!("unknown profile");
                }
                store::set_setting(c, "app", "profile", &json!(id))
            })
            .await?;
            PROFILE.store(id, Ordering::Relaxed);
            crate::local::changed("profile");
            Ok(json!({ "id": id }))
        }

        "trakt.deviceCode" => trakt::device_code().await,
        "trakt.refresh" => {
            let profile = request_profile(args).await?;
            let force = args.get("force").and_then(Value::as_bool) == Some(true);
            Ok(json!({ "refreshed": trakt::refresh_if_needed(trakt::Mode::Own, profile, force).await? }))
        }
        "trakt.devicePoll" => {
            let profile = request_profile(args).await?;
            let ok = trakt::device_poll(profile, arg_str(args, "code")?).await?.is_some();
            let mut local = Value::Null;
            if ok {
                let (again, counts) = store::with(move |c| {
                    let mut p = store::profiles(c)?.into_iter().find(|p| p.id == profile).context("profile")?;
                    let again = p.trakt == "own";
                    p.trakt = "own".into();
                    store::update_profile(c, &p)?;
                    c.execute("delete from settings where scope = ?1 and key = 'trakt_relogin'", [format!("profile:{profile}")])?;
                    Ok((again, store::local_counts(c, profile)?))
                })
                .await?;
                // a login that ran out has answered this already
                if !again && counts != (0, 0, 0) {
                    local = json!({ "watched": counts.0, "progress": counts.1, "library": counts.2 });
                }
            }
            Ok(json!({ "done": ok, "local": local }))
        }
        "trakt.choose" => trakt::choose(request_profile(args).await?, arg_str(args, "choice")?).await,
        _ => bail!("unknown method {method}"),
    }
}
