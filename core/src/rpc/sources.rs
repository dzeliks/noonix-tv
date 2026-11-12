// where videos come from and how they're picked: addons.*, streams.*, extensions.*, patterns.*,
// sources.*
use super::{arg_i64, arg_str, current_profile, parse};
use crate::{addons, ranking, store};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
struct Enable<Id> {
    id: Id,
    #[serde(default = "yes")]
    on: bool,
}

#[derive(Deserialize)]
struct StreamsFor {
    #[serde(default)]
    req: String,
    kind: String,
    tmdb: i64,
    season: Option<i64>,
    episode: Option<i64>,
}

pub(super) async fn call(method: &str, args: &Value) -> Result<Value> {
    match method {
        // an address or a file: what it adds (the confirm sheet), then install on yes
        "extensions.preview" => crate::extensions::preview(args).await,
        "extensions.install" => crate::extensions::install(arg_str(args, "token")?).await,
        "extensions.list" => crate::extensions::list().await,
        "extensions.remove" => crate::extensions::remove(arg_str(args, "id")?).await.map(|_| json!({ "ok": true })),
        "extensions.enable" => {
            let e: Enable<String> = parse(args)?;
            crate::extensions::set_enabled(&e.id, e.on).await.map(|_| json!({ "ok": true }))
        }
        "extensions.update" => crate::extensions::update(arg_str(args, "id")?).await,
        // the user's release patterns: {preferred: [...], excluded: [...]}
        "patterns.get" => Ok(store::with(|c| {
            let (p, e) = addons::user_patterns(c);
            Ok(json!({ "preferred": p, "excluded": e }))
        })
        .await?),
        "patterns.set" => {
            let clean = |k: &str| -> Result<Vec<String>> {
                let list: Vec<String> = serde_json::from_value(args.get(k).cloned().unwrap_or(json!([])))?;
                let list: Vec<String> = list.into_iter().map(|p| p.trim().to_owned()).filter(|p| !p.is_empty()).take(50).collect();
                if let Some(bad) = list.iter().find(|p| ranking::pattern(p).is_none()) {
                    bail!("This pattern doesn't work: {bad}");
                }
                Ok(list)
            };
            let v = json!({ "preferred": clean("preferred")?, "excluded": clean("excluded")? });
            let out = v.clone();
            store::with(move |c| {
                store::set_setting(c, "app", "patterns", &v)?;
                store::cache_drop_prefix(c, "streams:")?;
                Ok(())
            })
            .await?;
            Ok(out)
        }

        "addons.list" => Ok(json!(addons::list().await?)),
        "addons.add" => Ok(json!(addons::add(arg_str(args, "url")?).await?)),
        "addons.remove" => addons::remove(arg_i64(args, "id")?).await.map(|_| json!({ "ok": true })),
        "addons.enable" => {
            let e: Enable<i64> = parse(args)?;
            addons::set_enabled(e.id, e.on).await.map(|_| json!({ "ok": true }))
        }
        "addons.reorder" => {
            let ids: Vec<i64> = serde_json::from_value(args.get("ids").cloned().context("missing ids")?)?;
            addons::reorder(ids).await.map(|_| json!({ "ok": true }))
        }
        "addons.test" => addons::test(arg_i64(args, "id")?).await,
        "addons.formatter" => Ok(addons::formatter_template()),

        "streams.list" => {
            let s: StreamsFor = parse(args)?;
            let q = addons::Query { req: s.req, kind: s.kind, tmdb: s.tmdb, season: s.season, episode: s.episode };
            addons::streams(current_profile().await?, q).await
        }
        "sources.prefs" => Ok(json!(addons::prefs(current_profile().await?).await)),
        "sources.setPrefs" => {
            let p: ranking::Prefs = parse(args)?;
            let profile = current_profile().await?;
            store::with(move |c| store::set_setting(c, &format!("profile:{profile}"), "sources", &json!(p))).await?;
            crate::local::changed("languages");
            Ok(json!({ "ok": true }))
        }
        _ => bail!("unknown method {method}"),
    }
}
