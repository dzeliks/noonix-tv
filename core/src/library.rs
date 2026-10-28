// the library: video files in folders the user picked, matched to tmdb by their names
// ("Show/Season 1/Show.S01E02.mkv", "Movie (2010)/movie.mkv"). each file is the first source of
// its title ("On this PC") and the matched titles fill the library page and a home row. a scan
// runs at launch and from settings; unchanged files keep their match
use crate::store;
use crate::stremio::{self, Stream};
use anyhow::Result;
use once_cell::sync::Lazy;
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

pub const VIDEO: &[&str] = &["mkv", "mp4", "m4v", "avi", "mov", "wmv", "webm", "ts", "m2ts", "mpg", "mpeg", "ogv", "flv"];
/// smaller than this is a sample, a trailer or an extra
const MIN_BYTES: u64 = 20 * 1024 * 1024;
const SKIP_DIRS: &[&str] = &["sample", "samples", "extras", "featurettes", "trailers", "behind the scenes", "deleted scenes", "@eadir", "$recycle.bin"];

static SCANNING: AtomicBool = AtomicBool::new(false);

pub async fn folders() -> Vec<String> {
    store::with(|c| store::get_setting(c, "app", "library_folders"))
        .await
        .ok()
        .flatten()
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default()
}

/// the library counts as a source (on unless turned off)
pub fn on(c: &Connection) -> bool {
    store::get_setting(c, "app", "library").ok().flatten().and_then(|v| v.as_bool()).unwrap_or(true)
}

/// a path from the folder dialog (file:// url or plain)
fn clean(path: &str) -> String {
    let p = match path.strip_prefix("file://") {
        Some(rest) => urlencoding::decode(rest).map(|c| c.into_owned()).unwrap_or_else(|_| rest.to_owned()),
        None => path.to_owned(),
    };
    // windows: file:///C:/...
    let p = if cfg!(windows) && p.starts_with('/') && p.get(2..3) == Some(":") { p[1..].to_owned() } else { p };
    let t = p.trim_end_matches(['/', '\\']);
    if t.is_empty() { p } else { t.to_owned() }
}

pub async fn add_folder(path: &str) -> Result<Value> {
    let p = clean(path);
    anyhow::ensure!(Path::new(&p).is_dir(), "That folder isn't there");
    let mut list = folders().await;
    if !list.contains(&p) {
        list.push(p);
    }
    let v = json!(list);
    store::with(move |c| store::set_setting(c, "app", "library_folders", &v)).await?;
    scan_later();
    Ok(status().await)
}

pub async fn remove_folder(path: &str) -> Result<Value> {
    let p = clean(path);
    let mut list = folders().await;
    list.retain(|f| f != &p);
    let v = json!(list);
    store::with(move |c| store::set_setting(c, "app", "library_folders", &v)).await?;
    scan_later();
    Ok(status().await)
}

pub async fn set_on(on: bool) -> Result<Value> {
    store::with(move |c| {
        store::set_setting(c, "app", "library", &json!(on))?;
        store::cache_drop_prefix(c, "streams:")?;
        Ok(())
    })
    .await?;
    Ok(status().await)
}

pub async fn status() -> Value {
    let folders = folders().await;
    let (files, matched, unmatched, on) = store::with(|c| {
        let files: i64 = c.query_row("select count(*) from library_files", [], |r| r.get(0))?;
        let matched: i64 = c.query_row("select count(*) from library_files where tmdb is not null", [], |r| r.get(0))?;
        let mut st = c.prepare("select path from library_files where tmdb is null order by path limit 5")?;
        let unmatched: Vec<String> = st
            .query_map([], |r| r.get::<_, String>(0))?
            .filter_map(|r| r.ok())
            .map(|p| Path::new(&p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(p))
            .collect();
        Ok((files, matched, unmatched, on(c)))
    })
    .await
    .unwrap_or((0, 0, Vec::new(), true));
    let per: Vec<Value> = {
        let fs = folders.clone();
        let counts = store::with(move |c| {
            let mut out = Vec::new();
            for f in &fs {
                let n: i64 = c.query_row("select count(*) from library_files where path like ?1 || '%'", params![f], |r| r.get(0))?;
                out.push(n);
            }
            Ok(out)
        })
        .await
        .unwrap_or_default();
        folders.iter().zip(counts.iter().chain(std::iter::repeat(&0))).map(|(f, n)| json!({ "path": f, "label": label(f), "files": n })).collect()
    };
    json!({
        "on": on, "folders": per, "files": files, "matched": matched, "unmatched": files - matched,
        "unmatchedNames": unmatched, "scanning": SCANNING.load(Ordering::SeqCst),
    })
}

/// a folder as people read it: the home folder as ~
fn label(path: &str) -> String {
    let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
    match path.strip_prefix(home.trim_end_matches(['/', '\\'])) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with(['/', '\\'])) => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

pub fn scan_later() {
    tokio::spawn(async {
        if let Err(e) = scan().await {
            tracing::warn!("library scan: {e:#}");
        }
    });
}

struct Found {
    path: String,
    size: u64,
    mtime: i64,
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<Found>) {
    if depth > 8 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_lowercase();
        if name.starts_with('.') {
            continue;
        }
        let Ok(ft) = e.file_type() else { continue };
        let path = e.path();
        // a linked folder counts too; the depth limit stops a loop
        if ft.is_dir() || (ft.is_symlink() && path.is_dir()) {
            if !SKIP_DIRS.contains(&name.as_str()) {
                walk(&path, depth + 1, out);
            }
            continue;
        }
        let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !VIDEO.contains(&ext.as_str()) {
            continue;
        }
        let Ok(meta) = e.metadata() else { continue };
        if meta.len() < MIN_BYTES || (name.contains("sample") && meta.len() < 300 * 1024 * 1024) {
            continue;
        }
        let mtime = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs() as i64);
        out.push(Found { path: path.to_string_lossy().into_owned(), size: meta.len(), mtime });
    }
}

/// walks the folders, reads new or changed files and matches them; one scan at a time
pub async fn scan() -> Result<Value> {
    if SCANNING.swap(true, Ordering::SeqCst) {
        return Ok(status().await);
    }
    let r = scan_inner().await;
    SCANNING.store(false, Ordering::SeqCst);
    r?;
    let st = status().await;
    crate::app::emit("library", st.clone());
    Ok(st)
}

async fn scan_inner() -> Result<()> {
    let roots: Vec<PathBuf> = folders().await.into_iter().map(PathBuf::from).collect();
    let found = tokio::task::spawn_blocking(move || {
        let mut out = Vec::new();
        for r in &roots {
            walk(r, 0, &mut out);
        }
        out
    })
    .await?;
    let now = store::now();
    // what's new or changed since the last scan
    let known: std::collections::HashMap<String, (i64, i64)> = store::with(|c| {
        let mut st = c.prepare("select path, size, mtime from library_files")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, (r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    })
    .await?;
    let fresh: Vec<&Found> = found.iter().filter(|f| known.get(&f.path) != Some(&(f.size as i64, f.mtime))).collect();
    let seen: Vec<String> = found.iter().map(|f| f.path.clone()).collect();
    store::with(move |c| {
        let tx = c.unchecked_transaction()?;
        for p in &seen {
            tx.execute("update library_files set seen = ?2 where path = ?1", params![p, now])?;
        }
        tx.execute("delete from library_files where seen < ?1", params![now])?;
        tx.commit()?;
        Ok(())
    })
    .await?;
    let roots: Vec<String> = folders().await;
    let todo: Vec<(String, u64, i64, Guess)> = fresh
        .into_iter()
        .map(|f| {
            let root = roots.iter().find(|r| f.path.starts_with(r.as_str())).cloned().unwrap_or_default();
            let g = guess(Path::new(&f.path), Path::new(&root));
            (f.path.clone(), f.size, f.mtime, g)
        })
        .collect();
    use futures::stream::{self, StreamExt};
    let guessed: Vec<(String, u64, i64, Guess, Option<i64>)> = stream::iter(todo)
        .map(|(path, size, mtime, g)| async move {
            let id = match_title(&g).await;
            (path, size, mtime, g, id)
        })
        .buffer_unordered(4)
        .collect()
        .await;
    store::with(move |c| {
        let tx = c.unchecked_transaction()?;
        for (path, size, mtime, g, id) in &guessed {
            tx.execute(
                "insert or replace into library_files (path, size, mtime, kind, tmdb, season, episode, name, year, seen)
                 values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![path, *size as i64, mtime, g.kind, id, g.season, g.episode, g.name, g.year, now],
            )?;
        }
        store::cache_drop_prefix(&tx, "streams:")?;
        tx.commit()?;
        Ok(())
    })
    .await?;
    Ok(())
}

async fn match_title(g: &Guess) -> Option<i64> {
    if g.name.is_empty() {
        return None;
    }
    let kind = if g.kind == "movie" { "movie" } else { "show" };
    match crate::tmdb::find(kind, &g.name, g.year).await {
        Ok(id) => id,
        Err(e) => {
            tracing::debug!("library match {}: {e:#}", g.name);
            None
        }
    }
}

#[derive(Debug, Default, PartialEq)]
pub struct Guess {
    pub kind: &'static str, // movie | episode
    pub name: String,
    pub year: Option<i64>,
    pub season: Option<i64>,
    pub episode: Option<i64>,
}

static SXE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\bs(\d{1,2})[ ._-]?e(\d{1,3})\b|\b(\d{1,2})x(\d{2,3})\b").unwrap());
static EP_ONLY: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(?:^|[ ._-])(?:e|ep|episode)[ ._-]?(\d{1,3})\b").unwrap());
static SEASON_DIR: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(?:season|series|staffel|sezona|saison|temporada)[ ._-]*(\d{1,2})$|^s(\d{1,2})$").unwrap());
static YEAR: Lazy<Regex> = Lazy::new(|| Regex::new(r"[(\[]?\b(19[2-9]\d|20[0-4]\d)\b[)\]]?").unwrap());
static TAGS: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)\b(2160p|1080p|720p|576p|480p|4k|uhd|web[ .-]?dl|webrip|web|bluray|blu-ray|bdrip|brrip|remux|hdtv|dvdrip|x264|x265|h264|h265|hevc|hdr|proper|repack)\b").unwrap()
});
static BRACKETS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[[^\]]*\]").unwrap());

fn tidy(s: &str) -> String {
    let s = BRACKETS.replace_all(s, " ");
    s.replace(['.', '_'], " ").split_whitespace().collect::<Vec<_>>().join(" ").trim_matches(|c: char| c == '-' || c == ' ' || c == '(').to_owned()
}

/// name and year from the front of a title: "Dune Part Two 2024 2160p" -> ("Dune Part Two", 2024)
fn title_year(raw: &str) -> (String, Option<i64>) {
    let t = tidy(raw);
    let cut_tag = TAGS.find(&t).map(|m| m.start()).unwrap_or(t.len());
    let head = &t[..cut_tag];
    // the last year in it (a title can start with one: "2001 A Space Odyssey 1968")
    let year = YEAR.captures_iter(head).filter(|c| c.get(0).map_or(0, |m| m.start()) > 0).last();
    match year {
        Some(c) => {
            let m = c.get(0).unwrap();
            (tidy(&head[..m.start()]), c[1].parse().ok())
        }
        None => (tidy(head), None),
    }
}

pub fn guess(path: &Path, root: &Path) -> Guess {
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    // the folders between the library folder and the file, nearest first
    let dirs: Vec<String> = path
        .parent()
        .map(|p| p.strip_prefix(root).unwrap_or(p))
        .map(|p| p.components().rev().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    let season_dir = dirs.iter().position(|d| SEASON_DIR.is_match(d.trim()));
    let dir_season = season_dir.and_then(|i| SEASON_DIR.captures(dirs[i].trim())).and_then(|c| c.get(1).or(c.get(2))?.as_str().parse().ok());
    // the show's folder: the one above a season folder, else the nearest
    let show_dir = match season_dir {
        Some(i) => dirs.get(i + 1),
        None => dirs.first(),
    };

    let (season, episode, before) = if let Some(c) = SXE.captures(&stem) {
        let m = c.get(0).unwrap();
        let s = c.get(1).or(c.get(3)).and_then(|x| x.as_str().parse().ok());
        let e = c.get(2).or(c.get(4)).and_then(|x| x.as_str().parse().ok());
        (s, e, stem[..m.start()].to_owned())
    } else if let (Some(s), Some(c)) = (dir_season, EP_ONLY.captures(&stem)) {
        let m = c.get(0).unwrap();
        (Some(s), c[1].parse().ok(), stem[..m.start()].to_owned())
    } else if let Some(s) = dir_season {
        // "Season 1/03 - Pilot.mkv"
        let n = stem.trim_start().split(|c: char| !c.is_ascii_digit()).next().and_then(|d| d.parse::<i64>().ok()).filter(|n| *n > 0 && *n < 300);
        (Some(s), n, String::new())
    } else {
        (None, None, String::new())
    };

    if let (Some(s), Some(e)) = (season, episode) {
        let (mut name, mut year) = title_year(&before);
        if name.is_empty() {
            if let Some(d) = show_dir {
                (name, year) = title_year(d);
            }
        }
        return Guess { kind: "episode", name, year, season: Some(s), episode: Some(e) };
    }
    let (mut name, mut year) = title_year(&stem);
    // "Movie (2010)/movie.mkv", or a file named after the release in a folder named after the movie
    if let Some(d) = dirs.first() {
        let (dn, dy) = title_year(d);
        if !dn.is_empty() && (name.is_empty() || (year.is_none() && dy.is_some())) {
            (name, year) = (dn, dy);
        }
    }
    Guess { kind: "movie", name, year, season: None, episode: None }
}

/// the library's files of one title, as sources
pub fn streams(c: &Connection, kind: &str, tmdb: i64, season: Option<i64>, episode: Option<i64>) -> Result<Vec<Stream>> {
    if !on(c) {
        return Ok(Vec::new());
    }
    let rows: Vec<(String, i64)> = if kind == "movie" {
        let mut st = c.prepare("select path, size from library_files where kind = 'movie' and tmdb = ?1")?;
        let r = st.query_map(params![tmdb], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        r
    } else {
        let mut st = c.prepare("select path, size from library_files where kind = 'episode' and tmdb = ?1 and season = ?2 and episode = ?3")?;
        let r = st.query_map(params![tmdb, season, episode], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;
        r
    };
    Ok(rows
        .into_iter()
        .filter(|(p, _)| Path::new(p).is_file())
        .map(|(path, size)| {
            let name = Path::new(&path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let mut s = stremio::parse_release(&stremio::fold(&name));
            if s.resolution == 0 {
                s.resolution = crate::probe::size(Path::new(&path)).map_or(0, |(w, h)| crate::probe::resolution(w, h));
            }
            s.addon = "This PC".into();
            s.title = name.clone();
            s.filename = Some(name);
            s.size = Some(size as u64);
            s.url = Some(path);
            s.local = true;
            s.exact = true;
            s
        })
        .collect())
}

/// the matched titles, newest file first: {kind, id} for the library page and the home row
pub async fn items(kind: Option<&'static str>) -> Result<Vec<Value>> {
    store::with(move |c| {
        if !on(c) {
            return Ok(Vec::new());
        }
        let mut st = c.prepare(
            "select case kind when 'movie' then 'movie' else 'show' end k, tmdb, max(mtime) m from library_files
             where tmdb is not null group by k, tmdb order by m desc",
        )?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        Ok(rows
            .filter_map(|r| r.ok())
            .filter(|(k, _)| kind.is_none_or(|w| w == k))
            .map(|(k, id)| json!({ "kind": k, "id": id, "onThisPc": true }))
            .collect())
    })
    .await
}

/// a title has files here (details shows it)
pub fn has(c: &Connection, kind: &str, tmdb: i64) -> bool {
    let k = if kind == "movie" { "movie" } else { "episode" };
    on(c) && c.query_row("select 1 from library_files where kind = ?1 and tmdb = ?2 limit 1", params![k, tmdb], |_| Ok(())).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(p: &str) -> Guess {
        guess(Path::new(&format!("/lib/{p}")), Path::new("/lib"))
    }

    #[test]
    fn reads_names() {
        assert_eq!(g("Sintel.2010.1080p.mkv"), Guess { kind: "movie", name: "Sintel".into(), year: Some(2010), ..Default::default() });
        assert_eq!(g("Big Buck Bunny (2008)/bbb_sunflower_1080p_60fps_normal.mp4"), Guess { kind: "movie", name: "Big Buck Bunny".into(), year: Some(2008), ..Default::default() });
        assert_eq!(g("Tears of Steel.mkv").name, "Tears of Steel");
        assert_eq!(
            g("Shows/The Office/Season 2/The.Office.US.S02E03.720p.mkv"),
            Guess { kind: "episode", name: "The Office US".into(), year: None, season: Some(2), episode: Some(3) }
        );
        assert_eq!(g("Some Show (2019)/Season 01/03 - Pilot.mkv"), Guess { kind: "episode", name: "Some Show".into(), year: Some(2019), season: Some(1), episode: Some(3) });
        assert_eq!(g("Some Show/S02/Episode 4.mkv"), Guess { kind: "episode", name: "Some Show".into(), year: None, season: Some(2), episode: Some(4) });
        assert_eq!(g("show/1x05.mkv"), Guess { kind: "episode", name: "show".into(), year: None, season: Some(1), episode: Some(5) });
        assert_eq!(g("2001 A Space Odyssey 1968.mkv"), Guess { kind: "movie", name: "2001 A Space Odyssey".into(), year: Some(1968), ..Default::default() });
    }

    #[test]
    fn cleans_dialog_paths() {
        if !cfg!(windows) {
            assert_eq!(clean("file:///home/me/My%20Videos/"), "/home/me/My Videos");
            assert_eq!(clean("/srv/media"), "/srv/media");
        }
    }
}
