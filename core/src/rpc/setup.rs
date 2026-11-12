// setup, this device and the app's own settings: setup.*, bench.*, quality.*, desktop.*,
// keepalive.*, tvServer.*, settings.*, languages.*
use super::{arg_str, current_profile, parse, profiles::trakt_relogin, TERMS_VERSION};
use crate::{desktop, keepalive, ranking, setup, store};
use anyhow::{bail, Result};
use serde::Deserialize;
use serde_json::{json, Value};

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Allow {
    #[serde(default)]
    ip: String,
    #[serde(default)]
    allow: bool,
}

#[derive(Deserialize)]
struct DesktopEntry {
    what: String,
    #[serde(default = "yes")]
    on: bool,
}

#[derive(Deserialize)]
struct Languages {
    languages: Vec<String>,
    subtitles: Vec<String>,
}

#[derive(Deserialize)]
struct AppSetting {
    key: String,
    #[serde(default)]
    value: Value,
}

pub(super) async fn call(method: &str, args: &Value) -> Result<Value> {
    match method {
        "setup.accounts" => Ok(setup::accounts()),
        // this computer as the tvs' streaming server (torrents for lg / samsung)
        "tvServer.state" => Ok(crate::tvserver::state().await),
        "tvServer.set" => crate::tvserver::set(args.get("on").and_then(Value::as_bool).unwrap_or(false)).await,
        "tvServer.allow" => {
            let a: Allow = parse(args)?;
            crate::tvserver::allow(a.ip, a.allow).await
        }
        "tvServer.forget" => crate::tvserver::forget().await,
        "setup.torrents" => {
            setup::set_torrents(args.get("on").and_then(Value::as_bool).unwrap_or(false)).await?;
            Ok(setup::accounts())
        }
        // terms seen and agreed to in setup (the version they said yes to)
        "setup.agree" => {
            let v = json!(TERMS_VERSION);
            store::with(move |c| store::set_setting(c, "app", "terms_agreed", &v)).await?;
            Ok(json!({ "ok": true }))
        }
        "setup.credential" => setup::set_credential(arg_str(args, "key")?, args.get("value").unwrap_or(&Value::Null)).await,
        // kept for the quality recommendation (settings shows it later too)
        "bench.internet" => {
            // skipped or offline: the old reading goes too, the level then follows the device alone
            let v = match crate::bench::internet().await {
                Ok(v) => v,
                Err(e) => {
                    let _ = store::with(|c| store::set_setting(c, "app", "bench_net", &Value::Null)).await;
                    return Err(e);
                }
            };
            let m = v["mbps"].clone();
            store::with(move |c| store::set_setting(c, "app", "bench_net", &m)).await?;
            Ok(v)
        }
        "bench.sample" => Ok(json!({ "path": crate::bench::sample().await? })),
        "bench.skipInternet" => {
            crate::bench::skip_internet();
            Ok(json!({ "ok": true }))
        }
        "bench.device" => {
            // fps: the client decoded the clip with the player (bench.sample); without it, the cpu test
            crate::bench::drop_sample();
            let v = match args.get("fps").and_then(Value::as_f64) {
                Some(fps) => json!({ "score": fps.round().max(0.0) as u32, "source": "decode" }),
                None => crate::bench::device().await?,
            };
            let d = v["score"].clone();
            store::with(move |c| store::set_setting(c, "app", "bench_decode", &d)).await?;
            Ok(v)
        }
        "quality.options" => Ok(crate::quality::options().await),
        "quality.set" => {
            let id = arg_str(args, "id")?;
            if !crate::quality::LEVELS.iter().any(|l| l.id == id) {
                bail!("unknown quality level");
            }
            let v = json!(id);
            store::with(move |c| store::set_setting(c, "app", "quality", &v)).await?;
            // the other addons' answers were ranked for the old level
            let _ = store::with(|c| store::cache_drop_prefix(c, "streams:")).await;
            crate::local::changed("quality");
            Ok(crate::quality::options().await)
        }
        "setup.state" => {
            let (done, profiles) = store::with(|c| Ok((store::get_setting(c, "app", "setup_done")?, store::profiles(c)?))).await?;
            let mut desk = desktop::status();
            desk["menuChosen"] = store::with(|c| store::get_setting(c, "app", "menu_entry")).await?.unwrap_or(Value::Null);
            let mut keep = keepalive::status();
            keep["chosen"] = store::with(|c| store::get_setting(c, "app", "keepalive_timer")).await?.unwrap_or(Value::Null);
            Ok(json!({
                "done": done.and_then(|v| v.as_bool()).unwrap_or(false),
                "profiles": profiles,
                "balkanOn": store::with(|c| store::get_setting(c, "app", "balkan_subs")).await?.and_then(|v| v.as_bool()).unwrap_or(false),
                "termsAgreed": store::with(|c| store::get_setting(c, "app", "terms_agreed")).await?.and_then(|v| v.as_u64()) == Some(TERMS_VERSION),
                "library": crate::library::status().await,
                "traktRelogin": match current_profile().await {
                    Ok(id) => store::with(move |c| trakt_relogin(c, id)).await?,
                    Err(_) => false,
                },
                "keepalive": keep,
                "desktop": desk,
                "accounts": setup::accounts(),
                "dataError": store::open_error(),
            }))
        }
        "setup.finish" => {
            store::with(|c| store::set_setting(c, "app", "setup_done", &json!(true))).await?;
            // an appimage lands in the app menu unless setup turned it off (linux: xdg files)
            let menu = store::with(|c| store::get_setting(c, "app", "menu_entry")).await?;
            if menu.is_none() && cfg!(target_os = "linux") {
                if let Err(e) = tokio::task::spawn_blocking(|| desktop::set_menu(true)).await? {
                    tracing::warn!("app menu entry: {e:#}");
                }
            }
            // the daily check is on unless setup turned it off
            let chosen = store::with(|c| store::get_setting(c, "app", "keepalive_timer")).await?;
            if chosen.is_none() && keepalive::status()["scheduler"].as_bool() == Some(true) {
                if let Err(e) = tokio::task::spawn_blocking(keepalive::install).await? {
                    tracing::warn!("keepalive timer: {e:#}");
                }
            }
            Ok(json!({ "ok": true }))
        }
        "keepalive.status" => Ok(keepalive::status()),
        "desktop.status" => Ok(desktop::status()),
        "desktop.set" => {
            let DesktopEntry { what, on } = parse(args)?;
            match what.as_str() {
                "menu" => {
                    store::with(move |c| store::set_setting(c, "app", "menu_entry", &json!(on))).await?;
                    tokio::task::spawn_blocking(move || desktop::set_menu(on)).await?
                }
                "login" => tokio::task::spawn_blocking(move || desktop::set_login(on)).await?,
                w => bail!("unknown desktop entry {w}"),
            }
        }
        "keepalive.run" => keepalive::run().await,
        "keepalive.install" | "keepalive.remove" => {
            let on = method == "keepalive.install";
            store::with(move |c| store::set_setting(c, "app", "keepalive_timer", &json!(on))).await?;
            tokio::task::spawn_blocking(move || if on { keepalive::install() } else { keepalive::remove() }).await?
        }
        "setup.setBalkan" => {
            let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
            setup::set_balkan(on).await?;
            crate::local::changed("balkan");
            Ok(json!({ "balkanSubtitles": on }))
        }
        "settings.app" => Ok(json!(store::with(|c| store::settings(c, "app")).await?)),
        "settings.setApp" => {
            let AppSetting { key, value } = parse(args)?;
            store::with(move |c| store::set_setting(c, "app", &key, &value)).await?;
            Ok(json!({ "ok": true }))
        }
        "languages.options" => {
            let balkan = store::with(|c| store::get_setting(c, "app", "balkan_subs")).await?.and_then(|v| v.as_bool()).unwrap_or(false);
            Ok(json!({
                "audio": ranking::language_options(false, balkan),
                "subtitles": ranking::language_options(true, balkan),
            }))
        }
        "setup.setLanguages" => {
            let Languages { languages, subtitles } = parse(args)?;
            setup::set_languages(languages, subtitles).await?;
            crate::local::changed("languages");
            Ok(json!({ "ok": true }))
        }
        _ => bail!("unknown method {method}"),
    }
}
