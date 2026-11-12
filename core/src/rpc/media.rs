// what's on and what plays: home.*, progress.*, tmdb.*, playback.*, match.*
use super::{arg_str, current_profile, parse, request_profile};
use crate::{home, playback, store, tmdb, trakt};
use anyhow::{bail, Result};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
struct Dismiss {
    item: Value,
    #[serde(default)]
    undo: bool,
}

#[derive(Deserialize)]
struct Title {
    kind: String,
    tmdb: i64,
}

#[derive(Deserialize)]
struct Details {
    kind: String,
    id: i64,
}

#[derive(Deserialize)]
struct Season {
    show: i64,
    season: i64,
}

pub(super) async fn call(method: &str, args: &Value) -> Result<Value> {
    match method {
        "home.rows" => Ok(match args.get("page").and_then(Value::as_str).unwrap_or("home") {
            "movies" => home::movie_rows(),
            "shows" => home::show_rows(),
            _ => home::rows(),
        }),
        // before the first profile (setup) the catalog rows still load: setup sits over them
        "home.row" => home::row(current_profile().await.unwrap_or(0), arg_str(args, "id")?).await,
        "home.dismiss" => {
            let Dismiss { item, undo } = parse(args)?;
            home::dismiss(request_profile(args).await?, &item, undo).await?;
            Ok(json!({ "ok": true }))
        }

        "progress.clear" => {
            let profile = request_profile(args).await?;
            let t: Title = parse(args)?;
            let kind = if t.kind == "movie" { "movie" } else { "show" };
            let tmdb = t.tmdb;
            store::with(move |c| store::clear_title(c, profile, kind, tmdb)).await?;
            if let Some(acc) = trakt::Account::for_profile(profile).await? {
                acc.clear_title(kind, tmdb).await?;
            }
            Ok(json!({ "ok": true }))
        }

        "tmdb.details" => {
            let Details { kind, id } = parse(args)?;
            let mut d = tmdb::details(&kind, id).await?;
            if kind == "show" {
                annotate_show(&mut d, id).await;
            } else if let Ok(p) = current_profile().await {
                let key = store::movie_key(id);
                if let Ok(Some(pr)) = store::with(move |c| store::get_progress(c, p, &key)).await {
                    d["position"] = json!(pr.position);
                    d["duration"] = json!(pr.duration);
                    d["completed"] = json!(pr.completed);
                }
            }
            Ok(d)
        }
        "tmdb.season" => {
            let Season { show, season } = parse(args)?;
            let mut s = tmdb::season(show, season).await?;
            annotate_episodes(&mut s, show).await;
            Ok(s)
        }
        "tmdb.search" => tmdb::search(arg_str(args, "query")?).await,
        "tmdb.suggest" => tmdb::suggest(arg_str(args, "query")?).await,

        "playback.open" => playback::open(current_profile().await?, args).await,
        "playback.loaded" => playback::loaded(args).await,
        "playback.searchSubs" => playback::search_subs().await,
        "playback.importSub" => playback::import_sub(arg_str(args, "path")?).await,
        "playback.tick" => playback::tick(args).await,
        "playback.stop" => playback::stop(args).await,
        "playback.refresh" => playback::refresh(args).await,
        "playback.sub" => playback::sub_changed(args).await,
        "match.state" => playback::match_state().await,
        "match.rate" => playback::match_rate(args).await,
        "match.nextSub" => playback::match_next_sub(args).await,
        "match.nextSource" => playback::match_next_source(args).await,
        "match.offset" => playback::match_offset(args).await,
        "playback.next" => Ok(playback::next().await.unwrap_or(Value::Null)),
        _ => bail!("unknown method {method}"),
    }
}

/// watched ticks + resume points for a season's episode list
async fn annotate_episodes(season: &mut Value, show: i64) {
    let Ok(profile) = current_profile().await else { return };
    let local = store::with(move |c| store::show_progress(c, profile, show)).await.unwrap_or_default();
    let watched = match trakt::Account::for_reads(profile).await {
        Ok(Some(acc)) => acc.watched_episodes(show).await.unwrap_or_default(),
        _ => Vec::new(),
    };
    if let Some(eps) = season.get_mut("episodes").and_then(Value::as_array_mut) {
        for e in eps {
            let (s, n) = (
                e.get("season").and_then(Value::as_i64).unwrap_or(0),
                e.get("episode").and_then(Value::as_i64).unwrap_or(0),
            );
            let mut done = watched.contains(&(s, n));
            if let Some(p) = local.iter().find(|p| p.season == Some(s) && p.episode == Some(n)) {
                done |= p.completed;
                if !p.completed && p.duration > 0.0 {
                    e["progress"] = json!(p.position / p.duration);
                    e["position"] = json!(p.position);
                }
            }
            e["watched"] = json!(done);
        }
    }
}

/// which episode play/resume should start for a show
async fn annotate_show(d: &mut Value, show: i64) {
    let Ok(profile) = current_profile().await else { return };
    let up = home::up_next(profile).await.ok();
    let next = up.as_ref().and_then(Value::as_array).and_then(|a| {
        a.iter().find(|e| e.get("show").and_then(Value::as_i64) == Some(show)).cloned()
    });
    d["next"] = next.unwrap_or_else(|| json!({ "season": 1, "episode": 1 }));
}
