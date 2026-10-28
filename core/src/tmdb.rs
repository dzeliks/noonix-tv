use crate::config::{self, keys};
use crate::http::{self, Req};
use anyhow::{anyhow, Result};
use serde_json::{json, Map, Value};

const API: &str = "https://api.themoviedb.org/3";
pub const IMG: &str = "https://image.tmdb.org/t/p/";
pub const REGION: &str = "RS";
const LANG: &str = "en-US";

// ttl, seconds
const TTL_LIST: i64 = 6 * 3600;
const TTL_DETAILS: i64 = 3 * 86400;
const TTL_SEASON: i64 = 12 * 3600;

fn request(path: &str, query: &[(&str, String)]) -> Result<Req> {
    let mut url = url::Url::parse(&format!("{API}{path}"))?;
    {
        let mut q = url.query_pairs_mut();
        q.append_pair("language", LANG);
        for (k, v) in query {
            q.append_pair(k, v);
        }
        if let Some(key) = config::secret(keys::TMDB_API_KEY) {
            q.append_pair("api_key", &key);
        }
    }
    let mut req = Req::get(url.to_string());
    if !config::has_secret(keys::TMDB_API_KEY) {
        let token = config::secret(keys::TMDB_READ_TOKEN).ok_or_else(|| anyhow!("no tmdb key"))?;
        req = req.header("authorization", &format!("Bearer {token}"));
    }
    Ok(req)
}

/// tmdb said no to the key this run (a revoked built-in one, a typo): settings offers your own
pub static REFUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

async fn get(path: &str, query: &[(&str, String)], ttl: i64) -> Result<Value> {
    use std::sync::atomic::Ordering;
    let cache_key = format!(
        "tmdb:{path}?{}",
        query.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("&")
    );
    let r = http::cached_json(&cache_key, ttl, request(path, query)?).await;
    if let Err(e) = &r {
        if e.downcast_ref::<http::HttpError>().is_some_and(|h| h.status() == 401) && !REFUSED.swap(true, Ordering::SeqCst) {
            crate::app::emit("notice", json!({ "message": "TMDB refused the key: add your own in Settings › Accounts" }));
        }
    }
    r
}

pub fn img(path: Option<&str>, size: &str) -> Value {
    match path {
        Some(p) if !p.is_empty() => Value::String(format!("{IMG}{size}{p}")),
        _ => Value::Null,
    }
}

fn year(date: Option<&str>) -> Value {
    date.and_then(|d| d.get(..4)).and_then(|y| y.parse::<i64>().ok()).map_or(Value::Null, Value::from)
}

fn genre_name(id: i64) -> Option<&'static str> {
    Some(match id {
        28 => "Action",
        12 => "Adventure",
        16 => "Animation",
        35 => "Comedy",
        80 => "Crime",
        99 => "Documentary",
        18 => "Drama",
        10751 => "Family",
        14 => "Fantasy",
        36 => "History",
        27 => "Horror",
        10402 => "Music",
        9648 => "Mystery",
        10749 => "Romance",
        878 => "Science Fiction",
        10770 => "TV Movie",
        53 => "Thriller",
        10752 => "War",
        37 => "Western",
        10759 => "Action & Adventure",
        10762 => "Kids",
        10763 => "News",
        10764 => "Reality",
        10765 => "Sci-Fi & Fantasy",
        10766 => "Soap",
        10767 => "Talk",
        10768 => "War & Politics",
        _ => return None,
    })
}

/// one shape for every list/card in the ui
pub fn item(kind: &str, v: &Value) -> Value {
    let is_movie = kind == "movie";
    let title = v.get(if is_movie { "title" } else { "name" }).or(v.get("title")).or(v.get("name"));
    let date = v
        .get(if is_movie { "release_date" } else { "first_air_date" })
        .and_then(Value::as_str);
    let genres: Vec<Value> = match v.get("genres").and_then(Value::as_array) {
        Some(g) => g.iter().filter_map(|g| g.get("name").cloned()).collect(),
        None => v
            .get("genre_ids")
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(|i| i.as_i64().and_then(genre_name)).map(Value::from).collect())
            .unwrap_or_default(),
    };
    json!({
        "kind": if is_movie { "movie" } else { "show" },
        "id": v.get("id"),
        "title": title,
        "year": year(date),
        "date": date,
        "overview": v.get("overview"),
        "poster": img(v.get("poster_path").and_then(Value::as_str), "w500"),
        "backdrop": img(v.get("backdrop_path").and_then(Value::as_str), "w1280"),
        "rating": v.get("vote_average").and_then(Value::as_f64).map(|r| (r * 10.0).round() / 10.0),
        "genres": genres,
        "originalLanguage": v.get("original_language"),
    })
}

fn results(kind: &str, v: &Value) -> Value {
    Value::Array(
        v.get("results")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter(|r| r.get("poster_path").is_some_and(|p| !p.is_null()))
                    .map(|r| item(kind, r))
                    .collect()
            })
            .unwrap_or_default(),
    )
}

fn path_kind(kind: &str) -> &'static str {
    if kind == "movie" {
        "movie"
    } else {
        "tv"
    }
}

pub async fn popular(kind: &str, page: u32) -> Result<Value> {
    let v = get(&format!("/{}/popular", path_kind(kind)), &[("page", page.to_string()), ("region", REGION.into())], TTL_LIST).await?;
    Ok(results(kind, &v))
}

pub async fn trending(kind: &str) -> Result<Value> {
    let v = get(&format!("/trending/{}/week", path_kind(kind)), &[], TTL_LIST).await?;
    Ok(results(kind, &v))
}

pub async fn top_rated(kind: &str) -> Result<Value> {
    let v = get(&format!("/{}/top_rated", path_kind(kind)), &[("region", REGION.into())], TTL_LIST).await?;
    Ok(results(kind, &v))
}

/// discover with optional watch providers and genre
pub async fn discover(kind: &str, providers: &[i64], genre: Option<i64>, page: u32) -> Result<Value> {
    let mut q = vec![("sort_by", "popularity.desc".to_owned()), ("page", page.to_string())];
    if !providers.is_empty() {
        q.push(("with_watch_providers", providers.iter().map(i64::to_string).collect::<Vec<_>>().join("|")));
        q.push(("watch_region", REGION.into()));
    }
    if let Some(g) = genre {
        q.push(("with_genres", g.to_string()));
    }
    let v = get(&format!("/discover/{}", path_kind(kind)), &q, TTL_LIST).await?;
    Ok(results(kind, &v))
}

/// the best match for a name read from a file (and its year): the library's matching. a month
/// in the cache, the same names come back on every scan
pub async fn find(kind: &str, name: &str, year: Option<i64>) -> Result<Option<i64>> {
    let path = if kind == "movie" { "/search/movie" } else { "/search/tv" };
    let year_key = if kind == "movie" { "year" } else { "first_air_date_year" };
    let first = |v: &Value| v.get("results").and_then(Value::as_array).and_then(|a| a.first()).and_then(|r| r.get("id")).and_then(Value::as_i64);
    let mut q = vec![("query", name.to_owned()), ("include_adult", "false".into())];
    if let Some(y) = year {
        q.push((year_key, y.to_string()));
        if let Some(id) = first(&get(path, &q, 30 * 86400).await?) {
            return Ok(Some(id));
        }
        q.pop();
    }
    Ok(first(&get(path, &q, 30 * 86400).await?))
}

pub async fn search(query: &str) -> Result<Value> {
    let v = get("/search/multi", &[("query", query.to_owned()), ("include_adult", "false".into())], 3600).await?;
    let mut out = Vec::new();
    for r in v.get("results").and_then(Value::as_array).into_iter().flatten() {
        match r.get("media_type").and_then(Value::as_str) {
            Some("movie") if r.get("poster_path").is_some_and(|p| !p.is_null()) => out.push(item("movie", r)),
            Some("tv") if r.get("poster_path").is_some_and(|p| !p.is_null()) => out.push(item("show", r)),
            _ => {}
        }
    }
    Ok(Value::Array(out))
}

fn pick_logo(images: &Value) -> Value {
    let logos = images.get("logos").and_then(Value::as_array);
    let best = logos.and_then(|l| {
        l.iter()
            .filter(|x| matches!(x.get("iso_639_1").and_then(Value::as_str), Some("en")))
            .max_by(|a, b| {
                let va = a.get("vote_average").and_then(Value::as_f64).unwrap_or(0.0);
                let vb = b.get("vote_average").and_then(Value::as_f64).unwrap_or(0.0);
                va.total_cmp(&vb)
            })
            .or_else(|| l.first())
    });
    // svg logos come as .svg; qt renders png better at size
    let path = best.and_then(|b| b.get("file_path")).and_then(Value::as_str).map(|p| p.replace(".svg", ".png"));
    img(path.as_deref(), "w500")
}

/// textless backdrop when there is one (hero art), else the default
fn pick_backdrop(v: &Value) -> Value {
    let textless = v
        .pointer("/images/backdrops")
        .and_then(Value::as_array)
        .and_then(|b| b.iter().find(|x| x.get("iso_639_1").is_some_and(Value::is_null)))
        .and_then(|b| b.get("file_path"))
        .and_then(Value::as_str);
    img(textless.or(v.get("backdrop_path").and_then(Value::as_str)), "original")
}

fn certification(kind: &str, v: &Value) -> Value {
    let pick = |arr: Option<&Vec<Value>>, field: &str| -> Option<String> {
        let arr = arr?;
        for region in [REGION, "US", "GB"] {
            if let Some(r) = arr.iter().find(|r| r.get("iso_3166_1").and_then(Value::as_str) == Some(region)) {
                if kind == "movie" {
                    let c = r
                        .get("release_dates")
                        .and_then(Value::as_array)
                        .and_then(|d| d.iter().filter_map(|x| x.get(field)?.as_str()).find(|c| !c.is_empty()));
                    if let Some(c) = c {
                        return Some(c.to_owned());
                    }
                } else if let Some(c) = r.get(field).and_then(Value::as_str).filter(|c| !c.is_empty()) {
                    return Some(c.to_owned());
                }
            }
        }
        None
    };
    if kind == "movie" {
        pick(v.pointer("/release_dates/results").and_then(Value::as_array), "certification").map_or(Value::Null, Value::from)
    } else {
        pick(v.pointer("/content_ratings/results").and_then(Value::as_array), "rating").map_or(Value::Null, Value::from)
    }
}

pub async fn details(kind: &str, id: i64) -> Result<Value> {
    let append = if kind == "movie" {
        "images,external_ids,credits,release_dates,recommendations,alternative_titles"
    } else {
        "images,external_ids,credits,content_ratings,recommendations,alternative_titles"
    };
    let v = get(
        &format!("/{}/{id}", path_kind(kind)),
        &[("append_to_response", append.into()), ("include_image_language", "en,null".into())],
        TTL_DETAILS,
    )
    .await?;
    let mut out = item(kind, &v);
    let o = out.as_object_mut().unwrap();
    o.insert("logo".into(), pick_logo(v.get("images").unwrap_or(&Value::Null)));
    o.insert("backdrop".into(), pick_backdrop(&v));
    o.insert("imdb".into(), v.pointer("/external_ids/imdb_id").cloned().unwrap_or(Value::Null));
    o.insert("certification".into(), certification(kind, &v));
    o.insert("tagline".into(), v.get("tagline").cloned().unwrap_or(Value::Null));
    // every name a release could carry: the title, the original, the alternatives (for matching files)
    let mut titles: Vec<Value> = ["title", "name", "original_title", "original_name"].iter().filter_map(|k| v.get(*k).cloned()).collect();
    let alt = v.pointer("/alternative_titles/titles").or(v.pointer("/alternative_titles/results"));
    titles.extend(alt.and_then(Value::as_array).into_iter().flatten().filter_map(|t| t.get("title").cloned()));
    titles.dedup();
    o.insert("titles".into(), Value::Array(titles));
    let cast: Vec<Value> = v
        .pointer("/credits/cast")
        .and_then(Value::as_array)
        .map(|c| {
            c.iter()
                .take(15)
                .map(|p| {
                    json!({
                        "name": p.get("name"),
                        "role": p.get("character"),
                        "photo": img(p.get("profile_path").and_then(Value::as_str), "w185"),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    o.insert("cast".into(), Value::Array(cast));
    o.insert("more".into(), results(kind, v.get("recommendations").unwrap_or(&Value::Null)));
    if kind == "movie" {
        o.insert("runtime".into(), v.get("runtime").cloned().unwrap_or(Value::Null));
    } else {
        let runtime = v
            .get("episode_run_time")
            .and_then(Value::as_array)
            .and_then(|r| r.first())
            .cloned()
            .or_else(|| v.pointer("/last_episode_to_air/runtime").cloned())
            .unwrap_or(Value::Null);
        o.insert("runtime".into(), runtime);
        o.insert("network".into(), v.pointer("/networks/0/name").cloned().unwrap_or(Value::Null));
        o.insert("status".into(), v.get("status").cloned().unwrap_or(Value::Null));
        let seasons: Vec<Value> = v
            .get("seasons")
            .and_then(Value::as_array)
            .map(|s| {
                s.iter()
                    .filter(|x| x.get("season_number").and_then(Value::as_i64).unwrap_or(0) > 0)
                    .map(|x| {
                        json!({
                            "number": x.get("season_number"),
                            "name": x.get("name"),
                            "episodes": x.get("episode_count"),
                            "poster": img(x.get("poster_path").and_then(Value::as_str), "w342"),
                            "airDate": x.get("air_date"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        o.insert("seasons".into(), Value::Array(seasons));
        o.insert("nextAir".into(), v.get("next_episode_to_air").map(episode_brief).unwrap_or(Value::Null));
        o.insert("lastAir".into(), v.get("last_episode_to_air").map(episode_brief).unwrap_or(Value::Null));
    }
    Ok(out)
}

fn episode_brief(e: &Value) -> Value {
    if e.is_null() {
        return Value::Null;
    }
    json!({
        "season": e.get("season_number"),
        "episode": e.get("episode_number"),
        "title": e.get("name"),
        "airDate": e.get("air_date"),
    })
}

pub fn episode(show: i64, e: &Value) -> Value {
    json!({
        "kind": "episode",
        "show": show,
        "season": e.get("season_number"),
        "episode": e.get("episode_number"),
        "episodeTitle": e.get("name"),
        "overview": e.get("overview"),
        "still": img(e.get("still_path").and_then(Value::as_str), "w780"),
        "airDate": e.get("air_date"),
        "runtime": e.get("runtime"),
        "rating": e.get("vote_average"),
    })
}

pub async fn season(show: i64, number: i64) -> Result<Value> {
    let v = get(&format!("/tv/{show}/season/{number}"), &[], TTL_SEASON).await?;
    let eps: Vec<Value> = v
        .get("episodes")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(|e| episode(show, e)).collect())
        .unwrap_or_default();
    Ok(json!({ "number": number, "name": v.get("name"), "episodes": eps }))
}

pub async fn episode_details(show: i64, s: i64, e: i64) -> Result<Value> {
    let v = get(
        &format!("/tv/{show}/season/{s}/episode/{e}"),
        &[("append_to_response", "external_ids".into())],
        TTL_SEASON,
    )
    .await?;
    let mut ep = episode(show, &v);
    ep.as_object_mut()
        .unwrap()
        .insert("imdb".into(), v.pointer("/external_ids/imdb_id").cloned().unwrap_or(Value::Null));
    Ok(ep)
}

/// tmdb id for an imdb id (trakt usually has both, this is the fallback)
pub async fn find_imdb(imdb: &str) -> Result<Option<(String, i64)>> {
    let v = get(&format!("/find/{imdb}"), &[("external_source", "imdb_id".into())], TTL_DETAILS).await?;
    for (field, kind) in [("movie_results", "movie"), ("tv_results", "show")] {
        if let Some(id) = v.get(field).and_then(|a| a.get(0)).and_then(|r| r.get("id")).and_then(Value::as_i64) {
            return Ok(Some((kind.into(), id)));
        }
    }
    Ok(None)
}

/// light art lookup for cards built from trakt data
pub async fn art(kind: &str, id: i64) -> Result<Map<String, Value>> {
    let v = get(&format!("/{}/{id}", path_kind(kind)), &[], TTL_DETAILS).await?;
    Ok(item(kind, &v).as_object().cloned().unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_list_items() {
        let raw = json!({"id": 1399, "name": "Game of Thrones", "first_air_date": "2011-04-17",
            "poster_path": "/p.jpg", "backdrop_path": "/b.jpg", "vote_average": 8.456, "genre_ids": [18, 10765]});
        let it = item("show", &raw);
        assert_eq!(it["title"], "Game of Thrones");
        assert_eq!(it["year"], 2011);
        assert_eq!(it["rating"], 8.5);
        assert_eq!(it["genres"][1], "Sci-Fi & Fantasy");
        assert_eq!(it["poster"], "https://image.tmdb.org/t/p/w500/p.jpg");
    }

    #[test]
    fn logo_and_backdrop_choice() {
        let images = json!({ "logos": [
            { "iso_639_1": "fr", "vote_average": 9.0, "file_path": "/fr.png" },
            { "iso_639_1": "en", "vote_average": 5.2, "file_path": "/en-low.png" },
            { "iso_639_1": "en", "vote_average": 5.6, "file_path": "/en.svg" },
        ] });
        // best english logo, svg asked for as png
        assert_eq!(pick_logo(&images), "https://image.tmdb.org/t/p/w500/en.png");
        // no english one: the first
        assert_eq!(pick_logo(&json!({ "logos": [{ "iso_639_1": "de", "file_path": "/de.png" }] })), "https://image.tmdb.org/t/p/w500/de.png");
        assert!(pick_logo(&json!({})).is_null());

        let v = json!({ "backdrop_path": "/text.jpg", "images": { "backdrops": [
            { "iso_639_1": "en", "file_path": "/en.jpg" }, { "iso_639_1": null, "file_path": "/clean.jpg" } ] } });
        assert_eq!(pick_backdrop(&v), "https://image.tmdb.org/t/p/original/clean.jpg");
        assert_eq!(pick_backdrop(&json!({ "backdrop_path": "/text.jpg" })), "https://image.tmdb.org/t/p/original/text.jpg");
        assert!(img(Some(""), "w500").is_null());
    }
}
