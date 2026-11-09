// extra subtitles for every subtitle preference the file has no embedded track for: stremio's
// opensubtitles v3 addon (free, no key), or opensubtitles.com first when the user turned it on
// with their own api key (v3 fills what it can't: nothing found, daily quota spent). every
// candidate is scored against the playing release, the best two per preference are fetched
use crate::config::{self, keys, PATHS};
use crate::http::{self, Req};
use crate::matches::SubLearn;
use crate::ranking;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const API: &str = "https://api.opensubtitles.com/api/v1";
/// stremio's own subtitle addon: opensubtitles' catalogue, no key, no per-user quota
pub const V3: &str = "https://opensubtitles-v3.strem.io";
pub const OS_USERNAME: &str = "OPENSUBTITLES_USERNAME";
pub const OS_PASSWORD: &str = "OPENSUBTITLES_PASSWORD";
const PER_LANGUAGE: usize = 2;

/// what we know about the playing file
#[derive(Debug, Clone, Default)]
pub struct Release {
    pub name: String,
    pub group: Option<String>,
    pub resolution: u32,
    pub codec: Option<String>,
    pub fps: f64,
    pub duration: f64,
}

impl Release {
    pub fn of(s: &crate::stremio::Stream) -> Self {
        Release { name: s.filename.clone().unwrap_or_else(|| s.title.clone()), group: s.group.clone(), resolution: s.resolution, codec: s.codec.clone(), fps: 0.0, duration: 0.0 }
    }
}

/// when a subtitle's last line is (h:mm:ss,ms in srt / vtt / ass)
fn last_cue(text: &str) -> f64 {
    static TIME: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{2,3})").unwrap());
    TIME.captures_iter(text)
        .filter_map(|c| {
            let n = |i: usize| c[i].parse::<f64>().ok();
            let frac = n(4)? / if c[4].len() == 2 { 100.0 } else { 1000.0 };
            Some(n(1)? * 3600.0 + n(2)? * 60.0 + n(3)? + frac)
        })
        .fold(0.0, f64::max)
}

/// made for another cut: lines well past the end of this file, or ending far too early
fn wrong_length(path: &str, rel: &Release) -> Option<String> {
    if rel.duration < 600.0 {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    let last = last_cue(&String::from_utf8_lossy(&bytes));
    if last <= 0.0 {
        return None;
    }
    let (end, dur) = (last / 60.0, rel.duration / 60.0);
    if last > rel.duration + 90.0 {
        Some(format!("runs to {end:.0} min, the file is {dur:.0}"))
    } else if last < rel.duration * 0.75 {
        Some(format!("ends at {end:.0} min, the file is {dur:.0}"))
    } else {
        None
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Found {
    pub path: String,
    pub lang: String,
    pub title: String,
    pub score: f64,
    /// ext:<file name>, provider and how to get it again: the match marks' identity
    pub key: String,
    pub provider: String,
    pub src: Value,
    /// liked with this very file before
    pub liked: bool,
}

impl Found {
    pub fn sub(&self) -> crate::matches::Sub {
        crate::matches::Sub { key: self.key.clone(), lang: self.lang.clone(), name: self.title.clone(), provider: self.provider.clone(), src: Some(self.src.clone()) }
    }
}

const CP1250: &str = "€\u{fffd}‚\u{fffd}„…†‡\u{fffd}‰Š‹ŚŤŽŹ\u{fffd}‘’“”•–—\u{fffd}™š›śťžź\u{a0}ˇ˘Ł¤Ą¦§¨©Ş«¬\u{ad}®Ż°±˛ł´µ¶·¸ąş»Ľ˝ľżŔÁÂĂÄĹĆÇČÉĘËĚÍÎĎĐŃŇÓÔŐÖ×ŘŮÚŰÜÝŢßŕáâăäĺćçčéęëěíîďđńňóôőö÷řůúűüýţ˙";
const CP1251: &str = "ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—\u{fffd}™љ›њќћџ\u{a0}ЎўЈ¤Ґ¦§Ё©Є«¬\u{ad}®Ї°±Ііґµ¶·ё№є»јЅѕїАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя";

/// old subtitle files are in a windows code page: mostly latin 1250 here, 1251 when the letters
/// themselves are all high bytes (cyrillic)
fn decode(bytes: &[u8]) -> Option<String> {
    let utf16 = |be: bool| {
        let units = bytes[2..].chunks_exact(2).map(|p| if be { u16::from_be_bytes([p[0], p[1]]) } else { u16::from_le_bytes([p[0], p[1]]) });
        char::decode_utf16(units).map(|c| c.unwrap_or('\u{fffd}')).collect::<String>()
    };
    let text = match bytes {
        [0xff, 0xfe, ..] => utf16(false),
        [0xfe, 0xff, ..] => utf16(true),
        _ => match std::str::from_utf8(bytes) {
            Ok(t) => t.trim_start_matches('\u{feff}').to_owned(),
            Err(_) => {
                let high = bytes.iter().filter(|b| **b >= 0xc0).count();
                let plain = bytes.iter().filter(|b| b.is_ascii_alphabetic()).count();
                let table: Vec<char> = (if high > plain { CP1251 } else { CP1250 }).chars().collect();
                bytes.iter().map(|b| if b.is_ascii() { *b as char } else { table[*b as usize - 0x80] }).collect()
            }
        },
    };
    // a binary .sub, not text
    (!text.contains('\0')).then_some(unmangle(text))
}

/// utf-8 that was read as windows-1252 and saved again ("â™ª" for "♪", "Ä‡" for "ć"): put back.
/// anything that doesn't go back cleanly stays as it was
fn unmangle(text: String) -> String {
    const CP1252: &str = "€\u{81}‚ƒ„…†‡ˆ‰Š‹Œ\u{8d}Ž\u{8f}\u{90}‘’“”•–—˜™š›œ\u{9d}žŸ";
    let looks = text.chars().zip(text.chars().skip(1)).any(|(a, b)| ('\u{c2}'..='\u{f4}').contains(&a) && (('\u{80}'..='\u{bf}').contains(&b) || CP1252.contains(b)));
    if !looks {
        return text;
    }
    let mut bytes = Vec::with_capacity(text.len());
    for c in text.chars() {
        let b = if (c as u32) < 0x80 || ((c as u32) >= 0xa0 && (c as u32) < 0x100) {
            c as u32 as u8
        } else if let Some(i) = CP1252.chars().position(|x| x == c) {
            0x80 + i as u8
        } else {
            // a real character past latin-1: not mangled after all
            return text;
        };
        bytes.push(b);
    }
    String::from_utf8(bytes).unwrap_or(text)
}

/// italics / bold / underline tags typed with spaces (< / i >, < i>), or closing what never
/// opened in that cue: players show those as text
fn tidy(text: &str) -> String {
    static TAG: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"<\s*(/?)\s*([iIbBuU])\s*>").unwrap());
    let nl = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let cue_gap = format!("{nl}{nl}");
    text.split(cue_gap.as_str())
        .map(|cue| {
            let mut open = [0usize; 3];
            TAG.replace_all(cue, |c: &regex::Captures| {
                let t = c[2].to_lowercase();
                let k = "ibu".find(&t).unwrap_or(0);
                if c[1].is_empty() {
                    open[k] += 1;
                } else if open[k] == 0 {
                    return String::new();
                } else {
                    open[k] -= 1;
                }
                format!("<{}{t}>", &c[1])
            })
            .into_owned()
        })
        .collect::<Vec<_>>()
        .join(cue_gap.as_str())
}

/// the last word of the name, past the marks that aren't a language: movie.sr-Latn.forced.srt
fn guess_lang(name: &str) -> String {
    const LANGS: [(&str, &[&str]); 16] = [
        ("en", &["en", "eng", "english"]), ("sr", &["sr", "srp", "scc", "serbian", "srpski"]), ("hr", &["hr", "hrv", "scr", "croatian", "hrvatski"]),
        ("bs", &["bs", "bos", "bosnian", "bosanski"]), ("sl", &["sl", "slv", "slovenian", "slovenski"]), ("mk", &["mk", "mkd", "macedonian", "makedonski"]),
        ("de", &["de", "ger", "deu", "german"]), ("fr", &["fr", "fre", "fra", "french"]), ("es", &["es", "spa", "spanish"]), ("it", &["it", "ita", "italian"]),
        ("ru", &["ru", "rus", "russian"]), ("pt", &["pt", "por", "portuguese"]), ("pl", &["pl", "pol", "polish"]), ("nl", &["nl", "dut", "nld", "dutch"]),
        ("tr", &["tr", "tur", "turkish"]), ("ja", &["ja", "jpn", "japanese"]),
    ];
    const MARKS: [&str; 9] = ["forced", "sdh", "hi", "cc", "latn", "latin", "cyrl", "cyr", "lat"];
    let stem = name.rsplit_once('.').map_or(name, |n| n.0).to_lowercase();
    let word = stem.split(|c: char| !c.is_alphanumeric()).rev().find(|w| !w.is_empty() && !MARKS.contains(w)).unwrap_or("");
    LANGS.iter().find(|(_, names)| names.contains(&word)).map_or(String::new(), |l| l.0.to_owned())
}

/// a subtitle file of the viewer's own, kept as a utf-8 copy (it reads right, and stays when the
/// original moves)
pub fn import(path: &str) -> Result<Found> {
    use std::hash::{Hash, Hasher};
    let file = std::path::Path::new(path);
    let bytes = std::fs::read(file)?;
    anyhow::ensure!(bytes.len() <= 8 << 20, "not a subtitle file");
    let text = decode(&bytes).context("not a subtitle file")?;
    let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = file.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_else(|| "srt".into());
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hash);
    let dir = PATHS.cache.join("subs");
    std::fs::create_dir_all(&dir)?;
    let copy = dir.join(format!("import-{:016x}.{ext}", hash.finish()));
    std::fs::write(&copy, tidy(&text))?;
    Ok(Found {
        path: copy.to_string_lossy().into_owned(),
        lang: guess_lang(&name),
        key: format!("ext:{name}"),
        title: name,
        score: 0.0,
        provider: "file".into(),
        src: Value::Null,
        liked: false,
    })
}

fn req(url: String) -> Req {
    Req::get(url)
        .header("Api-Key", &config::secret(keys::OPENSUBTITLES_API_KEY).unwrap_or_default())
        .header("User-Agent", concat!("NoonixTV v", env!("CARGO_PKG_VERSION")))
        .header("Accept", "application/json")
        .timeout(10)
}

/// opensubtitles.com is used when the user turned it on and gave a key (a key alone means on)
pub async fn opensubtitles_on() -> bool {
    if !config::has_secret(keys::OPENSUBTITLES_API_KEY) {
        return false;
    }
    let app = crate::store::with(|c| crate::store::settings(c, "app")).await.unwrap_or_default();
    app.get("opensubtitles").and_then(Value::as_bool).unwrap_or(true)
}

// a signed-in user's token (24 h) raises the quota to their account's
static OS_TOKEN: once_cell::sync::Lazy<tokio::sync::Mutex<Option<(String, i64)>>> = once_cell::sync::Lazy::new(|| tokio::sync::Mutex::new(None));

/// logs in with the stored account, if there is one
pub async fn login(force: bool) -> Result<Option<String>> {
    let (Some(user), Some(pass)) = (config::secret(OS_USERNAME), config::secret(OS_PASSWORD)) else {
        return Ok(None);
    };
    let mut slot = OS_TOKEN.lock().await;
    if let Some((t, until)) = slot.as_ref() {
        if !force && *until > crate::store::now() {
            return Ok(Some(t.clone()));
        }
    }
    let r = Req::post(format!("{API}/login"), json!({ "username": user, "password": pass }))
        .header("Api-Key", &config::secret(keys::OPENSUBTITLES_API_KEY).unwrap_or_default())
        .header("User-Agent", concat!("NoonixTV v", env!("CARGO_PKG_VERSION")))
        .header("Accept", "application/json")
        .timeout(10);
    let v = http::json(&r).await.context("OpenSubtitles sign-in failed")?;
    let token = v.get("token").and_then(Value::as_str).context("OpenSubtitles didn't sign in")?.to_owned();
    *slot = Some((token.clone(), crate::store::now() + 23 * 3600));
    Ok(Some(token))
}

/// for setup: the key works (and the account, when given); {ok, downloads, message}
pub async fn check() -> Result<Value> {
    http::ensure(config::has_secret(keys::OPENSUBTITLES_API_KEY), "no OpenSubtitles key")?;
    let v = http::json(&req(format!("{API}/infos/formats"))).await.context("the key wasn't accepted")?;
    http::ensure(v.get("data").is_some(), "the key wasn't accepted")?;
    let mut out = json!({ "ok": true });
    if let Some(token) = login(true).await? {
        let me = http::json(&req(format!("{API}/infos/user")).header("Authorization", &format!("Bearer {token}"))).await?;
        out["downloads"] = me.pointer("/data/allowed_downloads").cloned().unwrap_or(Value::Null);
        out["vip"] = me.pointer("/data/vip").cloned().unwrap_or(Value::Null);
    }
    Ok(out)
}

/// opensubtitles language codes for one preference set
fn os_codes(set: &[String]) -> Vec<String> {
    set.iter().map(|c| if c == "pt" { "pt-PT".into() } else { c.clone() }).collect()
}

/// the 2-letter code of a track language tag (eng, en, scc, en-US, es-419...)
pub fn two_letter(tag: &str) -> Option<String> {
    let t = tag.split(['-', '_']).next().unwrap_or("").to_lowercase();
    if t.len() == 2 {
        return Some(t);
    }
    crate::stremio::LANGUAGE_NAMES
        .iter()
        .map(|(c, _)| *c)
        .find(|c| crate::stremio::iso639_tags(c).contains(&t))
        .map(str::to_owned)
}

/// how well a subtitle fits this exact file: group, fps, resolution, codec, web timing
pub fn match_score(attr: &Value, rel: &Release) -> f64 {
    let release = attr.get("release").and_then(Value::as_str).unwrap_or("").to_lowercase();
    let mut n = 0.0;
    // made for this very file: nothing fits better
    if !release.is_empty() && same_name(&release, &rel.name) {
        n += 40.0;
    }
    if let Some(g) = rel.group.as_deref().map(str::to_lowercase).filter(|g| g.len() > 1) {
        if release.contains(&g) {
            n += 20.0;
        }
    }
    let fps = attr.get("fps").and_then(Value::as_f64).unwrap_or(0.0);
    if rel.fps > 0.0 && fps > 0.0 && (rel.fps - fps).abs() < 0.01 {
        n += 8.0;
    }
    if rel.resolution > 0 && release.contains(&format!("{}p", rel.resolution)) {
        n += 5.0;
    }
    let codec_hit = match rel.codec.as_deref() {
        Some("HEVC") => ["x265", "h265", "h.265", "hevc"].iter().any(|c| release.contains(c)),
        Some("AVC") => ["x264", "h264", "h.264", "avc"].iter().any(|c| release.contains(c)),
        _ => false,
    };
    if codec_hit {
        n += 3.0;
    }
    // web releases share the same timing across groups
    let web = |s: &str| s.contains("web-dl") || s.contains("webdl") || s.contains("web.") || s.contains("webrip");
    if web(&rel.name.to_lowercase()) && web(&release) {
        n += 4.0;
    }
    n
}

/// how good the subtitle is on its own: popularity, ratings, trusted uploader, sdh
pub fn quality(attr: &Value) -> f64 {
    let mut n = (attr.get("download_count").and_then(Value::as_f64).unwrap_or(0.0) / 100.0).min(10.0);
    if attr.get("hearing_impaired").and_then(Value::as_bool).unwrap_or(false) {
        n -= 8.0;
    }
    if attr.get("from_trusted").and_then(Value::as_bool).unwrap_or(false) {
        n += 3.0;
    }
    n + attr.get("ratings").and_then(Value::as_f64).unwrap_or(0.0) * 2.0
}

fn translated(attr: &Value) -> bool {
    attr.get("machine_translated").and_then(Value::as_bool).unwrap_or(false)
        || attr.get("ai_translated").and_then(Value::as_bool).unwrap_or(false)
}

#[derive(Debug, Clone, PartialEq)]
enum Src {
    OpenSubtitles(i64),
    /// stremio addon: (id, url)
    Addon(String, String),
}

impl Src {
    fn file_name(&self) -> String {
        match self {
            Src::OpenSubtitles(file_id) => format!("{file_id}.srt"),
            Src::Addon(id, _) => format!("v3-{}.srt", id.replace(['/', '.'], "_")),
        }
    }
    fn key(&self) -> String {
        format!("ext:{}", self.file_name())
    }
    fn provider(&self) -> &'static str {
        match self {
            Src::OpenSubtitles(_) => "opensubtitles",
            Src::Addon(..) => "v3",
        }
    }
    fn json(&self) -> Value {
        match self {
            Src::OpenSubtitles(file_id) => json!({ "os": file_id }),
            Src::Addon(id, url) => json!({ "v3": id, "url": url }),
        }
    }
    fn from_json(v: &Value) -> Option<Src> {
        if let Some(id) = v.get("os").and_then(Value::as_i64) {
            return Some(Src::OpenSubtitles(id));
        }
        Some(Src::Addon(v.get("v3")?.as_str()?.to_owned(), v.get("url")?.as_str()?.to_owned()))
    }
}

#[derive(Debug, Clone)]
struct Cand {
    translated: bool,
    fit: f64,
    lang_rank: usize, // position in the preference set (balkan: sr, bs, hr)
    quality: f64,
    src: Src,
    release: String,
    lang: String,
}

/// machine translations last, then the best fit to the file, then the preferred language,
/// then popularity: a serbian sub for another release never beats a croatian one for this one
/// one release name either way: case, separators and the file extension don't count
fn same_name(a: &str, b: &str) -> bool {
    let norm = |s: &str| {
        let s = s.trim().to_lowercase();
        let s = [".mkv", ".mp4", ".avi", ".srt", ".ass", ".sub"].iter().fold(s, |s, e| s.strip_suffix(e).map(str::to_owned).unwrap_or(s));
        s.chars().map(|c| if c.is_alphanumeric() { c } else { '.' }).collect::<String>().split('.').filter(|p| !p.is_empty()).collect::<Vec<_>>().join(".")
    };
    let (a, b) = (norm(a), norm(b));
    !a.is_empty() && a == b
}

fn order(c: &mut [Cand]) {
    c.sort_by(|a, b| {
        a.translated
            .cmp(&b.translated)
            .then(b.fit.total_cmp(&a.fit))
            .then(a.lang_rank.cmp(&b.lang_rank))
            .then(b.quality.total_cmp(&a.quality))
    });
}

async fn download(src: &Src) -> Result<String> {
    let dir = PATHS.cache.join("subs");
    let path = dir.join(src.file_name());
    let link = match src {
        Src::OpenSubtitles(_) => None,
        Src::Addon(_, url) => Some(url.clone()),
    };
    if path.exists() {
        // saved before the tidy-up: once more through it
        if let Ok(bytes) = std::fs::read(&path) {
            if let Some(t) = decode(&bytes).filter(|t| tidy(t) != *t) {
                let _ = std::fs::write(&path, tidy(&t));
            }
        }
        return Ok(path.to_string_lossy().into_owned());
    }
    let link = match (src, link) {
        (_, Some(url)) => url,
        (Src::OpenSubtitles(file_id), None) => os_link(*file_id).await?,
        _ => unreachable!(),
    };
    let (status, bytes) = http::send(&Req::get(link).timeout(15)).await?;
    http::ensure(status.is_success() && !bytes.is_empty(), "subtitle download failed")?;
    std::fs::create_dir_all(&dir)?;
    match decode(&bytes) {
        Some(t) => std::fs::write(&path, tidy(&t))?,
        None => std::fs::write(&path, &bytes)?,
    }
    Ok(path.to_string_lossy().into_owned())
}

/// a one-time link for one file; counts against the account's (or this ip's) daily quota
async fn os_link(file_id: i64) -> Result<String> {
    let key = config::secret(keys::OPENSUBTITLES_API_KEY).unwrap_or_default();
    let mut r = Req::post(format!("{API}/download"), json!({ "file_id": file_id }))
        .header("Api-Key", &key)
        .header("User-Agent", concat!("NoonixTV v", env!("CARGO_PKG_VERSION")))
        .header("Accept", "application/json")
        .timeout(10);
    if let Ok(Some(token)) = login(false).await {
        r = r.header("Authorization", &format!("Bearer {token}"));
    }
    let v = http::json(&r).await?;
    // a dead key or a spent quota answers with a message instead of a link
    let link = v.get("link").and_then(Value::as_str).with_context(|| {
        format!("no download link: {}", v.get("message").and_then(Value::as_str).unwrap_or("unknown"))
    })?;
    Ok(link.to_owned())
}

/// the api key is purged after 60 days without a download: one real download resets that
/// (the search only finds something to download; the file itself isn't fetched)
pub async fn keepalive() -> Result<String> {
    http::ensure(config::has_secret(keys::OPENSUBTITLES_API_KEY), "no OpenSubtitles key")?;
    let v = http::json(&req(format!("{API}/subtitles?languages=en&query=hello"))).await?;
    let file_id = v.pointer("/data/0/attributes/files/0/file_id").and_then(Value::as_i64).context("no subtitle to download")?;
    let r = Req::post(format!("{API}/download"), json!({ "file_id": file_id }))
        .header("Api-Key", &config::secret(keys::OPENSUBTITLES_API_KEY).unwrap_or_default())
        .header("User-Agent", concat!("NoonixTV v", env!("CARGO_PKG_VERSION")))
        .header("Accept", "application/json")
        .timeout(10);
    let d = http::json(&r).await?;
    http::ensure(d.get("link").is_some(), d.get("message").and_then(Value::as_str).unwrap_or("download refused"))?;
    Ok(format!("{} downloads left today", d.get("remaining").and_then(Value::as_i64).unwrap_or(-1)))
}

/// opensubtitles.com candidates for the missing language codes: (2-letter lang, attributes, source)
async fn os_candidates(imdb: &str, season: Option<i64>, episode: Option<i64>, codes: &[String]) -> Result<Vec<(String, Value, Src)>> {
    let num = imdb.trim_start_matches("tt").trim_start_matches('0');
    let url = match (season, episode) {
        (Some(s), Some(e)) => format!("{API}/subtitles?episode_number={e}&languages={}&parent_imdb_id={num}&season_number={s}", codes.join(",")),
        _ => format!("{API}/subtitles?imdb_id={num}&languages={}", codes.join(",")),
    };
    // a few hours: the sources sheet asks for the same list again and again
    let v = http::cached_json(&format!("ossubs:{url}"), 3 * 3600, req(url.clone())).await?;
    Ok(v.get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|d| {
            let attr = d.get("attributes")?;
            let lang = attr.get("language").and_then(Value::as_str).unwrap_or("").to_lowercase();
            let lang = lang.split('-').next().unwrap_or("").to_owned();
            let file_id = attr.pointer("/files/0/file_id").and_then(Value::as_i64)?;
            Some((lang, attr.clone(), Src::OpenSubtitles(file_id)))
        })
        .collect())
}

/// the v3 addon answers every language at once, already in its own order: that order is
/// the only popularity it tells
fn v3_parse(v: &Value) -> Vec<(String, Value, Src)> {
    let list = v.get("subtitles").and_then(Value::as_array).cloned().unwrap_or_default();
    let n = list.len().max(1) as f64;
    list.iter()
        .enumerate()
        .filter_map(|(i, s)| {
            let url = s.get("url").and_then(Value::as_str)?.to_owned();
            let id = s.get("id").map(|x| x.as_str().map(str::to_owned).unwrap_or_else(|| x.to_string())).unwrap_or_else(|| i.to_string());
            let lang = two_letter(s.get("lang").and_then(Value::as_str).unwrap_or(""))?;
            let file = s.get("subtitleFileName").and_then(Value::as_str).unwrap_or("");
            let release = s.get("movieReleaseName").and_then(Value::as_str).filter(|r| !r.is_empty()).unwrap_or(file);
            // the addon's own group for it (synced to another release now and then)
            let group = s.get("releaseGroup").and_then(Value::as_str).unwrap_or("");
            let fps = s.get("fpsMilli").and_then(Value::as_f64).map(|f| f / 1000.0).unwrap_or(0.0);
            let hi = { let f = file.to_lowercase(); f.contains("-hi.") || f.contains(".hi.") || f.contains("sdh") };
            let attr = json!({ "release": format!("{release} {file} -{group}"), "title": release.trim_end_matches(".srt"), "fps": fps, "hearing_impaired": hi, "download_count": (1.0 - i as f64 / n) * 1000.0 });
            Some((lang, attr, Src::Addon(id, url)))
        })
        .collect()
}

async fn v3_candidates(imdb: &str, season: Option<i64>, episode: Option<i64>) -> Result<Vec<(String, Value, Src)>> {
    let id = match (season, episode) {
        (Some(s), Some(e)) => format!("series/{imdb}:{s}:{e}"),
        _ => format!("movie/{imdb}"),
    };
    let key = format!("v3subs:{id}");
    let v = http::cached_json(&key, 6 * 3600, Req::get(format!("{V3}/subtitles/{}.json", urlencoding::encode(&id).replace("%2F", "/"))).timeout(10).retries(1)).await?;
    Ok(v3_parse(&v))
}

/// how much the viewers' earlier picks lift a candidate: made for a group the show liked, from
/// the same source, in the same language
fn liked_bonus(attr: &Value, src: &Src, lang: &str, learn: &SubLearn) -> f64 {
    let release = attr.get("release").and_then(Value::as_str).unwrap_or("").to_lowercase();
    let hit = learn.liked.iter().any(|(provider, group, l)| provider == src.provider() && l == lang && release.contains(group.as_str()));
    if hit { 15.0 } else { 0.0 }
}

/// ranked candidates of one preference set from one source; reported ones never come back, nor
/// their copy on the other source (same release name)
fn ranked(set: &[String], pool: &[(String, Value, Src)], rel: &Release, learn: &SubLearn) -> Vec<Cand> {
    let mut c: Vec<Cand> = set
        .iter()
        .enumerate()
        .flat_map(|(rank, l)| {
            pool.iter().filter(move |(lang, _, src)| lang == l && !learn.bad.contains(&src.key())).map(move |(lang, attr, src)| Cand {
                translated: translated(attr),
                fit: match_score(attr, rel) + liked_bonus(attr, src, lang, learn),
                lang_rank: rank,
                quality: quality(attr),
                src: src.clone(),
                release: attr.get("title").or_else(|| attr.get("release")).and_then(Value::as_str).unwrap_or("").to_owned(),
                lang: lang.clone(),
            })
        })
        .filter(|c: &Cand| c.release.is_empty() || !learn.bad_names.contains(&c.release.to_lowercase()))
        .collect();
    order(&mut c);
    c
}

/// every external subtitle of the title in the wanted languages (lang, attributes), for ranking
/// releases before one plays. only cached or cheap lookups: no download, no quota
pub async fn pool(imdb: &str, season: Option<i64>, episode: Option<i64>, prefs: &[String], original: Option<&str>) -> Vec<(String, Value)> {
    let sets = ranking::expand(prefs, original);
    let mut codes: Vec<String> = sets.iter().flat_map(|s| os_codes(s)).collect();
    codes.sort();
    codes.dedup();
    if codes.is_empty() {
        return Vec::new();
    }
    let os = async {
        if opensubtitles_on().await {
            os_candidates(imdb, season, episode, &codes).await.unwrap_or_default()
        } else {
            Vec::new()
        }
    };
    let (os, v3) = tokio::join!(os, v3_candidates(imdb, season, episode));
    let wanted = |l: &String| sets.iter().any(|s| s.contains(l));
    os.into_iter().chain(v3.unwrap_or_default()).filter(|(l, _, _)| wanted(l)).map(|(l, a, _)| (l, a)).collect()
}

/// (wanted sets with a subtitle made for this release, how many such subtitles). made for it =
/// the release group is in the subtitle's name
pub fn fits(pool: &[(String, Value)], sets: &[Vec<String>], rel: &Release) -> (u8, u8) {
    let hits: Vec<&String> = pool.iter().filter(|(_, a)| match_score(a, rel) >= 20.0).map(|(l, _)| l).collect();
    let covered = sets.iter().filter(|set| hits.iter().any(|l| set.contains(l))).count();
    (covered.min(255) as u8, hits.len().min(255) as u8)
}

fn found(c: &Cand, path: String, name: &str, liked: bool) -> Found {
    // the release it was made for tells two of a language apart
    let title = if c.release.is_empty() { name.to_owned() } else { c.release.clone() };
    Found { path, lang: c.lang.clone(), title, score: c.fit, key: c.src.key(), provider: c.src.provider().into(), src: c.src.json(), liked }
}

/// embedded = language tags of the file's own non-forced subtitle tracks (the ones the viewers
/// reported left out). a subtitle liked with this file comes back first, embedded track or not
#[allow(clippy::too_many_arguments)]
pub async fn find(
    imdb: &str,
    season: Option<i64>,
    episode: Option<i64>,
    prefs: &[String],
    original: Option<&str>,
    embedded: &[String],
    rel: &Release,
    learn: &SubLearn,
) -> Result<Vec<Found>> {
    let have: Vec<String> = embedded.iter().filter_map(|t| two_letter(t)).collect();
    let liked: Vec<&crate::matches::Sub> = learn.exact.iter().filter(|s| !s.is_embedded()).collect();
    let missing: Vec<Vec<String>> = ranking::expand(prefs, original)
        .into_iter()
        .filter(|set| !set.iter().any(|c| have.contains(c)) || liked.iter().any(|s| set.contains(&s.lang)))
        .collect();
    if missing.is_empty() {
        return Ok(Vec::new());
    }
    let (os, v3) = candidates(imdb, season, episode, &missing).await;

    let mut out: Vec<Found> = Vec::new();
    let mut os_spent = false;
    for set in &missing {
        let mut got = 0;
        for s in liked.iter().filter(|s| set.contains(&s.lang)) {
            let Some(src) = s.src.as_ref().and_then(Src::from_json) else { continue };
            match download(&src).await {
                Ok(path) => {
                    let c = Cand { translated: false, fit: 100.0, lang_rank: 0, quality: 0.0, src, release: s.name.clone(), lang: s.lang.clone() };
                    tracing::info!("subtitle {} liked with this release: {}", c.lang, c.release);
                    out.push(found(&c, path, "", true));
                    got += 1;
                }
                Err(e) => tracing::warn!("liked subtitle: {e:#}"),
            }
        }
        // a set is one preference: "balkan" takes the best fit of sr / bs / hr. opensubtitles
        // first when it's on, v3 for whatever is still missing
        for (pool, name) in [(&os, "OpenSubtitles"), (&v3, "OpenSubtitles v3")] {
            if got >= PER_LANGUAGE || (name == "OpenSubtitles" && os_spent) {
                continue;
            }
            for c in ranked(set, pool, rel, learn) {
                if got >= PER_LANGUAGE {
                    break;
                }
                if out.iter().any(|f| f.key == c.src.key()) {
                    continue;
                }
                match download(&c.src).await {
                    Ok(path) if wrong_length(&path, rel).is_some() => {
                        tracing::info!("subtitle skipped, {}: {}", wrong_length(&path, rel).unwrap_or_default(), c.release);
                    }
                    Ok(path) => {
                        tracing::info!("subtitle {} from {name}, fit {:.0} quality {:.1}: {}", c.lang, c.fit, c.quality, c.release);
                        out.push(found(&c, path, name, false));
                        got += 1;
                    }
                    Err(e) => {
                        tracing::warn!("subtitle download ({name}): {e:#}");
                        // the quota is per day: don't burn the rest of the list, v3 takes over
                        if matches!(c.src, Src::OpenSubtitles(_)) && format!("{e:#}").contains("no download link") {
                            os_spent = true;
                            break;
                        }
                    }
                }
            }
        }
    }
    Ok(out)
}

/// opensubtitles.com (when it's on) and v3 candidates for these sets
async fn candidates(imdb: &str, season: Option<i64>, episode: Option<i64>, sets: &[Vec<String>]) -> (Vec<(String, Value, Src)>, Vec<(String, Value, Src)>) {
    let os = if opensubtitles_on().await {
        let mut codes: Vec<String> = sets.iter().flat_map(|s| os_codes(s)).collect();
        codes.sort();
        codes.dedup();
        os_candidates(imdb, season, episode, &codes).await.unwrap_or_else(|e| {
            tracing::warn!("opensubtitles: {e:#}");
            Vec::new()
        })
    } else {
        Vec::new()
    };
    let v3 = v3_candidates(imdb, season, episode).await.unwrap_or_else(|e| {
        tracing::warn!("opensubtitles v3: {e:#}");
        Vec::new()
    });
    (os, v3)
}

/// "try other subtitles": the next candidate of a language set past the ones already tried,
/// ranked like find() across both sources. (the subtitle, how many are left after it)
#[allow(clippy::too_many_arguments)]
pub async fn next(
    imdb: &str,
    season: Option<i64>,
    episode: Option<i64>,
    set: &[String],
    rel: &Release,
    learn: &SubLearn,
    skip: &std::collections::HashSet<String>,
    skip_names: &std::collections::HashSet<String>,
) -> Result<(Option<Found>, usize)> {
    let (os, v3) = candidates(imdb, season, episode, &[set.to_vec()]).await;
    let mut all = ranked(set, &os, rel, learn);
    all.extend(ranked(set, &v3, rel, learn));
    order(&mut all);
    // made for a release already ruled out: mostly the same file from the other source
    all.retain(|c| !skip.contains(&c.src.key()) && (c.release.is_empty() || !skip_names.contains(&c.release.to_lowercase())));
    let mut seen = std::collections::HashSet::new();
    all.retain(|c| seen.insert(c.src.key()));
    // a few of the wrong length at most: every download counts against the daily quota
    let mut wrong = 0;
    for (i, c) in all.iter().enumerate() {
        match download(&c.src).await {
            Ok(path) if wrong < 3 && wrong_length(&path, rel).is_some() => {
                tracing::info!("subtitle skipped, {}: {}", wrong_length(&path, rel).unwrap_or_default(), c.release);
                wrong += 1;
            }
            Ok(path) => return Ok((Some(found(c, path, if matches!(c.src, Src::OpenSubtitles(_)) { "OpenSubtitles" } else { "OpenSubtitles v3" }, false)), all.len() - i - 1)),
            Err(e) => tracing::warn!("subtitle download: {e:#}"),
        }
    }
    Ok((None, 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spaced_tags_are_closed_up() {
        assert_eq!(tidy("1\n00:00:01,000 --> 00:00:02,000\n< i >Engines.< / i >\n"), "1\n00:00:01,000 --> 00:00:02,000\n<i>Engines.</i>\n");
        assert_eq!(tidy("< I >Hi</i> <b>x< /B>"), "<i>Hi</i> <b>x</b>");
        assert_eq!(tidy("a < b and c > d"), "a < b and c > d");
        // a closing tag with nothing open in its cue goes; the next cue starts fresh
        assert_eq!(tidy("2\r\nI have started the main engines. </i>\r\n\r\n3\r\n<i>Four</i>"),
                   "2\r\nI have started the main engines. \r\n\r\n3\r\n<i>Four</i>");
    }

    #[test]
    fn imported_files_read_right() {
        assert_eq!(CP1250.chars().count(), 128);
        assert_eq!(CP1251.chars().count(), 128);
        // "čćžšđ" in 1250, a word of cyrillic in 1251
        assert_eq!(decode(b"1\n00:00:01,000\nrecenica \xe8\xe6\x9e\x9a\xf0").unwrap(), "1\n00:00:01,000\nrecenica čćžšđ");
        assert_eq!(decode(b"\xf1\xf0\xef\xf1\xea\xe8 \xf2\xe5\xea\xf1\xf2").unwrap(), "српски текст");
        assert_eq!(decode("već utf-8".as_bytes()).unwrap(), "već utf-8");
        assert_eq!(decode(b"\xef\xbb\xbfbom").unwrap(), "bom");
        assert_eq!(decode(b"\xff\xfea\0b\0").unwrap(), "ab");
        assert!(decode(b"\0\x01binary").is_none());
        // double encoded utf-8 goes back; real latin-1 text and real utf-8 stay
        assert_eq!(decode("â™ª Is finding a good way â™ª".as_bytes()).unwrap(), "♪ Is finding a good way ♪");
        assert_eq!(decode("reÄ‡enica Å¡ta".as_bytes()).unwrap(), "rećenica šta");
        assert_eq!(decode("Ã‰tÃ© dÃ©jÃ\u{a0}".as_bytes()).unwrap(), "Été déjà");
        assert_eq!(decode("crème brûlée".as_bytes()).unwrap(), "crème brûlée");
        assert_eq!(decode("Ã and ♪ together".as_bytes()).unwrap(), "Ã and ♪ together");
    }

    #[test]
    fn imported_language_comes_from_the_name() {
        assert_eq!(guess_lang("Movie.2019.1080p.sr.srt"), "sr");
        assert_eq!(guess_lang("Movie.2019.eng.forced.srt"), "en");
        assert_eq!(guess_lang("Movie-sr-Latn.ass"), "sr");
        assert_eq!(guess_lang("Film [Hrvatski].srt"), "hr");
        assert_eq!(guess_lang("Movie.2019.1080p.WEB-DL.srt"), "");
    }

    fn cand(attr: Value, rank: usize, lang: &str, rel: &Release) -> Cand {
        Cand { translated: translated(&attr), fit: match_score(&attr, rel), lang_rank: rank, quality: quality(&attr), src: Src::OpenSubtitles(0), release: String::new(), lang: lang.into() }
    }

    #[test]
    fn best_fit_first_then_language() {
        let rel = Release { name: "Show.S01E02.1080p.WEB-DL.H.264-GRP".into(), group: Some("GRP".into()), resolution: 1080, codec: Some("AVC".into()), fps: 23.976, ..Default::default() };
        let fit = json!({ "release": "Show.S01E02.1080p.WEB-DL.H.264-GRP", "fps": 23.976, "download_count": 300 });
        let mt = json!({ "release": "Show.S01E02.1080p.WEB-DL.H.264-GRP", "fps": 23.976, "machine_translated": true, "download_count": 9000 });
        let other = json!({ "release": "Show.S01E02.720p.HDTV.x264-OLD", "download_count": 9000, "ratings": 9 });
        // croatian for this release beats a popular serbian one for another release
        let mut c = vec![cand(other.clone(), 0, "sr", &rel), cand(mt, 0, "sr", &rel), cand(fit.clone(), 2, "hr", &rel)];
        order(&mut c);
        assert_eq!(c.iter().map(|x| x.lang.as_str()).collect::<Vec<_>>(), ["hr", "sr", "sr"]);
        assert!(c[2].translated);
        // the same fit: serbian, then bosnian, then croatian
        let mut c = vec![cand(fit.clone(), 2, "hr", &rel), cand(fit.clone(), 0, "sr", &rel), cand(fit, 1, "bs", &rel)];
        order(&mut c);
        assert_eq!(c.iter().map(|x| x.lang.as_str()).collect::<Vec<_>>(), ["sr", "bs", "hr"]);
        assert_eq!(two_letter("srp").as_deref(), Some("sr"));
        assert_eq!(two_letter("eng").as_deref(), Some("en"));
        assert_eq!(two_letter("en-US").as_deref(), Some("en"));
        assert_eq!(two_letter("es-419").as_deref(), Some("es"));
    }

    #[test]
    fn the_exact_release_beats_its_group() {
        let rel = Release { name: "Show.S01E02.1080p.WEB-DL.H.264-GRP.mkv".into(), group: Some("GRP".into()), resolution: 1080, codec: Some("AVC".into()), fps: 23.976, ..Default::default() };
        let exact = json!({ "release": "show s01e02 1080p web-dl h 264-grp" });
        let group = json!({ "release": "Show.S01E02.1080p.WEB.H264-GRP", "fps": 23.976 });
        assert!(match_score(&exact, &rel) > match_score(&group, &rel));
        assert!(!same_name("Show.S01E02.720p.HDTV-GRP", &rel.name));
    }

    #[test]
    fn fits_by_release_group() {
        let rel = Release { name: "Show.S01E02.1080p.WEB-DL.H.264-GRP".into(), group: Some("GRP".into()), resolution: 1080, codec: Some("AVC".into()), fps: 0.0, ..Default::default() };
        let pool = vec![
            ("en".to_owned(), json!({ "release": "Show.S01E02.1080p.WEB-DL.H.264-GRP" })),
            ("en".to_owned(), json!({ "release": "Show.S01E02.WEB.h264-GRP" })),
            ("hr".to_owned(), json!({ "release": "Show.S01E02.1080p.WEB-DL.H.264-GRP" })),
            ("sr".to_owned(), json!({ "release": "Show.S01E02.1080p.WEB.H264-OTHER" })),
        ];
        let sets = vec![vec!["en".to_owned()], vec!["sr".to_owned(), "bs".to_owned(), "hr".to_owned()], vec!["de".to_owned()]];
        assert_eq!(fits(&pool, &sets, &rel), (2, 3));
        let other = Release { name: "Show.S01E02.2160p.WEB.H265-ZZZ".into(), group: Some("ZZZ".into()), resolution: 2160, ..Default::default() };
        assert_eq!(fits(&pool, &sets, &other), (0, 0));
    }

    #[test]
    fn subtitle_length_against_the_file() {
        assert_eq!(last_cue("1\n00:00:01,000 --> 00:00:02,500\nhi\n\n2\n00:52:10,250 --> 00:52:12,000\nbye\n"), 3132.0);
        assert_eq!(last_cue("Dialogue: 0,0:01:02.03,0:44:04.50,Default,,0,0,0,,x"), 2644.5);
        let dir = std::env::temp_dir().join(format!("noonix-len-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = |name: &str, end: &str| {
            let p = dir.join(name);
            std::fs::write(&p, format!("1\n00:00:05,000 --> {end}\nx\n")).unwrap();
            p.to_string_lossy().into_owned()
        };
        let rel = Release { duration: 3216.0, ..Default::default() };
        assert!(wrong_length(&file("ok.srt", "00:52:40,000"), &rel).is_none());
        // an extended cut, and one that stops halfway
        assert!(wrong_length(&file("long.srt", "01:01:00,000"), &rel).is_some());
        assert!(wrong_length(&file("short.srt", "00:30:00,000"), &rel).is_some());
        // unknown duration: no opinion
        assert!(wrong_length(&file("any.srt", "01:30:00,000"), &Release::default()).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn fit_weights() {
        let rel = Release { name: "Show.S01E02.2160p.WEB-DL.DDP5.1.DV.H.265-GRP".into(), group: Some("GRP".into()), resolution: 2160, codec: Some("HEVC".into()), fps: 23.976, ..Default::default() };
        let score = |release: &str, fps: f64| match_score(&json!({ "release": release, "fps": fps }), &rel);
        // group 20 + fps 8 + resolution 5 + codec 3 + web 4
        assert_eq!(score("Show.S01E02.2160p.WEB-DL.H.265-GRP", 23.976), 40.0);
        // another web group at the same fps still times well
        assert_eq!(score("Show.S01E02.1080p.WEB-DL.x264-ZZZ", 23.976), 12.0);
        // a bluray at 25 fps barely counts
        assert_eq!(score("Show.S01E02.1080p.BluRay.x264-DEMAND", 25.0), 0.0);
        assert!(translated(&json!({ "ai_translated": true })) && !translated(&json!({})));
    }

    #[test]
    fn v3_answers() {
        // the shape opensubtitles-v3.strem.io returns (euphoria s03e04, trimmed)
        let v = json!({ "subtitles": [
            { "id": "1", "url": "https://subs5.strem.io/a", "lang": "eng", "subtitleFileName": "Euphoria.US.S03E04.720p.HDTV.x264-OLD.srt", "movieReleaseName": "Euphoria.US.S03E04.720p.HDTV.x264-OLD", "fpsMilli": 25000 },
            { "id": "2", "url": "https://subs5.strem.io/b", "lang": "eng", "subtitleFileName": "Euphoria.US.S03E04.2160p.WEB-DL.H.265-GRP.srt", "movieReleaseName": "Euphoria.US.S03E04.2160p.WEB-DL.H.265-GRP", "fpsMilli": 23976 },
            { "id": "3", "url": "https://subs5.strem.io/c", "lang": "hrv", "subtitleFileName": "Euphoria.S03E04.WEB.srt", "movieReleaseName": "", "fpsMilli": 23976 },
            { "id": "4", "url": "https://subs5.strem.io/d", "lang": "pob", "subtitleFileName": "x.srt" },
            { "id": "5", "lang": "srp" },
        ] });
        let pool = v3_parse(&v);
        // no url: dropped; brazilian portuguese has no 2-letter match in our list: dropped
        assert_eq!(pool.iter().map(|p| p.0.as_str()).collect::<Vec<_>>(), ["en", "en", "hr"]);
        assert_eq!(pool[2].2, Src::Addon("3".into(), "https://subs5.strem.io/c".into()));
        let rel = Release { name: "Euphoria.US.S03E04.2160p.WEB-DL.DDP5.1.H.265-GRP".into(), group: Some("GRP".into()), resolution: 2160, codec: Some("HEVC".into()), fps: 23.976, ..Default::default() };
        // the one made for this release wins over the addon's first pick
        let en = ranked(&["en".to_owned()], &pool, &rel, &SubLearn::default());
        assert_eq!(en[0].src, Src::Addon("2".into(), "https://subs5.strem.io/b".into()));
        assert_eq!(en[0].release, "Euphoria.US.S03E04.2160p.WEB-DL.H.265-GRP");
        // balkan set: croatian is all there is
        let b = ranked(&["sr".to_owned(), "bs".to_owned(), "hr".to_owned()], &pool, &rel, &SubLearn::default());
        assert_eq!((b.len(), b[0].lang.as_str(), b[0].lang_rank), (1, "hr", 2));
    }

    #[test]
    fn viewers_picks_steer_the_subtitles() {
        let rel = Release { name: "Euphoria.US.S01E02.1080p.WEB.H264-OTHER".into(), group: Some("OTHER".into()), resolution: 1080, codec: Some("AVC".into()), fps: 23.976, ..Default::default() };
        let pool = vec![
            ("en".to_owned(), json!({ "release": "Euphoria.US.S01E02.1080p.WEB.H264-POPULAR", "download_count": 9000 }), Src::Addon("1".into(), "u1".into())),
            ("en".to_owned(), json!({ "release": "Euphoria.US.S01E02.720p.HDTV.x264-OLD", "download_count": 50 }), Src::Addon("2".into(), "u2".into())),
            ("en".to_owned(), json!({ "release": "Euphoria.US.S01E02.1080p.WEB.H264-BAD", "download_count": 9999 }), Src::Addon("3".into(), "u3".into())),
        ];
        let en = ["en".to_owned()];
        // nothing learned: the popular ones (popularity caps, so the addon's order breaks the tie)
        assert_eq!(ranked(&en, &pool, &rel, &SubLearn::default())[0].src, Src::Addon("1".into(), "u1".into()));
        // the show liked v3 subtitles made for OLD, and one here was reported
        let learn = SubLearn {
            liked: vec![("v3".into(), "old".into(), "en".into())],
            bad: [Src::Addon("3".into(), "u3".into()).key()].into_iter().collect(),
            ..Default::default()
        };
        let r = ranked(&en, &pool, &rel, &learn);
        assert_eq!(r.len(), 2);
        // the reported one's copy on the other source goes too
        let copy = SubLearn { bad_names: ["euphoria.us.s01e02.1080p.web.h264-popular".to_owned()].into_iter().collect(), ..Default::default() };
        assert!(ranked(&en, &pool, &rel, &copy).iter().all(|c| c.src != Src::Addon("1".into(), "u1".into())));
        assert_eq!(r[0].src, Src::Addon("2".into(), "u2".into()));
        // the same liked group from another source or language doesn't count
        let learn = SubLearn { liked: vec![("opensubtitles".into(), "old".into(), "en".into()), ("v3".into(), "old".into(), "sr".into())], ..Default::default() };
        assert_eq!(ranked(&en, &pool, &rel, &learn)[0].src, Src::Addon("1".into(), "u1".into()));
        // identity round trip
        for src in [Src::OpenSubtitles(42), Src::Addon("a/b.c".into(), "https://x".into())] {
            assert_eq!(Src::from_json(&src.json()), Some(src.clone()));
        }
        assert_eq!(Src::Addon("a/b.c".into(), "u".into()).key(), "ext:v3-a_b_c.srt");
    }

    /// live: XDG_* pointing at scratch dirs, then cargo test -- --ignored v3_live
    #[test]
    #[ignore]
    fn v3_live() {
        let rel = Release { name: "Euphoria.US.S03E04.2160p.WEB-DL.DDP5.1.H.265-GRP".into(), group: Some("GRP".into()), resolution: 2160, codec: Some("HEVC".into()), fps: 23.976, ..Default::default() };
        let found = crate::app::RUNTIME.block_on(find("tt8772296", Some(3), Some(4), &["en".into(), "balkan".into()], None, &[], &rel, &SubLearn::default())).unwrap();
        for f in &found {
            eprintln!("{} {:.0} {} {}", f.lang, f.score, f.title, f.path);
            assert!(std::fs::metadata(&f.path).unwrap().len() > 1000);
        }
        assert!(found.iter().any(|f| f.lang == "en"));
        assert!(found.iter().any(|f| ["sr", "hr", "bs"].contains(&f.lang.as_str())));
    }
}
