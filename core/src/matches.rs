// how well a release and its subtitles matched, as the viewers judged it. "good" (said so, or
// watched to the end) lifts the release group for the show and the subtitles made the same way
// for the next episodes; a report sinks the release (picture / sound) or the subtitle (out of
// sync, wrong) for this title. timing set by hand is kept per release + subtitle. install-wide:
// it's about files, not taste
use crate::store;
use crate::stremio::Stream;
use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

pub const GOOD: i64 = 2;
pub const WATCHED: i64 = 1;
pub const BAD: i64 = -1;

/// a subtitle as it plays: an embedded track or an added file
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Sub {
    /// emb:<lang>:<title>:<codec> | ext:<file name>
    pub key: String,
    pub lang: String,
    /// the release it was made for (external) or the track's title
    pub name: String,
    /// embedded | opensubtitles | v3
    pub provider: String,
    /// external: how to get the file again
    #[serde(default)]
    pub src: Option<Value>,
}

impl Sub {
    pub fn embedded(lang: &str, title: &str, codec: &str) -> Sub {
        Sub {
            key: format!("emb:{}:{}:{}", lang.to_lowercase(), title.to_lowercase(), codec),
            lang: lang.to_owned(),
            name: title.to_owned(),
            provider: "embedded".into(),
            src: None,
        }
    }
    pub fn is_embedded(&self) -> bool {
        self.key.starts_with("emb:")
    }
}

/// the release side of a match
#[derive(Debug, Clone, Default)]
pub struct Rel {
    /// movie:<tmdb> | ep:<show>:<s>:<e>
    pub title: String,
    pub show: Option<i64>,
    pub file: String,
    pub group: Option<String>,
}

pub fn file_key(s: &Stream) -> String {
    s.filename.as_deref().unwrap_or(&s.title).trim().to_lowercase()
}

pub fn rel_of(title: &str, show: Option<i64>, s: &Stream) -> Rel {
    Rel { title: title.to_owned(), show, file: file_key(s), group: s.group.clone().map(|g| g.to_lowercase()) }
}

/// the group a subtitle was made for, as its release name writes it ("GRP")
pub fn sub_group_name(name: &str) -> Option<String> {
    let n = name.trim().trim_end_matches(".srt").trim_end_matches(".ass");
    crate::stremio::parse_release(n).group.filter(|g| g.len() > 1)
}

/// the same, lowercased for matching
pub fn sub_group(name: &str) -> Option<String> {
    sub_group_name(name).map(|g| g.to_lowercase())
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Mark {
    pub verdict: i64,
    pub reason: Option<String>,
    pub offset_ms: Option<i64>,
}

pub fn get(c: &Connection, rel: &Rel, sub: &str) -> Result<Option<Mark>> {
    Ok(c.query_row(
        "select verdict, reason, offset_ms from match_marks where title = ?1 and release = ?2 and sub = ?3",
        params![rel.title, rel.file, sub],
        |r| Ok(Mark { verdict: r.get(0)?, reason: r.get(1)?, offset_ms: r.get(2)? }),
    )
    .optional()?)
}

/// sets the verdict (and why) of the release alone (sub None) or of the pair
pub fn judge(c: &Connection, rel: &Rel, sub: Option<&Sub>, verdict: i64, reason: Option<&str>) -> Result<()> {
    let s = sub.cloned().unwrap_or_default();
    c.execute(
        "insert into match_marks (title, show, release, release_group, sub, sub_lang, sub_name, provider, sub_src, verdict, reason, updated)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         on conflict(title, release, sub) do update set verdict = excluded.verdict, reason = excluded.reason,
           sub_src = coalesce(excluded.sub_src, sub_src), updated = excluded.updated",
        params![
            rel.title, rel.show, rel.file, rel.group, s.key, none_if_empty(&s.lang), none_if_empty(&s.name),
            none_if_empty(&s.provider), s.src.as_ref().map(Value::to_string), verdict, reason, store::now()
        ],
    )?;
    Ok(())
}

/// watched to the end: a quiet "good" that never overrides what someone said
pub fn watched(c: &Connection, rel: &Rel, sub: Option<&Sub>) -> Result<()> {
    let quiet = |s: Option<&Sub>| -> Result<()> {
        if get(c, rel, s.map_or("", |x| x.key.as_str()))?.is_none_or(|m| m.verdict == 0) {
            judge(c, rel, s, WATCHED, None)?;
        }
        Ok(())
    };
    quiet(None)?;
    if sub.is_some() {
        quiet(sub)?;
    }
    Ok(())
}

/// timing set by hand: kept with the pair, and a sync report on it is settled
pub fn set_offset(c: &Connection, rel: &Rel, sub: &Sub, ms: i64) -> Result<()> {
    c.execute(
        "insert into match_marks (title, show, release, release_group, sub, sub_lang, sub_name, provider, sub_src, verdict, offset_ms, updated)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10, ?11)
         on conflict(title, release, sub) do update set offset_ms = excluded.offset_ms, updated = excluded.updated,
           verdict = case when reason = 'sync' then 0 else verdict end,
           reason = case when reason = 'sync' then null else reason end",
        params![
            rel.title, rel.show, rel.file, rel.group, sub.key, none_if_empty(&sub.lang), none_if_empty(&sub.name),
            none_if_empty(&sub.provider), sub.src.as_ref().map(Value::to_string), ms, store::now()
        ],
    )?;
    Ok(())
}

fn none_if_empty(s: &str) -> Option<&str> {
    (!s.is_empty()).then_some(s)
}

/// what the ranking learns: this title's good and reported files, the show's good groups
#[derive(Debug, Clone, Default)]
pub struct Learned {
    pub good_files: HashSet<String>,
    pub bad_files: HashSet<String>,
    pub good_groups: HashSet<String>,
}

pub fn learned(c: &Connection, title: &str, show: Option<i64>) -> Result<Learned> {
    let mut l = Learned::default();
    let mut st = c.prepare("select release, verdict from match_marks where title = ?1 and sub = ''")?;
    for row in st.query_map(params![title], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
        let (file, v) = row?;
        if v > 0 {
            l.good_files.insert(file);
        } else if v < 0 {
            l.bad_files.insert(file);
        }
    }
    // a group the show liked, unless its last word there was a picture / sound report
    let mut st = c.prepare(
        "select release_group, verdict from match_marks
         where (show = ?1 or title = ?2) and sub = '' and release_group is not null order by updated",
    )?;
    let mut last = std::collections::HashMap::new();
    for row in st.query_map(params![show, title], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))? {
        let (g, v) = row?;
        if v != 0 {
            last.insert(g, v);
        }
    }
    l.good_groups = last.into_iter().filter(|(_, v)| *v > 0).map(|(g, _)| g).collect();
    Ok(l)
}

/// what subtitle picking learns for one release
#[derive(Debug, Clone, Default)]
pub struct SubLearn {
    /// this file's best liked subtitle per language (said good beats watched)
    pub exact: Vec<Sub>,
    /// reported: wrong (another episode, language) for the whole title, out of sync only for
    /// this release (it may fit another one)
    pub bad: HashSet<String>,
    /// what those were made for (lowercased): the same subtitle often sits on both sources
    pub bad_names: HashSet<String>,
    /// embedded tracks reported on this file or on the show's releases of the same group
    pub avoid_embedded: HashSet<String>,
    /// (provider, group the subtitle was made for, lang) the show liked
    pub liked: Vec<(String, String, String)>,
}

pub fn sub_learn(c: &Connection, rel: &Rel) -> Result<SubLearn> {
    let mut l = SubLearn::default();
    let mut st = c.prepare(
        "select sub, sub_lang, sub_name, provider, sub_src, verdict from match_marks
         where title = ?1 and release = ?2 and sub != '' order by verdict desc, updated desc",
    )?;
    let mut langs = HashSet::new();
    for row in st.query_map(params![rel.title, rel.file], sub_row)? {
        let (s, v) = row?;
        if v > 0 && langs.insert(s.lang.clone()) {
            l.exact.push(s);
        }
    }
    let mut st = c.prepare(
        "select sub, sub_name from match_marks where title = ?1 and sub != '' and verdict < 0
         and (reason is not 'sync' or release = ?2)",
    )?;
    for row in st.query_map(params![rel.title, rel.file], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?)))? {
        let (key, name) = row?;
        if let (true, Some(n)) = (key.starts_with("ext:"), name) {
            l.bad_names.insert(n.to_lowercase());
        }
        l.bad.insert(key);
    }
    let mut st = c.prepare(
        "select sub from match_marks where sub like 'emb:%' and verdict < 0
         and ((title = ?1 and release = ?2) or (show = ?3 and release_group = ?4))",
    )?;
    for row in st.query_map(params![rel.title, rel.file, rel.show, rel.group], |r| r.get::<_, String>(0))? {
        l.avoid_embedded.insert(row?);
    }
    if rel.show.is_some() {
        let mut st = c.prepare(
            "select sub, sub_lang, sub_name, provider, sub_src, verdict from match_marks
             where show = ?1 and sub like 'ext:%' and verdict > 0 order by verdict desc, updated desc",
        )?;
        for row in st.query_map(params![rel.show], sub_row)? {
            let (s, _) = row?;
            if let Some(g) = sub_group(&s.name) {
                let t = (s.provider.clone(), g, s.lang.clone());
                if !l.liked.contains(&t) {
                    l.liked.push(t);
                }
            }
        }
    }
    Ok(l)
}

fn sub_row(r: &rusqlite::Row) -> rusqlite::Result<(Sub, i64)> {
    let src: Option<String> = r.get(4)?;
    Ok((
        Sub {
            key: r.get(0)?,
            lang: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
            name: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            provider: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            src: src.and_then(|s| serde_json::from_str(&s).ok()),
        },
        r.get(5)?,
    ))
}

/// the timing for a subtitle on this release: set here, or the same pairing on another episode
/// (same release group, same subtitle source made for the same group). (ms, from where)
pub fn offset_for(c: &Connection, rel: &Rel, sub: &Sub) -> Result<Option<(i64, Option<String>)>> {
    if let Some(m) = get(c, rel, &sub.key)? {
        if let Some(ms) = m.offset_ms {
            return Ok(Some((ms, None)));
        }
        // a sync report without a fix: no guessing on top of it
        if m.verdict != 0 {
            return Ok(None);
        }
    }
    let (Some(show), Some(group)) = (rel.show, rel.group.as_deref()) else { return Ok(None) };
    let sub_g = sub_group(&sub.name);
    let mut st = c.prepare(
        "select title, sub_name, offset_ms from match_marks
         where show = ?1 and release_group = ?2 and provider = ?3 and sub_lang = ?4 and offset_ms is not null and title != ?5
         order by updated desc",
    )?;
    let rows = st.query_map(params![show, group, sub.provider, sub.lang, rel.title], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, i64>(2)?))
    })?;
    for row in rows {
        let (title, name, ms) = row?;
        let same = sub.is_embedded() || (sub_g.is_some() && name.as_deref().and_then(sub_group) == sub_g);
        if same {
            return Ok(Some((ms, Some(title))));
        }
    }
    Ok(None)
}

/// "S1 · E2" from an episode key
pub fn episode_label(title: &str) -> Option<String> {
    let p: Vec<&str> = title.split(':').collect();
    (p.len() == 4 && p[0] == "ep").then(|| format!("S{} · E{}", p[2], p[3]))
}

pub fn state_json(m: Option<Mark>) -> Value {
    match m {
        Some(m) => json!({ "verdict": m.verdict, "reason": m.reason, "offsetMs": m.offset_ms }),
        None => json!({ "verdict": 0 }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(title: &str, file: &str, group: &str) -> Rel {
        Rel { title: title.into(), show: Some(85552), file: file.into(), group: Some(group.into()) }
    }

    fn ext(id: &str, name: &str, lang: &str) -> Sub {
        Sub { key: format!("ext:v3-{id}.srt"), lang: lang.into(), name: name.into(), provider: "v3".into(), src: Some(json!({ "v3": id, "url": format!("https://x/{id}") })) }
    }

    #[test]
    fn good_and_bad_reach_the_ranking() {
        let c = store::open_memory().unwrap();
        let e1 = rel("ep:85552:1:1", "euphoria.s01e01.1080p.web.h264-grp.mkv", "grp");
        let other = rel("ep:85552:1:1", "euphoria.s01e01.2160p.web.h265-other.mkv", "other");
        judge(&c, &e1, None, GOOD, None).unwrap();
        judge(&c, &other, None, BAD, Some("av")).unwrap();
        let l = learned(&c, "ep:85552:1:1", Some(85552)).unwrap();
        assert!(l.good_files.contains(&e1.file) && l.bad_files.contains(&other.file));
        assert!(l.good_groups.contains("grp") && !l.good_groups.contains("other"));
        // the next episode knows the group, not the files
        let l2 = learned(&c, "ep:85552:1:2", Some(85552)).unwrap();
        assert!(l2.good_files.is_empty() && l2.good_groups.contains("grp"));
        // a later picture report on the group's release takes the lift away
        let e2 = rel("ep:85552:1:2", "euphoria.s01e02.1080p.web.h264-grp.mkv", "grp");
        std::thread::sleep(std::time::Duration::from_millis(1100));
        judge(&c, &e2, None, BAD, Some("av")).unwrap();
        assert!(!learned(&c, "ep:85552:1:3", Some(85552)).unwrap().good_groups.contains("grp"));
    }

    #[test]
    fn watched_never_overrides_a_report() {
        let c = store::open_memory().unwrap();
        let e1 = rel("ep:1:1:1", "a-grp.mkv", "grp");
        let s = ext("7", "Show.S01E01.1080p.WEB.H264-GRP", "en");
        judge(&c, &e1, Some(&s), BAD, Some("wrong")).unwrap();
        watched(&c, &e1, Some(&s)).unwrap();
        assert_eq!(get(&c, &e1, &s.key).unwrap().unwrap().verdict, BAD);
        assert_eq!(get(&c, &e1, "").unwrap().unwrap().verdict, WATCHED);
        judge(&c, &e1, None, GOOD, None).unwrap();
        watched(&c, &e1, None).unwrap();
        assert_eq!(get(&c, &e1, "").unwrap().unwrap().verdict, GOOD);
    }

    #[test]
    fn subtitles_learn_per_file_and_per_show() {
        let c = store::open_memory().unwrap();
        let e1 = rel("ep:85552:1:1", "e1-grp.mkv", "grp");
        let good = ext("11", "Euphoria.US.S01E01.1080p.WEB.H264-GRP", "en");
        let wrong = ext("12", "Euphoria.US.S01E01.720p.HDTV.x264-OLD", "en");
        judge(&c, &e1, Some(&good), GOOD, None).unwrap();
        judge(&c, &e1, Some(&wrong), BAD, Some("wrong")).unwrap();
        let emb = Sub::embedded("eng", "English", "subrip");
        judge(&c, &e1, Some(&emb), BAD, Some("sync")).unwrap();
        let l = sub_learn(&c, &e1).unwrap();
        assert_eq!(l.exact, vec![good.clone()]);
        assert!(l.bad.contains(&wrong.key) && l.bad.contains(&emb.key));
        assert!(l.bad_names.contains("euphoria.us.s01e01.720p.hdtv.x264-old") && l.bad_names.len() == 1);
        assert!(l.avoid_embedded.contains(&emb.key));
        assert_eq!(l.liked, vec![("v3".to_owned(), "grp".to_owned(), "en".to_owned())]);
        // another release of the same episode: the wrong one stays out, the out of sync one may fit
        let e1b = rel("ep:85552:1:1", "e1-other.mkv", "other");
        let sync = ext("13", "Euphoria.US.S01E01.1080p.WEB.H264-METCON", "en");
        judge(&c, &e1, Some(&sync), BAD, Some("sync")).unwrap();
        let lb = sub_learn(&c, &e1b).unwrap();
        assert!(lb.bad.contains(&wrong.key) && !lb.bad.contains(&sync.key));
        assert!(sub_learn(&c, &e1).unwrap().bad.contains(&sync.key));
        // episode 2 of the same group: the embedded track is avoided too, the liked pattern carries
        let e2 = rel("ep:85552:1:2", "e2-grp.mkv", "grp");
        let l2 = sub_learn(&c, &e2).unwrap();
        assert!(l2.exact.is_empty() && l2.bad.is_empty());
        assert!(l2.avoid_embedded.contains(&emb.key));
        assert_eq!(l2.liked.len(), 1);
        // another group keeps its embedded track
        let e2b = rel("ep:85552:1:2", "e2-other.mkv", "other");
        assert!(sub_learn(&c, &e2b).unwrap().avoid_embedded.is_empty());
    }

    #[test]
    fn offsets_follow_the_same_pairing() {
        let c = store::open_memory().unwrap();
        let e1 = rel("ep:85552:1:1", "e1-grp.mkv", "grp");
        let s1 = ext("21", "Euphoria.US.S01E01.720p.HDTV.x264-OLD", "sr");
        judge(&c, &e1, Some(&s1), BAD, Some("sync")).unwrap();
        set_offset(&c, &e1, &s1, 1200).unwrap();
        // the hand fix settles the report
        assert_eq!(get(&c, &e1, &s1.key).unwrap().unwrap(), Mark { verdict: 0, reason: None, offset_ms: Some(1200) });
        assert_eq!(offset_for(&c, &e1, &s1).unwrap(), Some((1200, None)));
        // episode 2: same release group, a v3 subtitle made for the same group
        let e2 = rel("ep:85552:1:2", "e2-grp.mkv", "grp");
        let s2 = ext("22", "Euphoria.US.S01E02.720p.HDTV.x264-OLD", "sr");
        assert_eq!(offset_for(&c, &e2, &s2).unwrap(), Some((1200, Some("ep:85552:1:1".into()))));
        assert_eq!(episode_label("ep:85552:1:1").as_deref(), Some("S1 · E1"));
        // made for another group, or another language: nothing
        let s3 = ext("23", "Euphoria.US.S01E02.1080p.WEB.H264-GRP", "sr");
        assert_eq!(offset_for(&c, &e2, &s3).unwrap(), None);
        let s4 = ext("24", "Euphoria.US.S01E02.720p.HDTV.x264-OLD", "en");
        assert_eq!(offset_for(&c, &e2, &s4).unwrap(), None);
        // a release of another group doesn't borrow it
        let e2b = rel("ep:85552:1:2", "e2-other.mkv", "other");
        assert_eq!(offset_for(&c, &e2b, &s2).unwrap(), None);
    }
}
