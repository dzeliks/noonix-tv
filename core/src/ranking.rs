// source ranking: noonix tv's own engine over every addon the user added, plus the library.
// files on this pc come first. each addon's own order is the base and the answers are merged
// fairly (first of each, then the second of each...); noonix tv moves a stream down for what it
// knows better: not cached, dolby vision only where the player can't reshape it, no audio in the
// profile's languages, no embedded subtitles in them, then below 4k. above the install's quality
// level goes to the bottom with a warning (it may stutter here, it still plays); on a screen that
// shows no hdr, hdr gives up a few places to sdr (the player tone maps it, so a clearly better hdr
// release stays ahead). the user's preferred release patterns lift a stream within its tier, their
// excluded ones hide it. a remembered binge group goes first, like stremio's autoplay. balkan mode
// lifts releases with serbian / croatian / bosnian, and external subtitles made for the release
// lift it a bit. the viewers' word beats all that: a file they liked first, then the show's liked
// groups; a reported file goes last. torrents only show once the user allowed them
use crate::store::SourceMemory;
use crate::stremio::Stream;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;
use std::sync::Mutex;

/// what the screen shows, as the ui reports it (display.caps): hdr (None = unknown) and dolby
/// vision reshaping (mpv's gpu-next does it, vo_gpu shows profile 5 green and purple)
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Display {
    pub hdr: Option<bool>,
    pub dv: bool,
}

static DISPLAY: Mutex<Display> = Mutex::new(Display { hdr: None, dv: false });

pub fn display() -> Display {
    *DISPLAY.lock().unwrap()
}

/// the screen as the ranking takes it: the settings' "hdr_screen" (on / off) over what was found
pub fn screen(over: Option<&str>) -> Display {
    let mut d = display();
    match over {
        Some("on") => d.hdr = Some(true),
        Some("off") => d.hdr = Some(false),
        _ => {}
    }
    d
}

pub fn set_display(d: Display) {
    let mut g = DISPLAY.lock().unwrap();
    if *g != d {
        tracing::info!("display: hdr {:?}, dolby vision {}", d.hdr, d.dv);
        *g = d;
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Prefs {
    /// audio languages in order of preference: codes, "original" or "balkan"
    pub languages: Vec<String>,
    /// subtitle languages, same vocabulary
    pub subtitles: Vec<String>,
    pub max_gb: f64,
    pub show_uncached: bool,
    /// dv-only releases sink where the player can't reshape them, unless this says otherwise
    pub dv_only_ok: bool,
    /// the install's picture quality level (quality.rs), not the profile's
    pub quality: String,
    /// torrent sources allowed (install-wide): None = not asked yet, they stay hidden
    #[serde(skip)]
    pub torrents: Option<bool>,
    /// release patterns (install-wide: the user's, then the extensions'): preferred lift, excluded hide
    #[serde(skip)]
    pub preferred: Vec<String>,
    #[serde(skip)]
    pub excluded: Vec<String>,
    /// the screen, not saved with the profile
    #[serde(skip)]
    pub display: Display,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs { languages: vec!["en".into(), "original".into()], subtitles: vec!["en".into()], max_gb: 80.0, show_uncached: true, dv_only_ok: false, quality: String::new(), torrents: None, preferred: Vec::new(), excluded: Vec::new(), display: Display::default() }
    }
}

/// sr, bs and hr are one language for the house: any of them is a match, in this order
pub const BALKAN: &[&str] = &["sr", "bs", "hr"];

/// each preference as the set of codes that satisfy it ("original" needs the title's language)
pub fn expand(prefs: &[String], original: Option<&str>) -> Vec<Vec<String>> {
    let mut out: Vec<Vec<String>> = Vec::new();
    for p in prefs {
        let set: Vec<String> = match p.as_str() {
            "original" => match original {
                Some(o) if BALKAN.contains(&o) => BALKAN.iter().map(|c| c.to_string()).collect(),
                Some(o) => vec![o.to_owned()],
                None => continue,
            },
            "balkan" => BALKAN.iter().map(|c| c.to_string()).collect(),
            code => vec![code.to_owned()],
        };
        if !out.contains(&set) {
            out.push(set);
        }
    }
    out
}

/// the order the language pickers show: the common choices first, then everything else.
/// "balkan" only exists while balkan mode is on
pub fn language_options(subtitles: bool, balkan: bool) -> Value {
    let mut top: Vec<(&str, &str)> = vec![("en", "English")];
    if !subtitles {
        top.push(("original", "Original language"));
    }
    if balkan {
        top.extend([("balkan", "Balkan (Serbian, Bosnian, Croatian)"), ("sr", "Serbian"), ("bs", "Bosnian"), ("hr", "Croatian")]);
    }
    let mut rest: Vec<(&str, &str)> = crate::stremio::LANGUAGE_NAMES.iter().copied().filter(|(c, _)| !top.iter().any(|(t, _)| t == c)).collect();
    rest.sort_by(|a, b| a.1.cmp(b.1));
    let all: Vec<Value> = top.iter().chain(rest.iter()).map(|(c, n)| serde_json::json!({ "code": c, "name": n, "top": top.iter().any(|(t, _)| t == c) })).collect();
    Value::Array(all)
}

/// mpv --alang / --slang list (3-letter tags first, releases use both)
pub fn mpv_langs(prefs: &[String], original: Option<&str>) -> String {
    let mut out: Vec<String> = Vec::new();
    for set in expand(prefs, original) {
        for code in set {
            for tag in crate::stremio::iso639_tags(&code) {
                if !out.contains(&tag) {
                    out.push(tag);
                }
            }
        }
    }
    out.join(",")
}

/// a release pattern as the user writes it: words (case doesn't matter, whole words only) or
/// /a regex/. a broken regex matches nothing
pub fn pattern(p: &str) -> Option<Regex> {
    static SEEN: Lazy<Mutex<std::collections::HashMap<String, Option<Regex>>>> = Lazy::new(Default::default);
    let p = p.trim();
    if p.is_empty() {
        return None;
    }
    let mut seen = SEEN.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(r) = seen.get(p) {
        return r.clone();
    }
    let re = match p.strip_prefix('/').and_then(|r| r.strip_suffix('/')) {
        Some(r) if !r.is_empty() => format!("(?i){r}"),
        _ => format!(r"(?i)(^|[^\p{{L}}\p{{N}}]){}([^\p{{L}}\p{{N}}]|$)", regex::escape(p).replace(' ', r"[ ._\-]+")),
    };
    let r = regex::RegexBuilder::new(&re).size_limit(1 << 20).build().ok();
    seen.insert(p.to_owned(), r.clone());
    r
}

fn release_text(s: &Stream) -> String {
    format!("{}\n{}", s.filename.as_deref().unwrap_or(""), s.title)
}

/// a torrent: the app has to fetch it from other people itself
pub fn is_torrent(s: &Stream) -> bool {
    s.url.is_none() && s.info_hash.is_some()
}

pub const TORRENTS_OFF: &str = "torrents are off";

pub fn excluded(s: &Stream, prefs: &Prefs, runtime_min: Option<f64>) -> Option<&'static str> {
    if s.local {
        return None;
    }
    let text = format!("{} {}", s.title, s.filename.as_deref().unwrap_or("")).to_lowercase();
    if is_torrent(s) && prefs.torrents != Some(true) {
        return Some(TORRENTS_OFF);
    }
    if s.source.as_deref() == Some("CAM") {
        return Some("cam");
    }
    if text.split(|c: char| !c.is_alphanumeric()).any(|w| matches!(w, "3d" | "sbs" | "hsbs" | "hou")) {
        return Some("3d");
    }
    if let Some(f) = s.filename.as_deref().map(str::to_lowercase) {
        // disc images and loose bluray/dvd parts don't play as one title
        let stem = f.rsplit('/').next().unwrap_or(&f);
        let disc_part = stem.split('.').next().is_some_and(|n| n.len() >= 4 && n.bytes().all(|b| b.is_ascii_digit()));
        if [".iso", ".rar", ".zip", ".vob", ".img"].iter().any(|e| stem.ends_with(e)) || (disc_part && (stem.ends_with(".m2ts") || stem.ends_with(".mpls"))) {
            return Some("disc files");
        }
    }
    if s.resolution > 0 && s.resolution <= 480 {
        return Some("low resolution");
    }
    if let Some(size) = s.size {
        let gb = size as f64 / 1e9;
        if gb > prefs.max_gb {
            return Some("too big");
        }
        // under ~0.6 mbit/s for hd is a fake or a broken encode
        let mins = runtime_min.unwrap_or(if s.resolution >= 2160 { 90.0 } else { 40.0 });
        let mbps = size as f64 * 8.0 / (mins * 60.0) / 1e6;
        if s.resolution >= 720 && mbps < 0.6 {
            return Some("suspiciously small");
        }
    }
    if s.cached == Some(false) && !prefs.show_uncached {
        return Some("not cached");
    }
    if !prefs.excluded.is_empty() {
        let t = release_text(s);
        if prefs.excluded.iter().filter_map(|p| pattern(p)).any(|re| re.is_match(&t)) {
            return Some("excluded pattern");
        }
    }
    None
}

/// what the release should be: the title's names (tmdb title, original, alternatives) and year,
/// and what the viewers said about its releases
#[derive(Debug, Default, Clone)]
pub struct Wanted {
    pub titles: Vec<String>,
    pub year: Option<i64>,
    pub learned: crate::matches::Learned,
}

fn words(t: &str) -> Vec<String> {
    t.to_lowercase()
        .replace('&', " and ")
        .replace(['\'', '’'], "")
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect()
}

static EPISODE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\b(s\d{1,2}\s?e\d{1,4}|s\d{1,2}\b|\d{1,2}x\d{2,3}|season\s?\d|complete)").unwrap());
static YEAR: Lazy<Regex> = Lazy::new(|| Regex::new(r"\b(19[2-9]\d|20[0-4]\d)\b").unwrap());
static QUALITY: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\b(2160p|1080p|720p|480p|4k|uhd|web-?dl|webrip|bluray|remux|hdtv)\b").unwrap());
static SITE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^\s*(\[[^\]]*\]|www\.\S+\s*-?)\s*").unwrap());

/// the release's own name and year, read from the front of the file name: "Friends S01E01 ..." ->
/// (["friends"], None), "Dune.Part.Two.2024.2160p" -> (["dune", "part", "two"], Some(2024))
fn release_title(s: &Stream) -> Option<(Vec<String>, Option<i64>)> {
    let raw = s.filename.as_deref().unwrap_or_else(|| s.title.lines().next().unwrap_or(""));
    let name = raw.rsplit('/').next().unwrap_or(raw).replace(['.', '_'], " ");
    let name = SITE.replace(&name, "");
    let cut = [EPISODE.find(&name), QUALITY.find(&name)].into_iter().flatten().map(|m| m.start()).min()?;
    let mut head = name[..cut].to_owned();
    // a year right before the cut belongs to the release, not the title ("Dune Part Two 2024")
    let mut year = None;
    if let Some(m) = YEAR.find_iter(&head).last() {
        if m.start() > 0 && head[m.end()..].trim().trim_matches(|c: char| !c.is_alphanumeric()).is_empty() {
            year = m.as_str().parse().ok();
            head.truncate(m.start());
        }
    }
    let mut w = words(&head);
    // country tags after a show's name: "Euphoria US", "The Office UK"
    while w.len() > 1 && matches!(w.last().map(String::as_str), Some("us" | "uk" | "au" | "nz" | "ca")) {
        w.pop();
    }
    (!w.is_empty()).then_some((w, year))
}

/// true when the file is clearly another title (other name, or a year more than one off)
fn off_title(s: &Stream, want: &Wanted) -> bool {
    let Some((w, year)) = release_title(s) else { return false };
    let named = want.titles.iter().any(|t| {
        let t = words(t);
        let strip = |v: &[String]| v.iter().filter(|x| !matches!(x.as_str(), "the" | "a" | "an")).cloned().collect::<Vec<_>>();
        !t.is_empty() && strip(&t) == strip(&w)
    });
    let year_off = matches!((year, want.year), (Some(a), Some(b)) if (a - b).abs() > 1);
    !named || year_off
}

/// places an hdr release gives up in its addon's order on an sdr screen
const HDR_ON_SDR: usize = 3;

fn is_dv_only(s: &Stream) -> bool {
    s.hdr.iter().any(|h| h == "DV") && !s.hdr.iter().any(|h| h.starts_with("HDR") || h == "HLG")
}

/// how well the embedded subtitles cover the wanted sets: 2 per set the release lists, 1 for a
/// multi release that lists none (multi audio nearly always carries many subtitles)
fn subs_cover(s: &Stream, subs: &[Vec<String>]) -> usize {
    let listed = subs.iter().filter(|set| s.subtitles.iter().any(|l| set.contains(l))).count();
    if listed > 0 {
        return listed * 2;
    }
    usize::from(s.subtitles.iter().chain(s.languages.iter()).any(|l| l == "multi"))
}

fn subs_hit(s: &Stream, subs: &[Vec<String>]) -> bool {
    subs_cover(s, subs) > 0
}

/// lower is better; a demotion never outweighs a bigger one. subs = the wanted subtitle sets,
/// empty when no release tells its subtitles (then nothing sinks for them). above the quality
/// level still beats not cached: it plays, maybe with a stutter
pub fn tier(s: &Stream, prefs: &Prefs, langs: &[Vec<String>], subs: &[Vec<String>], memory: Option<&SourceMemory>, runtime_min: Option<f64>) -> i64 {
    // the user's own file plays from the disk: nothing beats it
    if s.local {
        return -8;
    }
    let mut t = 0;
    // more than this pc or this connection may manage: at the bottom, still there
    if over_level(s, prefs, runtime_min) {
        t += 64;
    }
    if s.cached == Some(false) {
        t += 32;
    }
    // a torrent needs people sharing it: few for its resolution stutters
    if few_seeders(s) {
        t += 16;
    }
    if is_dv_only(s) && !prefs.dv_only_ok && !prefs.display.dv {
        t += 8;
    }
    // unknown languages are fine, "multi" is fine
    let lang_miss = !s.languages.is_empty()
        && !langs.is_empty()
        && !s.languages.iter().any(|l| l == "multi" || langs.iter().any(|set| set.contains(l)));
    if lang_miss {
        t += 4;
    }
    if !subs.is_empty() && !subs_hit(s, subs) {
        t += 2;
    }
    if s.resolution < 2160 {
        t += 1;
    }
    let binge = memory.and_then(|m| m.binge_group.as_ref()).is_some_and(|b| s.binge_group.as_ref() == Some(b));
    if binge && t & (64 | 32 | 16 | 8 | 4) == 0 {
        t = -1;
    }
    t
}

fn over_level(s: &Stream, prefs: &Prefs, runtime_min: Option<f64>) -> bool {
    !s.local && !prefs.quality.is_empty() && crate::quality::over(s, crate::quality::level(&prefs.quality), runtime_min)
}

fn few_seeders(s: &Stream) -> bool {
    is_torrent(s) && s.seeders.is_some_and(|n| n < 10 || (s.resolution >= 2160 && n < 30))
}

/// how clean the copy is, coarse on purpose (the addon's order decides inside): an encode from
/// a screen recording or a tv broadcast, or a dvd, after the rest. unknown counts as good
fn class(s: &Stream) -> u8 {
    match s.source.as_deref() {
        Some("WEBRip" | "HDTV") => 1,
        Some("DVD") => 2,
        _ => 0,
    }
}

fn dedupe_key(s: &Stream) -> String {
    if let Some(h) = &s.info_hash {
        return format!("h:{}:{}", h.to_lowercase(), s.file_idx.unwrap_or(-1));
    }
    if let (Some(f), Some(size)) = (&s.filename, s.size) {
        // the same file reached through two scrapers
        return format!("f:{}:{}", f.to_lowercase(), size / 1_000_000);
    }
    format!("u:{}", s.url.as_deref().unwrap_or(""))
}

#[derive(Debug, Default, Serialize)]
pub struct Ranked {
    pub streams: Vec<Stream>,
    pub hidden: usize,
    /// torrents left out because they aren't allowed (yet)
    pub torrents: usize,
}

pub fn rank(
    mut list: Vec<Stream>,
    prefs: &Prefs,
    original: Option<&str>,
    memory: Option<&SourceMemory>,
    runtime_min: Option<f64>,
    want: &Wanted,
) -> Ranked {
    let langs = expand(&prefs.languages, original);
    let before = list.len();
    let torrents = list.iter().filter(|s| excluded(s, prefs, runtime_min) == Some(TORRENTS_OFF)).count();
    list.retain(|s| excluded(s, prefs, runtime_min).is_none());
    let hidden = before - list.len();
    let preferred: Vec<Regex> = prefs.preferred.iter().filter_map(|p| pattern(p)).collect();
    for s in list.iter_mut() {
        s.warn = if over_level(s, prefs, runtime_min) {
            Some("level".into())
        } else if few_seeders(s) {
            Some("seeders".into())
        } else {
            None
        };
        let t = release_text(s);
        s.preferred = preferred.iter().any(|re| re.is_match(&t));
    }
    // the first pattern that matches counts most
    let liked = |s: &Stream| {
        if !s.preferred {
            return preferred.len();
        }
        let t = release_text(s);
        preferred.iter().position(|re| re.is_match(&t)).unwrap_or(preferred.len())
    };
    // releases of another title (same words in a longer name, a remake's year) go last. only
    // when something does match: foreign release names must never sink everything
    let off: HashSet<String> = if want.titles.is_empty() {
        HashSet::new()
    } else {
        let off: HashSet<String> = list.iter().filter(|s| off_title(s, want)).map(dedupe_key).collect();
        if off.len() == list.len() { HashSet::new() } else { off }
    };
    // balkan mode: releases that carry serbian / croatian / bosnian go first within their tier
    let balkan = prefs.subtitles.iter().chain(prefs.languages.iter()).any(|l| l == "balkan" || BALKAN.contains(&l.as_str()));
    let no_balkan = |s: &Stream| balkan && !s.languages.iter().any(|l| BALKAN.contains(&l.as_str()));
    let mut subs = expand(&prefs.subtitles, original);
    if !list.iter().any(|s| subs_hit(s, &subs)) {
        subs.clear();
    }
    let ext = |s: &Stream| std::cmp::Reverse((s.ext_subs.0, s.ext_subs.1.min(3)));
    let cover = |s: &Stream| std::cmp::Reverse(subs_cover(s, &subs));
    let l = &want.learned;
    let judged = |s: &Stream| {
        let t = tier(s, prefs, &langs, &subs, memory, runtime_min);
        let file = crate::matches::file_key(s);
        if s.local {
            t
        } else if l.good_files.contains(&file) && s.cached != Some(false) {
            -3
        } else if s.group.as_ref().is_some_and(|g| l.good_groups.contains(&g.to_lowercase())) && t & (64 | 32 | 16 | 8 | 4) == 0 {
            -2
        } else {
            t
        }
    };
    let bad = |s: &Stream| l.bad_files.contains(&crate::matches::file_key(s));
    // a screen without hdr: the player tone maps it, so hdr only gives up a few places in the
    // addon's order (everything above still counts first, a much better hdr release stays ahead)
    let sdr_screen = prefs.display.hdr == Some(false);
    // the addons' answers merged fairly: everyone's first, then everyone's second...
    let order = |s: &Stream| (s.order.1 + if sdr_screen && !s.hdr.is_empty() { HDR_ON_SDR } else { 0 }, s.order.0);
    // torrents: the well shared copies first within the same tier
    let swarm = |s: &Stream| match (is_torrent(s), s.seeders) {
        (true, Some(n)) if n >= 100 => 0,
        (true, Some(n)) if n >= 30 => 1,
        (true, Some(n)) if n >= 10 => 2,
        (true, _) => 3,
        _ => 0,
    };
    list.sort_by_cached_key(|s| (off.contains(&dedupe_key(s)), bad(s), judged(s), liked(s), no_balkan(s), cover(s), ext(s), swarm(s), class(s), order(s)));
    let mut seen = HashSet::new();
    list.retain(|s| seen.insert(dedupe_key(s)));
    let n = list.len() as i64;
    for (i, s) in list.iter_mut().enumerate() {
        s.score = n - i as i64;
        s.off_title = off.contains(&dedupe_key(s));
    }
    Ranked { streams: list, hidden, torrents }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stremio::parse_release;

    fn st(name: &str, cached: Option<bool>, gb: f64) -> Stream {
        let mut s = parse_release(name);
        s.filename = Some(name.into());
        s.title = name.into();
        s.cached = cached;
        s.size = Some((gb * 1e9) as u64);
        s.url = Some(format!("https://x.invalid/{name}"));
        s
    }

    // as one addon answered them
    fn answer(mut list: Vec<Stream>) -> Vec<Stream> {
        for (i, s) in list.iter_mut().enumerate() {
            s.order = (0, i);
        }
        list
    }

    fn groups(r: &Ranked) -> Vec<String> {
        r.streams.iter().map(|s| s.group.clone().unwrap_or_default()).collect()
    }

    fn named(f: &str) -> Stream {
        let mut s = st(f, Some(true), 2.0);
        s.filename = Some(f.into());
        s
    }

    #[test]
    fn other_titles_go_last() {
        let want = Wanted { titles: vec!["Friends".into()], year: Some(1994), ..Default::default() };
        assert!(off_title(&named("Your Friends and Neighbors S01E01 This Is What Happens 2160p WEB-DL.mkv"), &want));
        assert!(off_title(&named("Friends from College S01E01 Welcome to New York 1080p WEB-DL.mkv"), &want));
        assert!(off_title(&named("The.Recruit.S01E01.1080p.WEB-DL.mkv"), &want));
        assert!(!off_title(&named("Friends S01E01 1080p WEB-DL DDP2.0 H.264-GRP.mkv"), &want));
        assert!(!off_title(&named("Friends.1994.S01E01.1080p.BluRay.mkv"), &want));
        assert!(off_title(&named("Friends.2024.S01E01.1080p.WEB-DL.mkv"), &want));
        let eu = Wanted { titles: vec!["Euphoria".into()], year: Some(2019), ..Default::default() };
        assert!(!off_title(&named("Euphoria.US.S03E04.Kitty.Likes.to.Dance.2160p.WEB-DL.mkv"), &eu));
        let dune = Wanted { titles: vec!["Dune: Part Two".into()], year: Some(2024), ..Default::default() };
        assert!(!off_title(&named("Dune.Part.Two.2024.2160p.UHD.BluRay.mkv"), &dune));
        assert!(off_title(&named("Dune.1984.2160p.UHD.BluRay.mkv"), &dune));
        let greys = Wanted { titles: vec!["Grey's Anatomy".into()], year: Some(2005), ..Default::default() };
        assert!(!off_title(&named("Greys.Anatomy.S21E01.1080p.WEB.h264.mkv"), &greys));
        // nothing to read: no verdict
        assert!(!off_title(&named("video.mkv"), &want));
    }

    #[test]
    fn embedded_subs_beat_resolution() {
        let p = Prefs { subtitles: vec!["en".into(), "balkan".into()], ..Prefs::default() };
        let uhd = st("Show.S01E01.2160p.WEB-DL.H.265-UHD", Some(true), 6.0);
        let multi = st("Show.S01E01.MULTi.1080p.WEB-DL.H.264-MUL", Some(true), 3.0);
        let esub = st("Show.S01E01.1080p.WEB-DL.H.264.ESub-ESB", Some(true), 3.0);
        let plain = st("Show.S01E01.1080p.WEB-DL.H.264-PLN", Some(true), 3.0);
        let r = rank(answer(vec![uhd.clone(), plain.clone(), esub.clone(), multi.clone()]), &p, Some("en"), None, None, &Wanted::default());
        assert_eq!(groups(&r), ["ESB", "MUL", "UHD", "PLN"]);
        // within a tier, more of the wanted languages first
        let mut both = st("Show.S01E01.2160p.WEB-DL.H.265-BTH", Some(true), 6.0);
        both.subtitles = vec!["en".into(), "sr".into()];
        let mut en = st("Show.S01E01.2160p.WEB-DL.H.265-ENG", Some(true), 6.0);
        en.subtitles = vec!["en".into()];
        assert_eq!(groups(&rank(answer(vec![en, both, uhd.clone()]), &p, Some("en"), None, None, &Wanted::default())), ["BTH", "ENG", "UHD"]);
        // nobody tells their subtitles: 4k first as before
        let r = rank(answer(vec![plain.clone(), uhd.clone()]), &p, Some("en"), None, None, &Wanted::default());
        assert_eq!(groups(&r), ["UHD", "PLN"]);
        // subtitles made for the release lift it within its tier
        let mut fitted = st("Show.S01E01.1080p.WEB-DL.H.264-FIT", Some(true), 3.0);
        fitted.ext_subs = (2, 3);
        let r = rank(answer(vec![plain, fitted, uhd]), &p, Some("en"), None, None, &Wanted::default());
        assert_eq!(groups(&r), ["UHD", "FIT", "PLN"]);
    }

    #[test]
    fn foreign_names_never_sink_everything() {
        let want = Wanted { titles: vec!["Attack on Titan".into()], year: Some(2013), ..Default::default() };
        let list = vec![named("Shingeki no Kyojin S01E01 1080p BluRay.mkv")];
        let r = rank(list, &Prefs::default(), None, None, None, &want);
        assert_eq!(r.streams.len(), 1);
    }

    #[test]
    fn addon_order_with_4k_first() {
        let p = Prefs::default();
        let r = rank(
            answer(vec![
                st("Movie.2024.1080p.WEB-DL.DDP5.1.H.264-AA", Some(true), 9.0),
                st("Movie.2024.2160p.WEB-DL.DV.H.265-BB", Some(true), 18.0),
                st("Movie.2024.2160p.WEB-DL.DV.HDR10.DDP5.1.Atmos.H.265-CC", Some(true), 20.0),
                st("Movie.2024.2160p.BluRay.REMUX.HDR10.HEVC.TrueHD.7.1.Atmos-DD", Some(false), 60.0),
                st("Movie.2024.1080p.WEB-DL.DDP5.1.HEVC-EE", Some(true), 5.0),
                st("Movie.2024.HDCAM.x264-FF", Some(true), 1.5),
                st("Movie.2024.720p.WEB.H264-GG", Some(true), 0.1),
                st("Movie.2024.2160p.WEB-DL.H.265-HH", Some(true), 6.0),
            ]),
            &p,
            Some("en"),
            None,
            Some(120.0),
            &Wanted::default(),
        );
        // 4k in the addon's order, then the rest in the addon's order, dv-only and uncached last
        assert_eq!(groups(&r), ["CC", "HH", "AA", "EE", "BB", "DD"]);
        assert_eq!(r.hidden, 2);
    }

    #[test]
    fn screen_decides_hdr() {
        let list = || {
            answer(vec![
                st("Movie.2024.1080p.WEB-DL.DDP5.1.H.264-AA", Some(true), 9.0),
                st("Movie.2024.2160p.WEB-DL.DV.H.265-BB", Some(true), 18.0),
                st("Movie.2024.2160p.WEB-DL.DV.HDR10.DDP5.1.Atmos.H.265-CC", Some(true), 20.0),
                st("Movie.2024.2160p.WEB-DL.H.265-HH", Some(true), 6.0),
            ])
        };
        let rank_on = |d: Display| groups(&rank(list(), &Prefs { display: d, ..Prefs::default() }, Some("en"), None, Some(120.0), &Wanted::default()));
        // gpu-next reshapes dv-only, the addon's order stands
        assert_eq!(rank_on(Display { hdr: Some(true), dv: true }), ["BB", "CC", "HH", "AA"]);
        // an sdr screen: the sdr 4k just behind moves up, dv-only still sinks without reshaping
        assert_eq!(rank_on(Display { hdr: Some(false), dv: false }), ["HH", "CC", "AA", "BB"]);
        // ...but an hdr release the addon puts well ahead stays first
        let rr = st("Movie.2024.2160p.BluRay.REMUX.HDR10.HEVC.TrueHD.7.1.Atmos-RR", Some(true), 60.0);
        let mut ww = st("Movie.2024.2160p.WEB.H.265-WW", Some(true), 4.0);
        ww.order = (0, 5);
        let sdr = Prefs { display: Display { hdr: Some(false), dv: false }, ..Prefs::default() };
        assert_eq!(groups(&rank(vec![rr, ww], &sdr, Some("en"), None, Some(120.0), &Wanted::default())), ["RR", "WW"]);
        // unknown screen: as before
        assert_eq!(rank_on(Display::default()), ["CC", "HH", "AA", "BB"]);
    }

    #[test]
    fn addons_merge_fairly() {
        let p = Prefs::default();
        let mut a = st("Show.S01E02.2160p.WEB-DL.H.265-FIRST", Some(true), 9.0);
        a.order = (1, 0);
        let mut b = st("Show.S01E02.2160p.WEB-DL.H.265-THIRD", Some(true), 4.0);
        b.order = (0, 3);
        let mut c = st("Show.S01E02.2160p.WEB-DL.H.265-SECOND", Some(true), 4.0);
        c.order = (0, 0);
        // each addon's first before anyone's fourth; the registry breaks the tie
        assert_eq!(groups(&rank(vec![a, b, c], &p, None, None, None, &Wanted::default())), ["SECOND", "FIRST", "THIRD"]);
    }

    #[test]
    fn library_first_torrents_asked() {
        let mut p = Prefs::default();
        let mut file = st("Movie.2010.1080p.BluRay.x264-HOME", None, 2.0);
        file.local = true;
        file.order = (9, 9);
        let mut t = st("Movie.2010.2160p.BluRay.x265-SWARM", None, 20.0);
        t.url = None;
        t.info_hash = Some("08ada5a7a6183aae1e09d831df6748d566095a10".into());
        t.seeders = Some(200);
        let web = answer(vec![st("Movie.2010.2160p.WEB-DL.x265-WEB", Some(true), 10.0)]);
        let all: Vec<Stream> = [vec![file.clone(), t.clone()], web.clone()].concat();
        let r = rank(all.clone(), &p, None, None, None, &Wanted::default());
        assert_eq!(groups(&r), ["HOME", "WEB"]);
        assert_eq!(r.torrents, 1);
        p.torrents = Some(true);
        let r = rank(all, &p, None, None, None, &Wanted::default());
        assert_eq!(groups(&r)[0], "HOME");
        assert_eq!(r.torrents, 0);
        assert_eq!(r.streams.len(), 3);
    }

    #[test]
    fn above_the_level_goes_last_with_a_warning() {
        let p = Prefs { quality: "hd".into(), ..Prefs::default() };
        let list = answer(vec![
            st("Movie.2010.2160p.BluRay.REMUX.HEVC-BIG", Some(true), 60.0),
            st("Movie.2010.1080p.WEB-DL.H.264-FIT", Some(false), 4.0),
        ]);
        let r = rank(list, &p, None, None, Some(120.0), &Wanted::default());
        assert_eq!(groups(&r), ["FIT", "BIG"]);
        assert_eq!(r.streams[1].warn.as_deref(), Some("level"));
        assert_eq!(r.streams[0].warn, None);
    }

    #[test]
    fn release_patterns() {
        let mut p = Prefs::default();
        let list = answer(vec![
            st("Movie.2010.2160p.WEB-DL.H.265-AAA", Some(true), 8.0),
            st("Movie.2010.2160p.BluRay.REMUX.HEVC-BBB", Some(true), 50.0),
            st("Movie.2010.2160p.WEB-DL.HC.H.265-CCC", Some(true), 8.0),
        ]);
        p.preferred = vec!["remux".into()];
        p.excluded = vec!["HC".into()];
        let r = rank(list, &p, None, None, None, &Wanted::default());
        assert_eq!(groups(&r), ["BBB", "AAA"]);
        assert_eq!(r.hidden, 1);
        assert!(pattern("/web[ .-]?dl/").unwrap().is_match("x.WEB-DL.y"));
        assert!(pattern("blu ray").unwrap().is_match("Blu.Ray"));
        assert!(!pattern("hc").unwrap().is_match("hchc"));
    }

    #[test]
    fn memory_and_language() {
        let p = Prefs::default();
        let mut a = st("Show.S01E02.2160p.WEB-DL.ITA.H.265-XX", Some(true), 2.0);
        a.languages = vec!["it".into()];
        let mut b = st("Show.S01E02.720p.WEB.H264-YY", Some(true), 1.0);
        b.binge_group = Some("aio|720p|YY".into());
        let c = st("Show.S01E02.1080p.WEB.H264-ZZ", Some(true), 1.2);
        let mem = SourceMemory { binge_group: Some("aio|720p|YY".into()), ..Default::default() };
        let r = rank(answer(vec![a.clone(), b.clone(), c.clone()]), &p, Some("en"), Some(&mem), Some(45.0), &Wanted::default());
        assert_eq!(r.streams[0].group.as_deref(), Some("YY"));
        // italian-only 4k goes below english 1080p
        let r = rank(answer(vec![a, c]), &p, Some("en"), None, Some(45.0), &Wanted::default());
        assert_eq!(groups(&r), ["ZZ", "XX"]);
    }

    #[test]
    fn viewers_word_first() {
        let p = Prefs::default();
        let mut a = named("Show.S01E02.2160p.WEB.H265-AAA.mkv");
        let mut b = named("Show.S01E02.1080p.WEB.H264-BBB.mkv");
        let mut c = named("Show.S01E02.1080p.WEB.H264-CCC.mkv");
        for s in [&mut a, &mut b, &mut c] {
            s.cached = Some(true);
        }
        let mut want = Wanted::default();
        // nothing said: 4k first
        assert_eq!(groups(&rank(answer(vec![a.clone(), b.clone(), c.clone()]), &p, None, None, None, &want)), ["AAA", "BBB", "CCC"]);
        // the show liked BBB on another episode; the 4k file got a picture report here
        want.learned.good_groups.insert("bbb".into());
        want.learned.bad_files.insert(crate::matches::file_key(&a));
        assert_eq!(groups(&rank(answer(vec![a.clone(), b.clone(), c.clone()]), &p, None, None, None, &want)), ["BBB", "CCC", "AAA"]);
        // this very file was liked: before the group
        want.learned.good_files.insert(crate::matches::file_key(&c));
        assert_eq!(groups(&rank(answer(vec![a, b, c]), &p, None, None, None, &want)), ["CCC", "BBB", "AAA"]);
    }

    #[test]
    fn balkan_mode_lifts_within_the_tier() {
        let p = Prefs { subtitles: vec!["en".into(), "balkan".into()], ..Default::default() };
        let a = st("Show.S01E02.2160p.WEB-DL.H.265-AA", Some(true), 9.0);
        let mut b = st("Show.S01E02.2160p.WEB-DL.H.265-BB", Some(true), 9.0);
        b.languages = vec!["en".into(), "hr".into()];
        let mut c = st("Show.S01E02.1080p.WEB-DL.H.264-CC", Some(true), 4.0);
        c.languages = vec!["en".into(), "sr".into()];
        // 4k first, the croatian one leads it; the serbian 1080p stays below every 4k
        assert_eq!(groups(&rank(answer(vec![a.clone(), b.clone(), c.clone()]), &p, Some("en"), None, None, &Wanted::default())), ["BB", "AA", "CC"]);
        // without balkan mode the addon's order stands
        assert_eq!(groups(&rank(answer(vec![a, b, c]), &Prefs::default(), Some("en"), None, None, &Wanted::default())), ["AA", "BB", "CC"]);
    }

    #[test]
    fn dedupes_same_file() {
        let p = Prefs::default();
        let a = st("Movie.2024.1080p.WEB-DL.H.264-AA", Some(true), 9.0);
        let mut b = a.clone();
        b.url = Some("https://other.invalid/x".into());
        assert_eq!(rank(answer(vec![a, b]), &p, None, None, None, &Wanted::default()).streams.len(), 1);
    }

    #[test]
    fn balkan_and_original() {
        let p = Prefs { languages: vec!["balkan".into(), "original".into()], ..Default::default() };
        let mut a = st("Film.2020.1080p.WEB-DL.H.264-AA", Some(true), 4.0);
        a.languages = vec!["de".into()];
        let mut b = st("Film.2020.1080p.WEB-DL.H.264-BB", Some(true), 4.0);
        b.languages = vec!["hr".into()];
        let r = rank(answer(vec![a.clone(), b.clone()]), &p, Some("fr"), None, None, &Wanted::default());
        assert_eq!(r.streams[0].group.as_deref(), Some("BB"));
        assert_eq!(expand(&p.languages, Some("sr")), vec![vec!["sr", "bs", "hr"]]);
        assert_eq!(mpv_langs(&["en".into(), "balkan".into()], None), "eng,en,srp,sr,scc,bos,bs,hrv,hr,scr");
    }

    #[test]
    fn balkan_only_when_on() {
        let codes = |v: serde_json::Value| v.as_array().unwrap().iter().map(|o| o["code"].as_str().unwrap().to_owned()).collect::<Vec<_>>();
        let off = codes(language_options(true, false));
        assert!(!off.contains(&"balkan".to_owned()));
        assert!(off.contains(&"sr".to_owned()), "single languages stay pickable");
        assert_eq!(off[0], "en");
        let on = codes(language_options(true, true));
        assert_eq!(&on[..5], ["en", "balkan", "sr", "bs", "hr"]);
        assert_eq!(codes(language_options(false, false))[1], "original");
        assert!(!codes(language_options(true, false)).contains(&"original".to_owned()));
    }
}
