// the viewer's own videos and list: library.*, shares.*, local.*
use super::{arg_str, current_profile, parse, request_profile};
use crate::home;
use anyhow::{bail, Result};
use serde::Deserialize;
use serde_json::{json, Value};

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Share {
    #[serde(default)]
    kind: String,
    #[serde(default)]
    address: String,
    #[serde(default)]
    user: String,
    #[serde(default)]
    password: String,
}

#[derive(Deserialize)]
struct InLibrary {
    kind: String,
    tmdb: i64,
    #[serde(default = "yes")]
    on: bool,
}

pub(super) async fn call(method: &str, args: &Value) -> Result<Value> {
    match method {
        "library.status" => Ok(crate::library::status().await),
        "library.browse" => {
            let path = args.get("path").and_then(Value::as_str).unwrap_or("").to_owned();
            let files: Vec<String> = serde_json::from_value(args.get("files").cloned().unwrap_or(json!([]))).unwrap_or_default();
            if crate::shares::is_share(&path) {
                return crate::shares::browse(&path).await;
            }
            let start = path.is_empty();
            let mut v = tokio::task::spawn_blocking(move || crate::library::browse(&path, &files)).await??;
            // the saved network shares are places too
            if start {
                if let Some(list) = v.get_mut("folders").and_then(Value::as_array_mut) {
                    list.extend(crate::shares::places().await);
                }
            }
            Ok(v)
        }
        "shares.add" => {
            let s: Share = parse(args)?;
            crate::shares::add(&s.kind, &s.address, &s.user, &s.password).await
        }
        "shares.remove" => crate::shares::remove(arg_str(args, "path")?).await,
        "library.addFolder" => crate::library::add_folder(arg_str(args, "path")?).await,
        "library.removeFolder" => crate::library::remove_folder(arg_str(args, "path")?).await,
        "library.scan" => crate::library::scan().await,
        "library.setOn" => crate::library::set_on(args.get("on").and_then(Value::as_bool).unwrap_or(true)).await,
        "library.list" => home::library(current_profile().await?, arg_str(args, "section")?).await,
        "library.state" => {
            let t: InLibrary = parse(args)?;
            Ok(json!({ "inLibrary": home::in_library(request_profile(args).await?, &t.kind, t.tmdb).await? }))
        }
        "library.set" => {
            let t: InLibrary = parse(args)?;
            home::set_library(request_profile(args).await?, &t.kind, t.tmdb, t.on).await?;
            Ok(json!({ "inLibrary": t.on }))
        }

        // what this build brings along (nothing in the public app)
        "local.status" => Ok(crate::local::status().await),
        "local.start" => {
            crate::local::start();
            // {"wait": true}: until it all answers (smoke tests)
            if args.get("wait").and_then(Value::as_bool) == Some(true) {
                crate::local::wait().await;
            }
            Ok(crate::local::status().await)
        }
        "local.stop" => {
            crate::local::stop().await;
            Ok(crate::local::status().await)
        }
        _ => bail!("unknown method {method}"),
    }
}
