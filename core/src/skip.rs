// smart skip: release chapters first, then introdb, then a guessed outro (port of skip.lua)
use crate::http::{self, Req};
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Segment {
    pub kind: &'static str, // intro | recap | outro
    pub start: f64,
    pub end: f64,
    pub source: &'static str, // chapters | introdb | guess
}

fn classify(title: &str) -> Option<&'static str> {
    let t = title.trim().to_lowercase();
    let word = |w: &str| t == w || t.starts_with(&format!("{w} ")) || (t.starts_with(w) && t[w.len()..].starts_with(|c: char| c.is_ascii_digit()));
    if t.contains("intro") || t.contains("opening") || word("op") {
        Some("intro")
    } else if t.contains("recap") || t.contains("previously") || t.contains("last time") {
        Some("recap")
    } else if t.contains("credits") || t.contains("ending") || t.contains("outro") || word("ed") {
        Some("outro")
    } else {
        None
    }
}

/// chapters: (title, start) in order
pub fn from_chapters(chapters: &[(String, f64)], duration: f64) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    for (i, (title, start)) in chapters.iter().enumerate() {
        let Some(kind) = classify(title) else { continue };
        if out.iter().any(|s| s.kind == kind) {
            continue;
        }
        let end = chapters.get(i + 1).map(|c| c.1).unwrap_or(duration);
        if end > *start {
            out.push(Segment { kind, start: *start, end, source: "chapters" });
        }
    }
    out
}

pub async fn introdb(imdb: &str, season: i64, episode: i64) -> Vec<Segment> {
    let url = format!("https://api.introdb.app/segments?imdb_id={imdb}&season={season}&episode={episode}");
    let Ok(v) = http::cached_json(&format!("introdb:{imdb}:{season}:{episode}"), 7 * 86400, Req::get(url).timeout(6).retries(0)).await
    else {
        return Vec::new();
    };
    ["intro", "recap", "outro"]
        .iter()
        .filter_map(|k| {
            let s = v.get(*k)?;
            let (a, b) = (s.get("start_sec").and_then(Value::as_f64)?, s.get("end_sec").and_then(Value::as_f64)?);
            (b > a).then_some(Segment { kind: k, start: a, end: b, source: "introdb" })
        })
        .collect()
}

/// chapters win per kind; without any outro the last `guess_secs` count as one
pub fn merge(chapters: Vec<Segment>, introdb: Vec<Segment>, duration: f64, guess_secs: f64, episode: bool) -> Vec<Segment> {
    let mut out = chapters;
    for s in introdb {
        if !out.iter().any(|c| c.kind == s.kind) {
            out.push(s);
        }
    }
    if episode && duration > guess_secs * 4.0 && !out.iter().any(|s| s.kind == "outro") {
        out.push(Segment { kind: "outro", start: duration - guess_secs, end: duration, source: "guess" });
    }
    out.sort_by(|a, b| a.start.total_cmp(&b.start));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chapters_and_guess() {
        let ch: Vec<(String, f64)> = [("Previously On", 0.0), ("Opening Credits", 40.0), ("Episode", 90.0), ("End Credits", 170.0)]
            .iter()
            .map(|(t, s)| (t.to_string(), *s))
            .collect();
        let segs = merge(from_chapters(&ch, 180.0), vec![], 180.0, 60.0, true);
        let kinds: Vec<_> = segs.iter().map(|s| (s.kind, s.start, s.end)).collect();
        assert_eq!(kinds, vec![("recap", 0.0, 40.0), ("intro", 40.0, 90.0), ("outro", 170.0, 180.0)]);
        let g = merge(vec![], vec![], 2700.0, 60.0, true);
        assert_eq!((g[0].kind, g[0].start, g[0].source), ("outro", 2640.0, "guess"));
        assert!(merge(vec![], vec![], 7200.0, 60.0, false).is_empty());
        assert_eq!(classify("OP"), Some("intro"));
        assert_eq!(classify("Episode"), None);
    }

    #[test]
    fn introdb_fills_gaps_only() {
        let ch = vec![Segment { kind: "intro", start: 30.0, end: 75.0, source: "chapters" }];
        let idb = vec![
            Segment { kind: "intro", start: 0.0, end: 50.0, source: "introdb" },
            Segment { kind: "recap", start: 0.0, end: 28.0, source: "introdb" },
            Segment { kind: "outro", start: 2500.0, end: 2600.0, source: "introdb" },
        ];
        let m = merge(ch, idb, 2600.0, 60.0, true);
        let got: Vec<_> = m.iter().map(|s| (s.kind, s.source)).collect();
        // sorted by start, chapters keep the intro, no guessed outro next to a real one
        assert_eq!(got, vec![("recap", "introdb"), ("intro", "chapters"), ("outro", "introdb")]);
        // too short to guess an outro
        assert!(merge(vec![], vec![], 200.0, 60.0, true).is_empty());
    }

    #[test]
    fn chapter_names() {
        for (t, k) in [("Opening", Some("intro")), ("OP2", Some("intro")), ("op", Some("intro")), ("Opera", None),
            ("Last time on", Some("recap")), ("ED", Some("outro")), ("Ending Theme", Some("outro")),
            ("Edgar", None), ("Chapter 3", None)]
        {
            assert_eq!(classify(t), k, "{t}");
        }
        // an empty chapter is skipped, the next one of that kind counts
        let ch: Vec<(String, f64)> = [("Intro", 10.0), ("Intro 2", 10.0), ("Part A", 60.0)].iter().map(|(t, s)| (t.to_string(), *s)).collect();
        let s = from_chapters(&ch, 100.0);
        assert_eq!(s.len(), 1);
        assert_eq!((s[0].start, s[0].end), (10.0, 60.0));
    }
}
