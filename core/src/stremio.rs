use crate::config::redact;
use crate::http::{self, Req};
use anyhow::{bail, Context, Result};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Addon {
    /// manifest url (secret: may carry config/tokens)
    pub manifest_url: String,
    pub id: String,
    pub name: String,
    pub version: String,
    pub resources: Vec<String>,
    pub types: Vec<String>,
    pub id_prefixes: Vec<String>,
    pub catalogs: Vec<Value>,
}

impl Addon {
    pub fn base(&self) -> &str {
        self.manifest_url.trim_end_matches("/manifest.json")
    }

    /// streams, catalogs, details or subtitles: something noonix tv uses
    pub fn usable(&self) -> bool {
        self.resources.iter().any(|r| matches!(r.as_str(), "stream" | "catalog" | "meta" | "subtitles"))
    }

    pub fn provides(&self, resource: &str, kind: &str, id: &str) -> bool {
        self.resources.iter().any(|r| r == resource)
            && (self.types.is_empty() || self.types.iter().any(|t| t == kind))
            && (self.id_prefixes.is_empty() || self.id_prefixes.iter().any(|p| id.starts_with(p.as_str())))
    }
}

pub fn check_url(url: &str) -> Result<url::Url> {
    let u = url::Url::parse(url).context("not a valid address")?;
    match u.scheme() {
        "https" => {}
        // only loopback http (our own services)
        "http" if matches!(u.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")) => {}
        _ => bail!("Addon addresses must be https"),
    }
    Ok(u)
}

pub async fn load_manifest(url: &str) -> Result<Addon> {
    let url = url.trim().replace("stremio://", "https://");
    let url = if url.ends_with("manifest.json") { url } else { format!("{}/manifest.json", url.trim_end_matches('/')) };
    check_url(&url)?;
    let m = http::json(&Req::get(&url).timeout(15)).await?;
    let list = |v: Option<&Value>| -> Vec<String> {
        v.and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|r| r.as_str().map(str::to_owned).or_else(|| r.get("name")?.as_str().map(str::to_owned)))
                    .collect()
            })
            .unwrap_or_default()
    };
    let id = m.get("id").and_then(Value::as_str).context("manifest has no id")?.to_owned();
    Ok(Addon {
        manifest_url: url,
        id,
        name: m.get("name").and_then(Value::as_str).unwrap_or("Addon").to_owned(),
        version: m.get("version").and_then(Value::as_str).unwrap_or("").to_owned(),
        resources: list(m.get("resources")),
        types: list(m.get("types")),
        id_prefixes: list(m.get("idPrefixes")),
        catalogs: m.get("catalogs").and_then(Value::as_array).cloned().unwrap_or_default(),
    })
}

async fn resource(addon: &Addon, res: &str, kind: &str, id: &str, timeout: u64) -> Result<Value> {
    let url = format!("{}/{res}/{kind}/{}.json", addon.base(), urlencoding::encode(id));
    http::json(&Req::get(url).timeout(timeout).retries(0))
        .await
        .map_err(|e| anyhow::anyhow!("{}: {}", addon.name, redact(&format!("{e:#}"))))
}

// ---- streams

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Stream {
    pub addon: String,
    pub title: String,
    pub url: Option<String>,
    pub info_hash: Option<String>,
    pub file_idx: Option<i64>,
    /// a torrent's trackers ("tracker:udp://…"), for torrent mode
    #[serde(default)]
    pub sources: Vec<String>,
    /// people sharing a torrent, as the addon tells it
    #[serde(default)]
    pub seeders: Option<u32>,
    /// a file in the library on this pc (url = its path)
    #[serde(default)]
    pub local: bool,
    /// why it may not play well here: "level" (above the picture quality level), "seeders"
    #[serde(default)]
    pub warn: Option<String>,
    /// a release pattern of the user's (or an extension's) it matches: lifted within its tier
    #[serde(default)]
    pub preferred: bool,
    pub headers: Vec<(String, String)>,
    pub filename: Option<String>,
    pub size: Option<u64>,
    pub resolution: u32,
    pub hdr: Vec<String>,
    pub codec: Option<String>,
    pub audio: Vec<String>,
    pub channels: Option<String>,
    pub source: Option<String>,
    pub group: Option<String>,
    pub cached: Option<bool>,
    pub service: Option<String>,
    pub binge_group: Option<String>,
    pub languages: Vec<String>,
    /// embedded subtitle languages the addon or the release name tells ("multi" = many)
    #[serde(default)]
    pub subtitles: Vec<String>,
    /// external subtitles made for this release: preference sets covered, and how many
    #[serde(default)]
    pub ext_subs: (u8, u8),
    pub score: i64,
    /// another title by its name (ranked last, never remembered for the show)
    #[serde(default)]
    pub off_title: bool,
    /// read from the noonix formatter line, not guessed
    #[serde(skip)]
    pub exact: bool,
    /// (addon position in the registry, index in that addon's answer)
    #[serde(skip)]
    pub order: (usize, usize),
}

pub async fn raw_streams(addon: &Addon, kind: &str, id: &str) -> Result<Vec<Value>> {
    let v = resource(addon, "stream", kind, id, 12).await?;
    Ok(v.get("streams").and_then(Value::as_array).cloned().unwrap_or_default())
}

pub async fn streams(addon: &Addon, kind: &str, id: &str) -> Result<Vec<Stream>> {
    Ok(raw_streams(addon, kind, id).await?.iter().filter_map(|s| normalize(&addon.name, s)).collect())
}

pub fn normalize(addon: &str, s: &Value) -> Option<Stream> {
    let url = s.get("url").and_then(Value::as_str).map(str::to_owned);
    let info_hash = s.get("infoHash").and_then(Value::as_str).map(str::to_owned);
    if url.is_none() && info_hash.is_none() {
        return None; // yt / external-only streams are not playable here
    }
    let name = s.get("name").and_then(Value::as_str).unwrap_or("");
    let desc = s.get("description").or(s.get("title")).and_then(Value::as_str).unwrap_or("");
    let hints = s.get("behaviorHints").cloned().unwrap_or(Value::Null);
    let mut filename = hints.get("filename").and_then(Value::as_str).map(str::to_owned);
    let text = fold(&format!("{name}\n{desc}\n{}", filename.as_deref().unwrap_or("")));
    let noonix = desc.lines().find_map(parse_noonix_line);
    let mut st = match &noonix {
        Some(v) => {
            if filename.is_none() {
                filename = v.filename.clone();
            }
            let mut st = v.stream.clone();
            // aiostreams tags miss some flavours the release name carries (atmos, hdr10+)
            let guess = parse_release(&text);
            for a in guess.audio {
                if !st.audio.contains(&a) {
                    st.audio.push(a);
                }
            }
            if st.hdr.is_empty() {
                st.hdr = guess.hdr;
            }
            if st.resolution == 0 {
                st.resolution = guess.resolution;
            }
            if st.subtitles.is_empty() {
                st.subtitles = guess.subtitles;
            }
            st
        }
        None => parse_release(&text),
    };
    st.exact = noonix.is_some();
    st.addon = addon.to_owned();
    st.url = url;
    st.info_hash = info_hash;
    st.file_idx = s.get("fileIdx").and_then(Value::as_i64);
    st.sources = s.get("sources").and_then(Value::as_array).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default();
    st.filename = filename.clone();
    st.title = filename.clone().unwrap_or_else(|| desc.lines().next().unwrap_or(name).trim().to_owned());
    st.size = st.size.or_else(|| hints.get("videoSize").and_then(Value::as_u64)).or_else(|| parse_size(&text));
    st.binge_group = hints.get("bingeGroup").and_then(Value::as_str).map(str::to_owned);
    if let Some(h) = hints.pointer("/proxyHeaders/request").and_then(Value::as_object) {
        st.headers = h.iter().filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_owned()))).collect();
    }
    if noonix.is_none() {
        // formatter markers: ⚡ cached, ⏳ needs download, [TB+] / [TB download], (Instant TB)
        let lower = text.to_lowercase();
        st.cached = if text.contains('⚡') || text.contains("+]") || lower.contains("instant") || lower.contains("⚡ready") {
            Some(true)
        } else if text.contains('⏳') || lower.contains("download]") || lower.contains("not ready") {
            Some(false)
        } else {
            None
        };
        st.service = SERVICE.captures(&text).map(|c| c[1].to_uppercase());
        if st.seeders.is_none() && st.info_hash.is_some() {
            st.seeders = parse_seeders(&text);
        }
        if st.group.is_none() {
            // a group is a short name: not a resolution, a source, or an info hash some addons put there
            st.group = st.binge_group.as_deref().and_then(|b| b.rsplit('|').next()).filter(|g| {
                !g.contains('.') && g.len() <= 24 && !RES.is_match(g) && !matches!(g.to_lowercase().as_str(), "web-dl" | "webrip" | "bluray" | "remux")
            }).map(str::to_owned);
        }
    }
    Some(st)
}

pub struct NoonixLine {
    pub stream: Stream,
    pub filename: Option<String>,
}

/// machine line written by the noonix formatter template (see NOONIX_FORMATTER)
pub fn parse_noonix_line(line: &str) -> Option<NoonixLine> {
    let rest = line.trim().strip_prefix("noonix1|")?;
    let mut s = Stream::default();
    let mut filename = None;
    let list = |v: &str| -> Vec<String> { v.split(',').map(str::trim).filter(|x| !x.is_empty()).map(str::to_owned).collect() };
    // n= is last and may contain anything
    let (fields, name) = match rest.find("|n=") {
        Some(i) => (&rest[..i], Some(&rest[i + 3..])),
        None => (rest, None),
    };
    for kv in fields.split('|') {
        let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
        let v = v.trim();
        match k {
            "r" => s.resolution = v.trim_end_matches(['p', 'P', 'i']).parse().unwrap_or(0),
            "q" => s.source = (!v.is_empty()).then(|| canonical_source(v)),
            "e" => s.codec = (!v.is_empty()).then(|| canonical_codec(v)),
            "v" => s.hdr = list(v).iter().filter_map(|t| canonical_hdr(t)).collect(),
            "a" => s.audio = list(v),
            "c" => s.channels = list(v).into_iter().max_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal)),
            "s" => s.size = v.parse::<f64>().ok().filter(|n| *n > 0.0).map(|n| n as u64),
            "g" => s.group = (!v.is_empty()).then(|| v.to_owned()),
            "sv" => s.service = (!v.is_empty()).then(|| service_short(v)),
            "k" => s.cached = match v { "1" | "true" => Some(true), "0" | "false" => Some(false), _ => None },
            "l" => s.languages = list(v).iter().map(|l| lang_code(l)).collect(),
            "t" => s.subtitles = list(v).iter().map(|l| lang_code(l)).collect(),
            "p" => s.seeders = v.parse().ok(),
            _ => {}
        }
    }
    if let Some(n) = name.map(str::trim).filter(|n| !n.is_empty()) {
        filename = Some(n.to_owned());
    }
    Some(NoonixLine { stream: s, filename })
}

fn canonical_source(q: &str) -> String {
    let l = q.to_lowercase();
    match () {
        _ if l.contains("remux") => "Remux",
        _ if l.contains("bluray") || l.contains("blu-ray") || l.contains("bdrip") => "BluRay",
        _ if l.contains("web-dl") || l.contains("webdl") => "WEB-DL",
        _ if l.contains("webrip") => "WEBRip",
        _ if l.contains("web") => "WEB",
        _ if l.contains("hdtv") => "HDTV",
        _ if l.contains("cam") || l == "ts" || l.contains("telesync") || l.contains("scr") => "CAM",
        _ if l.contains("dvd") => "DVD",
        _ => return q.to_owned(),
    }
    .to_owned()
}

fn canonical_codec(e: &str) -> String {
    match e.to_lowercase().as_str() {
        "hevc" | "x265" | "h265" | "h.265" => "HEVC".into(),
        "avc" | "x264" | "h264" | "h.264" => "AVC".into(),
        "av1" => "AV1".into(),
        _ => e.to_uppercase(),
    }
}

fn canonical_hdr(t: &str) -> Option<String> {
    Some(match t.to_uppercase().as_str() {
        "DV" | "DOVI" => "DV",
        "HDR10+" => "HDR10+",
        "HDR10" | "HDR" => "HDR10",
        "HLG" => "HLG",
        "SDR" => "SDR",
        _ => return None,
    }
    .into())
}

fn service_short(id: &str) -> String {
    match id.to_lowercase().as_str() {
        "torbox" | "tb" => "TB",
        "realdebrid" | "real-debrid" | "rd" => "RD",
        "alldebrid" | "ad" => "AD",
        "premiumize" | "pm" => "PM",
        "debridlink" | "dl" => "DL",
        "easydebrid" | "ed" => "ED",
        "offcloud" | "oc" => "OC",
        "pikpak" => "PKP",
        other => return other.to_uppercase(),
    }
    .into()
}

fn lang_code(l: &str) -> String {
    let l = l.trim().to_lowercase();
    LANGS
        .iter()
        .find(|(code, words)| *code == l || words.contains(&l.as_str()))
        .map(|(c, _)| c.to_string())
        .unwrap_or(if l.contains("multi") || l.contains("dual") { "multi".into() } else { l })
}

/// paste into aiostreams > formatter > custom (name + description); the last description
/// line is what noonix tv reads, the rest stays readable in stremio
pub const NOONIX_FORMATTER_NAME: &str = r#"{stream.resolution::exists["{stream.resolution}"||"?"]}{service.id::exists[" {service.cached["⚡"||"⏳"]}"||""]}"#;
pub const NOONIX_FORMATTER_DESCRIPTION: &str = r#"{?{stream.quality} ?}{?{stream.encode} ?}{?{stream.visualTags::join(' · ')} ?}{?{stream.audioTags::join(' · ')} ?}{?{stream.audioChannels::join(' · ')}?}
{stream.size::>0["{stream.size::sbytes} "||""]}{?[{service.shortName}] ?}{addon.name}{? · {stream.releaseGroup}?}
noonix1|r={stream.resolution}|q={stream.quality}|e={stream.encode}|v={stream.visualTags::join(',')}|a={stream.audioTags::join(',')}|c={stream.audioChannels::join(',')}|s={stream.size}|g={stream.releaseGroup}|sv={service.id}|k={service.id::exists["{service.cached["1"||"0"]}"||""]}|l={stream.languages::join(',')}|t={stream.subtitles::join(',')}|p={stream.seeders}|n={stream.filename}"#;

/// how well an addon's stream text can be read: "noonix" (template), "ok", "unsupported"
pub fn formatting(streams: &[Stream]) -> &'static str {
    if streams.is_empty() {
        return "ok";
    }
    if streams.iter().all(|s| s.exact) {
        return "noonix";
    }
    let known = streams.iter().filter(|s| s.exact || s.resolution > 0).count();
    if known * 2 >= streams.len() {
        "ok"
    } else {
        "unsupported"
    }
}

static RES: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\b(2160|1440|1080|720|576|480)[pi]\b|\b(4k|uhd)\b|\b(2k)\b").unwrap());
static SIZE: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(\d+(?:[.,]\d+)?)\s*(GB|MB|GiB|MiB)\b").unwrap());
static SERVICE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[(TB|RD|AD|PM|DL|ED|OC|PKP)\+?\]").unwrap());
// "👤 123" (the common addon mark), "Seeders: 12", "S: 12"
static SEEDERS: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(?:👤|\bseeders?\b\s*:?|\bseeds?\b\s*:?|\bs:)\s*(\d{1,6})").unwrap());
static GROUP: Lazy<Regex> = Lazy::new(|| Regex::new(r"-([A-Za-z0-9]{2,12})(?:\.[a-z0-9]{2,4})?$").unwrap());

// word-bounded, case-insensitive; compiled once per pattern
fn has(text: &str, pat: &'static str) -> bool {
    static CACHE: Lazy<std::sync::Mutex<std::collections::HashMap<&'static str, Regex>>> = Lazy::new(Default::default);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    cache
        .entry(pat)
        .or_insert_with(|| Regex::new(&format!(r"(?i)(^|[^a-z0-9]){pat}([^a-z0-9]|$)")).expect("pattern"))
        .is_match(text)
}

pub fn parse_seeders(text: &str) -> Option<u32> {
    SEEDERS.captures(text)?[1].parse().ok()
}

pub fn parse_size(text: &str) -> Option<u64> {
    let c = SIZE.captures(text)?;
    let n: f64 = c[1].replace(',', ".").parse().ok()?;
    let mult = if c[2].to_uppercase().starts_with('G') { 1u64 << 30 } else { 1 << 20 };
    Some((n * mult as f64) as u64)
}

pub fn parse_release(text: &str) -> Stream {
    let resolution = RES
        .captures(text)
        .map(|c| match (c.get(1), c.get(3)) {
            (Some(r), _) => r.as_str().parse().unwrap_or(0),
            (None, Some(_)) => 1440,
            _ => 2160,
        })
        .unwrap_or(0);
    let mut s = Stream { resolution, ..Default::default() };
    let mut hdr = Vec::new();
    if has(text, r"(dv|dovi|dolby[ .]?vision)") {
        hdr.push("DV".to_owned());
    }
    if has(text, r"hdr10(\+|plus)") {
        hdr.push("HDR10+".to_owned());
    } else if has(text, r"hdr(10)?") {
        hdr.push("HDR10".to_owned());
    }
    if has(text, "hlg") {
        hdr.push("HLG".to_owned());
    }
    if hdr.is_empty() && has(text, "sdr") {
        hdr.push("SDR".to_owned());
    }
    s.hdr = hdr;
    s.codec = if has(text, r"(hevc|[xh][ .]?265)") {
        Some("HEVC".into())
    } else if has(text, "av1") {
        Some("AV1".into())
    } else if has(text, r"(avc|[xh][ .]?264)") {
        Some("AVC".into())
    } else {
        None
    };
    let mut audio = Vec::new();
    for (pat, name) in [
        ("atmos", "Atmos"),
        ("truehd", "TrueHD"),
        (r"dts[ .-]?(hd|x|ma)", "DTS-HD"),
        ("dts", "DTS"),
        (r"(ddp|dd\+|eac3|e-ac-3)", "DD+"),
        (r"(dd|ac3|dolby digital)", "DD"),
        ("aac", "AAC"),
        ("opus", "Opus"),
        ("flac", "FLAC"),
    ] {
        if has(text, pat) && !(name == "DTS" && audio.iter().any(|a| a == "DTS-HD")) && !(name == "DD" && audio.iter().any(|a| a == "DD+")) {
            audio.push(name.to_owned());
        }
    }
    s.audio = audio;
    s.channels = ["7.1", "5.1", "2.0"].iter().find(|c| text.contains(*c)).map(|c| c.to_string());
    s.source = [
        (r"remux", "Remux"),
        (r"(blu-?ray|bdrip|brrip)", "BluRay"),
        (r"web-?dl", "WEB-DL"),
        (r"web-?rip", "WEBRip"),
        (r"web", "WEB"),
        (r"hdtv", "HDTV"),
        (r"(cam|hdcam|telesync|\bts\b|hdts)", "CAM"),
        (r"(dvdrip|dvd)", "DVD"),
    ]
    .iter()
    .find(|(p, _)| has(text, p))
    .map(|(_, n)| n.to_string());
    let last_line = text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("");
    s.group = GROUP.captures(last_line.trim()).map(|c| c[1].to_owned());
    s.languages = languages(text);
    s.subtitles = subtitle_languages(text);
    s
}

// (code, words that mean it in release names, two-letter form allowed only on a language line)
const LANGS: &[(&str, &[&str])] = &[
    ("en", &["eng", "english"]),
    ("sr", &["srp", "serbian", "srpski"]),
    ("hr", &["hrv", "croatian"]),
    ("bs", &["bos", "bosnian"]),
    ("de", &["ger", "deu", "german"]),
    ("fr", &["fre", "fra", "french", "vff", "truefrench"]),
    ("es", &["spa", "spanish", "latino", "castellano"]),
    ("it", &["ita", "italian"]),
    ("pt", &["por", "portuguese"]),
    ("ru", &["rus", "russian"]),
    ("uk", &["ukr", "ukrainian"]),
    ("pl", &["pol", "polish"]),
    ("hi", &["hin", "hindi"]),
    ("ja", &["jpn", "japanese"]),
    ("ko", &["kor", "korean"]),
    ("zh", &["chi", "chinese", "mandarin"]),
    ("tr", &["tur", "turkish"]),
    ("cs", &["cze", "ces", "czech"]),
    ("hu", &["hun", "hungarian"]),
    ("nl", &["dut", "nld", "dutch"]),
    ("sv", &["swe", "swedish"]),
    ("da", &["danish"]),
    ("no", &["nor", "norwegian"]),
    ("fi", &["finnish"]),
    ("el", &["gre", "ell", "greek"]),
    ("ro", &["romanian"]),
    ("bg", &["bul", "bulgarian"]),
    ("sl", &["slv", "slovenian"]),
    ("mk", &["mkd", "macedonian"]),
    ("lt", &["lithuanian"]),
    ("ar", &["ara", "arabic"]),
    ("he", &["heb", "hebrew"]),
    ("th", &["tha", "thai"]),
    ("vi", &["vietnamese"]),
];

pub const LANGUAGE_NAMES: &[(&str, &str)] = &[
    ("en", "English"), ("sr", "Serbian"), ("hr", "Croatian"), ("bs", "Bosnian"), ("de", "German"), ("fr", "French"),
    ("es", "Spanish"), ("it", "Italian"), ("pt", "Portuguese"), ("ru", "Russian"), ("uk", "Ukrainian"), ("pl", "Polish"),
    ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"), ("tr", "Turkish"), ("cs", "Czech"),
    ("hu", "Hungarian"), ("nl", "Dutch"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"),
    ("el", "Greek"), ("ro", "Romanian"), ("bg", "Bulgarian"), ("sl", "Slovenian"), ("mk", "Macedonian"),
    ("lt", "Lithuanian"), ("ar", "Arabic"), ("he", "Hebrew"), ("th", "Thai"), ("vi", "Vietnamese"),
];

/// track language tags mpv may see for a code: 639-2 first, then 639-1, then old ones
pub fn iso639_tags(code: &str) -> Vec<String> {
    let three = LANGS.iter().find(|(c, _)| *c == code).and_then(|(_, w)| w.iter().find(|x| x.len() == 3)).copied();
    let mut out: Vec<String> = three.into_iter().map(str::to_owned).collect();
    out.push(code.to_owned());
    match code {
        "sr" => out.push("scc".into()),
        "hr" => out.push("scr".into()),
        "zh" => out.push("zho".into()),
        "de" => out.push("deu".into()),
        "fr" => out.push("fra".into()),
        _ => {}
    }
    out
}

/// small caps / sub / superscript letters and digits -> ascii, so decorated text parses
pub fn fold(text: &str) -> String {
    const MAP: &[(char, char)] = &[
        ('ᴀ', 'a'), ('ʙ', 'b'), ('ᴄ', 'c'), ('ᴅ', 'd'), ('ᴇ', 'e'), ('ғ', 'f'), ('ɢ', 'g'), ('ʜ', 'h'),
        ('ɪ', 'i'), ('ᴊ', 'j'), ('ᴋ', 'k'), ('ʟ', 'l'), ('ᴍ', 'm'), ('ɴ', 'n'), ('ᴏ', 'o'), ('ᴘ', 'p'),
        ('ǫ', 'q'), ('ʀ', 'r'), ('ꜱ', 's'), ('ᴛ', 't'), ('ᴜ', 'u'), ('ᴠ', 'v'), ('ᴡ', 'w'), ('ʏ', 'y'),
        ('ᴢ', 'z'), ('₀', '0'), ('₁', '1'), ('₂', '2'), ('₃', '3'), ('₄', '4'), ('₅', '5'), ('₆', '6'),
        ('₇', '7'), ('₈', '8'), ('₉', '9'), ('⁰', '0'), ('¹', '1'), ('²', '2'), ('³', '3'), ('⁴', '4'),
        ('⁵', '5'), ('⁶', '6'), ('⁷', '7'), ('⁸', '8'), ('⁹', '9'), ('ᵃ', 'a'), ('ᵇ', 'b'), ('ᶜ', 'c'),
        ('ᵈ', 'd'), ('ᵉ', 'e'), ('ᶠ', 'f'), ('ᵍ', 'g'), ('ʰ', 'h'), ('ⁱ', 'i'), ('ʲ', 'j'), ('ᵏ', 'k'),
        ('ˡ', 'l'), ('ᵐ', 'm'), ('ⁿ', 'n'), ('ᵒ', 'o'), ('ᵖ', 'p'), ('ʳ', 'r'), ('ˢ', 's'), ('ᵗ', 't'),
        ('ᵘ', 'u'), ('ᵛ', 'v'), ('ʷ', 'w'), ('ˣ', 'x'), ('ʸ', 'y'), ('ᶻ', 'z'), ('ᴹ', 'M'), ('ᴷ', 'K'),
        ('\u{a0}', ' '),
    ];
    text.chars()
        .filter(|c| !matches!(c, '\u{200b}'..='\u{200f}' | '\u{2060}' | '\u{feff}'))
        .map(|c| MAP.iter().find(|(k, _)| *k == c).map(|(_, v)| *v).unwrap_or(c))
        .collect()
}

/// embedded subtitle languages: a formatter's "sub (en · fr)" part, and release name markers
/// (esub = english, msubs / multi-sub = many)
pub fn subtitle_languages(text: &str) -> Vec<String> {
    let folded = fold(text).to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut add = |code: &str| {
        if !out.iter().any(|c| c == code) {
            out.push(code.to_owned());
        }
    };
    for line in folded.lines() {
        let line = line.trim();
        let lang_line = line.starts_with('✓') || line.starts_with('🌎') || line.starts_with('🗣') || line.starts_with('🌐') || line.starts_with('💬');
        let words: Vec<&str> = line.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
        for (i, w) in words.iter().enumerate() {
            match *w {
                "esub" | "esubs" => add("en"),
                "msub" | "msubs" | "multisub" | "multisubs" => add("multi"),
                "sub" | "subs" if i > 0 && words[i - 1] == "multi" => add("multi"),
                _ => {}
            }
        }
        if !lang_line {
            continue;
        }
        let Some((_, subs)) = line.split_once(" sub") else { continue };
        for word in subs.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
            for (code, names) in LANGS {
                if names.contains(&word) || word == *code {
                    add(code);
                }
            }
        }
    }
    out
}

/// audio languages; subtitle-only mentions don't count
pub fn languages(text: &str) -> Vec<String> {
    let folded = fold(text).to_lowercase();
    let mut out: Vec<String> = Vec::new();
    let mut add = |code: &str| {
        if !out.iter().any(|c| c == code) {
            out.push(code.to_owned());
        }
    };
    for line in folded.lines() {
        let line = line.trim();
        // formatter language lines: "✓ en · sub (en)", "🌎 english | italian", "🗣️ 🇬🇧 / 🇮🇹"
        let lang_line = line.starts_with('✓') || line.starts_with('🌎') || line.starts_with('🗣') || line.starts_with('🌐');
        let audio_part = line.split(" sub").next().unwrap_or(line);
        for word in audio_part.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
            if word == "multi" || word == "dual" {
                add("multi");
            }
            for (code, words) in LANGS {
                if words.contains(&word) || (lang_line && word == *code) {
                    add(code);
                }
            }
        }
        for (flag, code) in [("🇬🇧", "en"), ("🇺🇸", "en"), ("🇷🇸", "sr"), ("🇭🇷", "hr"), ("🇧🇦", "bs"), ("🇩🇪", "de"), ("🇫🇷", "fr"), ("🇪🇸", "es"), ("🇮🇹", "it"), ("🇷🇺", "ru")] {
            if lang_line && audio_part.contains(flag) {
                add(code);
            }
        }
    }
    out
}

// ---- catalogs / meta / subtitles

pub async fn catalog(addon: &Addon, kind: &str, id: &str, extra: &[(&str, &str)]) -> Result<Vec<Value>> {
    let mut path = id.to_owned();
    if !extra.is_empty() {
        let e: Vec<String> = extra.iter().map(|(k, v)| format!("{k}={}", urlencoding::encode(v))).collect();
        path = format!("{id}/{}", e.join("&"));
    }
    let url = format!("{}/catalog/{kind}/{path}.json", addon.base());
    let v = http::cached_json(&format!("addon:{}:{kind}:{path}", addon.id), 3600, Req::get(url).timeout(15)).await?;
    Ok(v.get("metas").and_then(Value::as_array).cloned().unwrap_or_default())
}

pub async fn meta(addon: &Addon, kind: &str, id: &str) -> Result<Value> {
    let v = resource(addon, "meta", kind, id, 15).await?;
    v.get("meta").cloned().context("no meta")
}

pub async fn subtitles(addon: &Addon, kind: &str, id: &str, extra: &[(&str, String)]) -> Result<Vec<Value>> {
    let mut path = id.to_owned();
    if !extra.is_empty() {
        let e: Vec<String> = extra.iter().map(|(k, v)| format!("{k}={}", urlencoding::encode(v))).collect();
        path = format!("{id}/{}", e.join("&"));
    }
    let url = format!("{}/subtitles/{kind}/{path}.json", addon.base());
    let v = http::json(&Req::get(url).timeout(10).retries(0)).await?;
    Ok(v.get("subtitles")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|s| {
                    Some(json!({
                        "url": s.get("url")?.as_str()?,
                        "lang": s.get("lang").and_then(Value::as_str).unwrap_or("und"),
                        "id": s.get("id"),
                        "addon": addon.name,
                    }))
                })
                .collect()
        })
        .unwrap_or_default())
}

/// stremio video id: tt123 for movies, tt123:s:e for episodes
pub fn video_id(imdb: &str, season: Option<i64>, episode: Option<i64>) -> String {
    match (season, episode) {
        (Some(s), Some(e)) => format!("{imdb}:{s}:{e}"),
        _ => imdb.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hash_is_no_group() {
        let v = json!({
            "name": "[P2P] Example unknown",
            "description": "📄 Sintel [H264 - Eng - Multisubs]\n💾 463 MB",
            "infoHash": "a41915eaabbf8d37ff5f96c0db70a289d1b0c3d2",
            "behaviorHints": { "bingeGroup": "example|a41915eaabbf8d37ff5f96c0db70a289d1b0c3d2" }
        });
        assert_eq!(normalize("Example", &v).unwrap().group, None);
        let v = json!({ "name": "x", "url": "https://example.invalid/x", "behaviorHints": { "bingeGroup": "addon|1080p|GRP" } });
        assert_eq!(normalize("Addon", &v).unwrap().group.as_deref(), Some("GRP"));
    }

    #[test]
    fn parses_aiostreams_fancy_stream() {
        let v = json!({
            "name": "1080P\u{200d}\u{200d}\u{a0}⚡\n〈Webrip〉",
            "description": "✎ Sintel\n▣  HEVC ✧ 10bit  ♬ DD+  ♯ 2.0\n◈ 1.13 GB · 3.42 ᴹᵇᵖˢ\n⛉ [TB] Example · GRP",
            "url": "https://example.invalid/x",
            "behaviorHints": {
                "bingeGroup": "aiostreams|1080p|WEBRip|GRP",
                "videoSize": 1134216346u64,
                "filename": "Sintel.2010.EAC3.2.0.1080p.WEBRip.10bit.x265-GRP.mkv"
            }
        });
        let s = normalize("AIOStreams", &v).unwrap();
        assert_eq!(s.resolution, 1080);
        assert_eq!(s.codec.as_deref(), Some("HEVC"));
        assert_eq!(s.source.as_deref(), Some("WEBRip"));
        assert_eq!(s.cached, Some(true));
        assert_eq!(s.service.as_deref(), Some("TB"));
        assert_eq!(s.group.as_deref(), Some("GRP"));
        assert!(s.audio.contains(&"DD+".to_owned()));
        assert_eq!(s.size, Some(1134216346));
    }

    #[test]
    fn parses_hdr_flavours() {
        let s = parse_release("Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR10.HEVC.TrueHD.Atmos.7.1-GRP");
        assert_eq!(s.resolution, 2160);
        assert_eq!(s.hdr, vec!["DV", "HDR10"]);
        assert_eq!(s.source.as_deref(), Some("Remux"));
        assert!(s.audio.contains(&"Atmos".to_owned()) && s.audio.contains(&"TrueHD".to_owned()));
        let s = parse_release("Show.S01E01.2160p.WEB-DL.DV.H.265-GRP");
        assert_eq!(s.hdr, vec!["DV"]);
        assert_eq!(s.codec.as_deref(), Some("HEVC"));
    }

    #[test]
    fn reads_noonix_formatter_line() {
        let v = json!({
            "name": "2160p ⚡",
            "description": "BluRay REMUX HEVC DV · HDR10\n91.7 GB [TB] Example · GRP\nnoonix1|r=2160p|q=BluRay REMUX|e=HEVC|v=DV,HDR10|a=TrueHD,DD|c=7.1,5.1|s=91668707421|g=GRP|sv=torbox|k=1|l=English,Latino,Czech|t=English,Serbian|n=Tears.of.Steel.2012.2160p.BluRay.Remux.DV.HDR.HEVC.Atmos-GRP.mkv",
            "url": "https://example.invalid/x"
        });
        let s = normalize("AIOStreams", &v).unwrap();
        assert!(s.exact);
        assert_eq!((s.resolution, s.codec.as_deref(), s.source.as_deref()), (2160, Some("HEVC"), Some("Remux")));
        assert_eq!(s.hdr, vec!["DV", "HDR10"]);
        assert_eq!((s.cached, s.service.as_deref(), s.group.as_deref()), (Some(true), Some("TB"), Some("GRP")));
        assert_eq!(s.channels.as_deref(), Some("7.1"));
        assert_eq!(s.languages, vec!["en", "es", "cs"]);
        assert_eq!(s.subtitles, vec!["en", "sr"]);
        assert!(s.audio.contains(&"Atmos".to_owned()));
        assert_eq!(s.filename.as_deref(), Some("Tears.of.Steel.2012.2160p.BluRay.Remux.DV.HDR.HEVC.Atmos-GRP.mkv"));
        assert_eq!(formatting(&[s]), "noonix");
    }

    #[test]
    fn languages_from_lines_and_names() {
        assert_eq!(languages("✓ ᴇɴ · sᴜʙ (ᴇɴ · ғʀ)"), vec!["en"]);
        assert_eq!(languages("Movie.2024.1080p.WEB-DL.ITA.ENG.x264-GRP"), vec!["it", "en"]);
        assert!(languages("It.2017.1080p.BluRay.x264").is_empty());
        assert_eq!(languages("Film.MULTi.1080p"), vec!["multi"]);
        assert_eq!(subtitle_languages("✓ ᴇɴ · sᴜʙ (ᴇɴ · ғʀ)"), vec!["en", "fr"]);
        assert_eq!(subtitle_languages("Show.S01E01.1080p.WEB.x264.ESub-GRP"), vec!["en"]);
        assert_eq!(subtitle_languages("Film.2020.1080p.BluRay.Multi-Subs.x265"), vec!["multi"]);
        assert!(subtitle_languages("Film.2020.1080p.BluRay.Subbed.x265").is_empty());
    }

    /// a tiny stremio addon on loopback: answers by path, records what was asked
    async fn mock_addon(routes: Vec<(&'static str, serde_json::Value)>) -> (String, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req.split_whitespace().nth(1).unwrap_or("").to_owned();
                log.lock().unwrap().push(path.clone());
                let (status, body) = match routes.iter().find(|(p, _)| *p == path) {
                    Some((_, b)) => ("200 OK", b.to_string()),
                    None => ("404 Not Found", "{}".to_owned()),
                };
                let res = format!("HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                let _ = sock.write_all(res.as_bytes()).await;
            }
        });
        (base, seen)
    }

    #[tokio::test]
    async fn addon_contract() {
        let manifest = json!({ "id": "org.mock", "name": "Mock", "version": "1.2.3",
            "resources": ["stream", { "name": "meta", "types": ["series"] }], "types": ["movie", "series"], "idPrefixes": ["tt"] });
        let answer = json!({ "streams": [
            { "name": "Mock 4K", "title": "Show.S01E02.2160p.WEB-DL.DDP5.1.H.265-GRP",
              "url": "https://cdn.example/a.mkv",
              "behaviorHints": { "filename": "Show.S01E02.2160p.WEB-DL.DDP5.1.H.265-GRP.mkv", "videoSize": 13207024435u64, "bingeGroup": "mock|2160p" } },
            { "name": "Mock 1080p", "title": "Show.S01E02.1080p.WEB-DL.x264-GRP", "infoHash": "0123456789abcdef0123456789abcdef01234567", "fileIdx": 3 },
        ] });
        let (base, seen) = mock_addon(vec![("/manifest.json", manifest), ("/stream/series/tt0000001%3A1%3A2.json", answer)]).await;

        // a bare base address gets /manifest.json
        let addon = load_manifest(&format!("{base}/")).await.unwrap();
        assert_eq!((addon.id.as_str(), addon.name.as_str(), addon.version.as_str()), ("org.mock", "Mock", "1.2.3"));
        assert_eq!(addon.resources, vec!["stream", "meta"]);
        assert!(addon.usable());
        // a stream-only addon is enough, a manifest of nothing isn't
        let only = |r: &[&str]| Addon { resources: r.iter().map(|s| s.to_string()).collect(), ..addon.clone() };
        assert!(only(&["stream"]).usable());
        assert!(!only(&["addon_catalog"]).usable());
        assert!(addon.provides("stream", "series", "tt0000001:1:2"));
        assert!(!addon.provides("stream", "series", "kitsu:1"));
        assert!(!addon.provides("subtitles", "movie", "tt1"));

        // the id is path-encoded like stremio does
        let got = streams(&addon, "series", "tt0000001:1:2").await.unwrap();
        assert_eq!(seen.lock().unwrap().last().map(String::as_str), Some("/stream/series/tt0000001%3A1%3A2.json"));
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].resolution, 2160);
        assert_eq!(got[0].size, Some(13207024435));
        assert_eq!(got[0].binge_group.as_deref(), Some("mock|2160p"));
        assert_eq!(got[0].url.as_deref(), Some("https://cdn.example/a.mkv"));
        assert_eq!(got[1].resolution, 1080);
        assert_eq!((got[1].info_hash.as_deref(), got[1].file_idx), (Some("0123456789abcdef0123456789abcdef01234567"), Some(3)));

        // an addon that doesn't know the title: an error, not a panic
        assert!(streams(&addon, "movie", "tt9").await.is_err());
        // plain http only on loopback; nothing is fetched
        assert!(load_manifest("http://example.com/manifest.json").await.is_err());
    }
}
