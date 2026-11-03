use crate::{addons, desktop, home, keepalive, playback, ranking, setup, store, tmdb, trakt, update};
use anyhow::{bail, Context, Result};
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

fn arg_i64(args: &Value, k: &str) -> Result<i64> {
    args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"))
}

/// custom avatars: any png / jpg / webp dropped in ~/.local/share/noonix-tv/avatars
fn avatar_files() -> Vec<String> {
    let dir = crate::config::PATHS.data.join("avatars");
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

/// the profile's picture when its file is still there
fn trakt_relogin(c: &rusqlite::Connection, profile: i64) -> Result<bool> {
    Ok(store::get_setting(c, &format!("profile:{profile}"), "trakt_relogin")?.and_then(|v| v.as_bool()).unwrap_or(false))
}

fn avatar_of(c: &rusqlite::Connection, id: i64) -> Option<String> {
    let name = store::get_setting(c, &format!("profile:{id}"), "avatar").ok().flatten()?;
    let path = crate::config::PATHS.data.join("avatars").join(name.as_str()?);
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

fn set_avatar(c: &rusqlite::Connection, id: i64, file: &str) -> Result<()> {
    // only the file name is kept: the folder can move with the data dir
    let name = std::path::Path::new(file).file_name().and_then(|n| n.to_str()).unwrap_or("").to_owned();
    store::set_setting(c, &format!("profile:{id}"), "avatar", &json!(name))
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

        "setup.accounts" => Ok(setup::accounts()),
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
        "setup.credential" => setup::set_credential(arg_str(&args, "key")?, args.get("value").unwrap_or(&Value::Null)).await,
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
            let id = arg_str(&args, "id")?;
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
            }))
        }
        "setup.finish" => {
            store::with(|c| store::set_setting(c, "app", "setup_done", &json!(true))).await?;
            // an appimage lands in the app menu unless setup turned it off
            let menu = store::with(|c| store::get_setting(c, "app", "menu_entry")).await?;
            if menu.is_none() {
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
        "profiles.setTrakt" => {
            let (id, mode) = (arg_i64(&args, "id")?, arg_str(&args, "mode")?.to_owned());
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
        "keepalive.status" => Ok(keepalive::status()),
        "desktop.status" => Ok(desktop::status()),
        "desktop.set" => {
            let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
            match arg_str(&args, "what")? {
                "menu" => {
                    store::with(move |c| store::set_setting(c, "app", "menu_entry", &json!(on))).await?;
                    tokio::task::spawn_blocking(move || desktop::set_menu(on)).await?
                }
                "login" => tokio::task::spawn_blocking(move || desktop::set_login(on)).await?,
                w => anyhow::bail!("unknown desktop entry {w}"),
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
            let id = arg_i64(&args, "id")?;
            let a = args.clone();
            store::with(move |c| {
                let mut p = store::profiles(c)?.into_iter().find(|p| p.id == id).context("unknown profile")?;
                if let Some(n) = a.get("name").and_then(Value::as_str).map(str::trim).filter(|n| !n.is_empty()) {
                    p.name = n.to_owned();
                }
                if let Some(col) = a.get("color").and_then(Value::as_str) {
                    p.color = col.to_owned();
                }
                store::update_profile(c, &p)?;
                if let Some(f) = a.get("avatar").and_then(Value::as_str) {
                    set_avatar(c, id, f)?;
                }
                Ok(())
            })
            .await?;
            Ok(json!({ "ok": true }))
        }
        "profiles.avatars" => Ok(json!({
            "dir": crate::config::PATHS.data.join("avatars").to_string_lossy(),
            "files": avatar_files(),
        })),
        "profiles.setAvatar" => {
            let id = arg_i64(&args, "id")?;
            let file = args.get("file").and_then(Value::as_str).unwrap_or("").to_owned();
            store::with(move |c| set_avatar(c, id, &file)).await?;
            Ok(json!({ "ok": true }))
        }
        "profiles.add" => {
            let name = arg_str(&args, "name")?.to_owned();
            let color = args.get("color").and_then(Value::as_str).unwrap_or("green").to_owned();
            let trakt = args.get("trakt").and_then(Value::as_str).unwrap_or("none").to_owned();
            let avatar = args.get("avatar").and_then(Value::as_str).unwrap_or("").to_owned();
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
        "profiles.exportSummary" => crate::profile_file::summary(arg_i64(&args, "id")?).await,
        "profiles.export" => {
            let flag = |k: &str| args.get(k).and_then(Value::as_bool).unwrap_or(false);
            crate::profile_file::export(arg_i64(&args, "id")?, args.get("folder").and_then(Value::as_str), flag("watch"), flag("keys")).await
        }
        "profiles.importPreview" => crate::profile_file::preview(arg_str(&args, "path")?).await,
        "profiles.import" => crate::profile_file::import(arg_str(&args, "token")?).await,
        "profiles.select" => {
            let id = arg_i64(&args, "id")?;
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

        "home.rows" => Ok(match args.get("page").and_then(Value::as_str).unwrap_or("home") {
            "movies" => home::movie_rows(),
            "shows" => home::show_rows(),
            _ => home::rows(),
        }),
        // before the first profile (setup) the catalog rows still load: setup sits over them
        "home.row" => home::row(current_profile().await.unwrap_or(0), arg_str(&args, "id")?).await,
        "home.dismiss" => {
            let item = args.get("item").cloned().context("missing item")?;
            let undo = args.get("undo").and_then(Value::as_bool).unwrap_or(false);
            home::dismiss(request_profile(&args).await?, &item, undo).await?;
            Ok(json!({ "ok": true }))
        }

        "tmdb.details" => {
            let kind = arg_str(&args, "kind")?;
            let id = arg_i64(&args, "id")?;
            let mut d = tmdb::details(kind, id).await?;
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
            let show = arg_i64(&args, "show")?;
            let mut s = tmdb::season(show, arg_i64(&args, "season")?).await?;
            annotate_episodes(&mut s, show).await;
            Ok(s)
        }
        "tmdb.search" => tmdb::search(arg_str(&args, "query")?).await,
        "tmdb.suggest" => tmdb::suggest(arg_str(&args, "query")?).await,

        // dev cli: let background work finish between calls
        "dev.wait" => {
            let ms = args.get("ms").and_then(Value::as_u64).unwrap_or(1000).min(60_000);
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            Ok(json!({ "waited": ms }))
        }

        "playback.open" => playback::open(current_profile().await?, &args).await,
        "playback.loaded" => playback::loaded(&args).await,
        "playback.searchSubs" => playback::search_subs().await,
        "playback.importSub" => playback::import_sub(arg_str(&args, "path")?).await,
        "playback.tick" => playback::tick(&args).await,
        "playback.stop" => playback::stop(&args).await,
        "playback.refresh" => playback::refresh(&args).await,
        "playback.sub" => playback::sub_changed(&args).await,
        "match.state" => playback::match_state().await,
        "match.rate" => playback::match_rate(&args).await,
        "match.nextSub" => playback::match_next_sub(&args).await,
        "match.nextSource" => playback::match_next_source(&args).await,
        "match.offset" => playback::match_offset(&args).await,
        "playback.next" => Ok(playback::next().await.unwrap_or(Value::Null)),

        "update.check" => update::check(args.get("auto").and_then(Value::as_bool).unwrap_or(false)).await,
        "update.install" => update::install().await,
        "update.relaunch" => update::relaunch(),

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

        "library.status" => Ok(crate::library::status().await),
        "library.browse" => {
            let path = args.get("path").and_then(Value::as_str).unwrap_or("").to_owned();
            let files: Vec<String> = serde_json::from_value(args.get("files").cloned().unwrap_or(json!([]))).unwrap_or_default();
            tokio::task::spawn_blocking(move || crate::library::browse(&path, &files)).await?
        }
        "library.addFolder" => crate::library::add_folder(arg_str(&args, "path")?).await,
        "library.removeFolder" => crate::library::remove_folder(arg_str(&args, "path")?).await,
        "library.scan" => crate::library::scan().await,
        "library.setOn" => crate::library::set_on(args.get("on").and_then(Value::as_bool).unwrap_or(true)).await,

        // an address or a file: what it adds (the confirm sheet), then install on yes
        "extensions.preview" => crate::extensions::preview(&args).await,
        "extensions.install" => crate::extensions::install(arg_str(&args, "token")?).await,
        "extensions.list" => crate::extensions::list().await,
        "extensions.remove" => crate::extensions::remove(arg_str(&args, "id")?).await.map(|_| json!({ "ok": true })),
        "extensions.enable" => {
            let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
            crate::extensions::set_enabled(arg_str(&args, "id")?, on).await.map(|_| json!({ "ok": true }))
        }
        "extensions.update" => crate::extensions::update(arg_str(&args, "id")?).await,
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
        "addons.add" => Ok(json!(addons::add(arg_str(&args, "url")?).await?)),
        "addons.remove" => addons::remove(arg_i64(&args, "id")?).await.map(|_| json!({ "ok": true })),
        "addons.enable" => {
            let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
            addons::set_enabled(arg_i64(&args, "id")?, on).await.map(|_| json!({ "ok": true }))
        }
        "addons.reorder" => {
            let ids: Vec<i64> = serde_json::from_value(args.get("ids").cloned().context("missing ids")?)?;
            addons::reorder(ids).await.map(|_| json!({ "ok": true }))
        }
        "addons.test" => addons::test(arg_i64(&args, "id")?).await,
        "addons.formatter" => Ok(addons::formatter_template()),

        "streams.list" => {
            let q = addons::Query {
                req: args.get("req").and_then(Value::as_str).unwrap_or("").to_owned(),
                kind: arg_str(&args, "kind")?.to_owned(),
                tmdb: arg_i64(&args, "tmdb")?,
                season: args.get("season").and_then(Value::as_i64),
                episode: args.get("episode").and_then(Value::as_i64),
            };
            addons::streams(current_profile().await?, q).await
        }
        "library.list" => home::library(current_profile().await?, arg_str(&args, "section")?).await,
        "library.state" => {
            let (kind, tmdb) = (arg_str(&args, "kind")?.to_owned(), arg_i64(&args, "tmdb")?);
            Ok(json!({ "inLibrary": home::in_library(request_profile(&args).await?, &kind, tmdb).await? }))
        }
        "library.set" => {
            let (kind, tmdb) = (arg_str(&args, "kind")?.to_owned(), arg_i64(&args, "tmdb")?);
            let on = args.get("on").and_then(Value::as_bool).unwrap_or(true);
            home::set_library(request_profile(&args).await?, &kind, tmdb, on).await?;
            Ok(json!({ "inLibrary": on }))
        }
        "settings.app" => Ok(json!(store::with(|c| store::settings(c, "app")).await?)),
        "settings.setApp" => {
            let key = arg_str(&args, "key")?.to_owned();
            let value = args.get("value").cloned().unwrap_or(Value::Null);
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
            let langs: Vec<String> = serde_json::from_value(args.get("languages").cloned().context("missing languages")?)?;
            let subs: Vec<String> = serde_json::from_value(args.get("subtitles").cloned().context("missing subtitles")?)?;
            setup::set_languages(langs, subs).await?;
            crate::local::changed("languages");
            Ok(json!({ "ok": true }))
        }
        "sources.prefs" => Ok(json!(addons::prefs(current_profile().await?).await)),
        "sources.setPrefs" => {
            let p: ranking::Prefs = serde_json::from_value(args.clone())?;
            let profile = current_profile().await?;
            store::with(move |c| store::set_setting(c, &format!("profile:{profile}"), "sources", &json!(p))).await?;
            crate::local::changed("languages");
            Ok(json!({ "ok": true }))
        }

        "trakt.deviceCode" => trakt::device_code().await,
        "trakt.refresh" => {
            let profile = request_profile(&args).await?;
            let force = args.get("force").and_then(Value::as_bool) == Some(true);
            Ok(json!({ "refreshed": trakt::refresh_if_needed(trakt::Mode::Own, profile, force).await? }))
        }
        "trakt.devicePoll" => {
            let profile = request_profile(&args).await?;
            let ok = trakt::device_poll(profile, arg_str(&args, "code")?).await?.is_some();
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
        "trakt.choose" => trakt::choose(request_profile(&args).await?, arg_str(&args, "choice")?).await,

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
