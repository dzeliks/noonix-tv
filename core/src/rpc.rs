// the core's calls by name, for every client (qml, swift, the dev cli). each domain answers in its
// own file; the names and their fields are what three clients rely on
mod library;
mod media;
mod profiles;
mod setup;
mod sources;

use crate::{ranking, store, update};
use anyhow::{bail, Context, Result};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicI64, Ordering};

static PROFILE: AtomicI64 = AtomicI64::new(0);
/// bumped when the terms setup shows change: everyone agrees again
pub const TERMS_VERSION: u64 = 1;

pub async fn current_profile() -> Result<i64> {
    let p = PROFILE.load(Ordering::Relaxed);
    if p > 0 {
        return Ok(p);
    }
    let id = store::with(|c| {
        let saved = store::get_setting(c, "app", "profile")?.and_then(|v| v.as_i64());
        let all = store::profiles(c)?;
        Ok(saved.filter(|s| all.iter().any(|p| p.id == *s)).or(all.first().map(|p| p.id)))
    })
    .await?
    .context("no profile yet")?;
    PROFILE.store(id, Ordering::Relaxed);
    Ok(id)
}

/// a call's fields as one struct (missing ones named in the error)
fn parse<T: DeserializeOwned>(args: &Value) -> Result<T> {
    Ok(serde_json::from_value(args.clone())?)
}

fn arg_i64(args: &Value, k: &str) -> Result<i64> {
    args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"))
}

fn arg_str<'a>(args: &'a Value, k: &str) -> Result<&'a str> {
    args.get(k).and_then(Value::as_str).with_context(|| format!("missing {k}"))
}

/// the profile a call names (the ui pins it so a switch mid-call can't hit the other one)
async fn request_profile(args: &Value) -> Result<i64> {
    let Some(id) = args.get("profile").and_then(Value::as_i64).filter(|id| *id > 0) else {
        return current_profile().await;
    };
    store::with(move |c| {
        if !store::profiles(c)?.iter().any(|p| p.id == id) {
            bail!("unknown profile");
        }
        Ok(id)
    })
    .await
}

pub async fn dispatch(method: &str, args: Value) -> Result<Value> {
    match method.split_once('.').map_or(method, |(domain, _)| domain) {
        "setup" | "bench" | "quality" | "desktop" | "keepalive" | "tvServer" | "settings" | "languages" => setup::call(method, &args).await,
        "profiles" | "trakt" => profiles::call(method, &args).await,
        "home" | "progress" | "tmdb" | "playback" | "match" => media::call(method, &args).await,
        "addons" | "streams" | "extensions" | "patterns" | "sources" => sources::call(method, &args).await,
        "library" | "shares" | "local" => library::call(method, &args).await,
        _ => general(method, args).await,
    }
}

async fn general(method: &str, args: Value) -> Result<Value> {
    match method {
        "ping" => Ok(json!({ "pong": true, "version": env!("CARGO_PKG_VERSION"), "echo": args })),
        // what the screen shows (hdr, dolby vision reshaping), for the source ranking
        "display.caps" => {
            ranking::set_display(serde_json::from_value(args)?);
            Ok(json!({}))
        }
        // what was found, for the settings' hdr row
        "display.state" => Ok(json!(ranking::display())),
        // a qr code as svg, black on white with the quiet zone (a phone opens the link)
        "qr" => {
            let code = qrcode::QrCode::new(arg_str(&args, "text")?.as_bytes())?;
            let svg = code.render::<qrcode::render::svg::Color>().min_dimensions(256, 256).quiet_zone(true).build();
            Ok(json!({ "svg": svg }))
        }
        // dev cli: let background work finish between calls
        "dev.wait" => {
            let ms = args.get("ms").and_then(Value::as_u64).unwrap_or(1000).min(60_000);
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            Ok(json!({ "waited": ms }))
        }
        "update.check" => update::check(args.get("auto").and_then(Value::as_bool).unwrap_or(false)).await,
        "update.install" => update::install().await,
        "update.relaunch" => update::relaunch(),
        _ => bail!("unknown method {method}"),
    }
}
