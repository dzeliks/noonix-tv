use crate::config::PATHS;
use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Mutex;

const MIGRATIONS: &[&str] = &[
    // 1
    r#"
    create table profiles (
        id integer primary key,
        name text not null,
        color text not null default 'green',
        trakt text not null default 'none',      -- none | shared | own
        created integer not null
    );
    create table settings (
        scope text not null,                      -- 'app' or 'profile:<id>'
        key text not null,
        value text not null,
        primary key (scope, key)
    );
    create table progress (
        profile integer not null,
        key text not null,                        -- movie:<tmdb> | ep:<show tmdb>:<s>:<e>
        kind text not null,                       -- movie | episode
        tmdb integer not null,                    -- movie or show id
        imdb text,
        season integer,
        episode integer,
        title text,
        position real not null,
        duration real not null,
        completed integer not null default 0,
        updated integer not null,
        primary key (profile, key)
    );
    create index progress_recent on progress(profile, updated desc);
    create table history (
        id integer primary key,
        profile integer not null,
        key text not null,
        kind text not null,
        tmdb integer not null,
        season integer,
        episode integer,
        watched_at integer not null
    );
    create index history_profile on history(profile, watched_at desc);
    create table watchlist (
        profile integer not null,
        kind text not null,                       -- movie | show
        tmdb integer not null,
        added integer not null,
        primary key (profile, kind, tmdb)
    );
    create table source_memory (
        profile integer not null,
        show integer not null,
        provider text,
        resolution text,
        binge_group text,
        updated integer not null,
        primary key (profile, show)
    );
    create table cache (
        key text primary key,
        value text not null,
        expires integer not null
    );
    "#,
    // 2
    r#"
    create table addons (
        id integer primary key,
        manifest_url text not null unique,        -- secret: may carry tokens
        addon_id text not null,
        name text not null,
        version text not null default '',
        manifest text not null,                   -- json of stremio::Addon
        enabled integer not null default 1,
        position integer not null default 0,
        formatting text,                          -- noonix | ok | unsupported (last seen)
        last_error text,
        added integer not null
    );
    "#,
    // 3
    r#"
    create table match_marks (
        title text not null,                      -- movie:<tmdb> | ep:<show>:<s>:<e>
        show integer,                             -- show tmdb id, null for movies
        release text not null,                    -- the file's name, lowercased
        release_group text,
        sub text not null default '',             -- '' = the release alone | emb:... | ext:<file>
        sub_lang text,
        sub_name text,                            -- the release the subtitle was made for / track title
        provider text,                            -- embedded | opensubtitles | v3
        sub_src text,                             -- json: how to get an external one again
        verdict integer not null default 0,       -- 2 good, 1 watched to the end, -1 reported
        reason text,                              -- sync | wrong | av
        offset_ms integer,                        -- subtitle timing set by hand
        updated integer not null,
        primary key (title, release, sub)
    );
    create index match_show on match_marks(show, release_group);
    "#,
    // 4: keys and logins live here (no keyring, no files); "this pc's trakt login" is gone:
    // those profiles sign in with noonix tv's own trakt app once
    r#"
    create table secrets (
        key text primary key,
        value text not null
    );
    insert or replace into settings (scope, key, value)
        select 'app', 'trakt_relogin', 'true' where exists (select 1 from profiles where trakt = 'shared');
    update profiles set trakt = 'none' where trakt = 'shared';
    "#,
    // 5: "sign in to trakt once more" belongs to the profile that lost its login, not to everyone:
    // the ones with trakt answers in the cache had it
    r#"
    insert or replace into settings (scope, key, value)
        select 'profile:' || p.id, 'trakt_relogin', 'true' from profiles p
        where p.trakt = 'none'
          and exists (select 1 from settings where scope = 'app' and key = 'trakt_relogin')
          and exists (select 1 from cache where key like 'trakt:' || p.id || ':%');
    delete from settings where scope = 'app' and key = 'trakt_relogin';
    "#,
    // 6: no built-in sources any more: the library and what the user adds (addons, extensions).
    // torrent mode chosen before = torrents allowed
    r#"
    create table extensions (
        id text primary key,
        name text not null,
        version text not null default '',
        source text not null,                     -- the address it came from, or 'file'
        manifest text not null,                   -- the extension's json
        enabled integer not null default 1,
        added integer not null
    );
    alter table addons add column extension text;  -- the extension that added it, null = the user
    create table library_files (
        path text primary key,
        size integer not null,
        mtime integer not null,
        kind text not null,                       -- movie | episode | unknown
        tmdb integer,                             -- movie or show id once matched
        season integer,
        episode integer,
        name text,                                -- the title as the file or folder names it
        year integer,
        seen integer not null                     -- the scan that last found it
    );
    create index library_title on library_files(tmdb, season, episode);
    delete from addons where manifest_url like 'http://127.0.0.1:37831/%';
    insert or replace into settings (scope, key, value)
        select 'app', 'torrents', 'true' from secrets where key = 'SOURCES_MODE' and value = 'torrent';
    delete from secrets where key = 'SOURCES_MODE';
    "#,
];

pub static DB: Lazy<Mutex<Connection>> = Lazy::new(|| {
    let path = std::env::var_os("NOONIX_DB")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| PATHS.data.join("noonix-tv.db"));
    let conn = open(&path).unwrap_or_else(|e| {
        tracing::error!("db {}: {e:#}, using memory", path.display());
        open_memory().expect("in-memory db")
    });
    Mutex::new(conn)
});

fn setup(conn: &Connection) -> Result<()> {
    conn.pragma_update(None, "journal_mode", "wal")?;
    conn.pragma_update(None, "synchronous", "normal")?;
    conn.pragma_update(None, "foreign_keys", "on")?;
    let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(sql).with_context(|| format!("migration {}", i + 1))?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    Ok(())
}

pub fn open(path: &std::path::Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    // holds the keys and logins; sqlite copies these bits to -wal/-shm. windows: the per-user
    // app data dir is private already
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    setup(&conn)?;
    Ok(conn)
}

pub fn open_memory() -> Result<Connection> {
    let conn = Connection::open_in_memory()?;
    setup(&conn)?;
    Ok(conn)
}

/// run blocking db work off the async threads
pub async fn with<T, F>(f: F) -> Result<T>
where
    T: Send + 'static,
    F: FnOnce(&Connection) -> Result<T> + Send + 'static,
{
    tokio::task::spawn_blocking(move || {
        let conn = DB.lock().map_err(|_| anyhow::anyhow!("db lock poisoned"))?;
        f(&conn)
    })
    .await?
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

// ---- profiles

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: i64,
    pub name: String,
    pub color: String,
    pub trakt: String,
}

pub fn profiles(c: &Connection) -> Result<Vec<Profile>> {
    let mut st = c.prepare("select id, name, color, trakt from profiles order by id")?;
    let rows = st.query_map([], |r| {
        Ok(Profile { id: r.get(0)?, name: r.get(1)?, color: r.get(2)?, trakt: r.get(3)? })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn add_profile(c: &Connection, name: &str, color: &str, trakt: &str) -> Result<i64> {
    c.execute(
        "insert into profiles (name, color, trakt, created) values (?1, ?2, ?3, ?4)",
        params![name, color, trakt, now()],
    )?;
    Ok(c.last_insert_rowid())
}

pub fn update_profile(c: &Connection, p: &Profile) -> Result<()> {
    c.execute(
        "update profiles set name = ?2, color = ?3, trakt = ?4 where id = ?1",
        params![p.id, p.name, p.color, p.trakt],
    )?;
    Ok(())
}

// ---- settings

pub fn get_setting(c: &Connection, scope: &str, key: &str) -> Result<Option<Value>> {
    let v: Option<String> = c
        .query_row("select value from settings where scope = ?1 and key = ?2", params![scope, key], |r| r.get(0))
        .optional()?;
    Ok(v.and_then(|s| serde_json::from_str(&s).ok()))
}

pub fn secrets(c: &Connection) -> Result<std::collections::BTreeMap<String, String>> {
    let mut st = c.prepare("select key, value from secrets")?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn set_secret(c: &Connection, key: &str, value: Option<&str>) -> Result<()> {
    match value {
        Some(v) => c.execute("insert into secrets (key, value) values (?1, ?2) on conflict(key) do update set value = excluded.value", params![key, v])?,
        None => c.execute("delete from secrets where key = ?1", params![key])?,
    };
    Ok(())
}

pub fn set_setting(c: &Connection, scope: &str, key: &str, value: &Value) -> Result<()> {
    c.execute(
        "insert into settings (scope, key, value) values (?1, ?2, ?3)
         on conflict(scope, key) do update set value = excluded.value",
        params![scope, key, value.to_string()],
    )?;
    Ok(())
}

pub fn settings(c: &Connection, scope: &str) -> Result<serde_json::Map<String, Value>> {
    let mut st = c.prepare("select key, value from settings where scope = ?1")?;
    let rows = st.query_map(params![scope], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    let mut map = serde_json::Map::new();
    for row in rows {
        let (k, v) = row?;
        map.insert(k, serde_json::from_str(&v).unwrap_or(Value::Null));
    }
    Ok(map)
}

// ---- progress / history

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Progress {
    pub key: String,
    pub kind: String,
    pub tmdb: i64,
    pub imdb: Option<String>,
    pub season: Option<i64>,
    pub episode: Option<i64>,
    pub title: Option<String>,
    pub position: f64,
    pub duration: f64,
    pub completed: bool,
    pub updated: i64,
}

pub fn movie_key(tmdb: i64) -> String {
    format!("movie:{tmdb}")
}

pub fn episode_key(show: i64, season: i64, episode: i64) -> String {
    format!("ep:{show}:{season}:{episode}")
}

pub fn save_progress(c: &Connection, profile: i64, p: &Progress) -> Result<()> {
    c.execute(
        "insert into progress (profile, key, kind, tmdb, imdb, season, episode, title, position, duration, completed, updated)
         values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         on conflict(profile, key) do update set
           position = excluded.position, duration = excluded.duration, completed = excluded.completed,
           updated = excluded.updated, imdb = coalesce(excluded.imdb, imdb), title = coalesce(excluded.title, title)",
        params![
            profile, p.key, p.kind, p.tmdb, p.imdb, p.season, p.episode, p.title, p.position, p.duration,
            p.completed, p.updated
        ],
    )?;
    Ok(())
}

fn row_progress(r: &rusqlite::Row) -> rusqlite::Result<Progress> {
    Ok(Progress {
        key: r.get(0)?,
        kind: r.get(1)?,
        tmdb: r.get(2)?,
        imdb: r.get(3)?,
        season: r.get(4)?,
        episode: r.get(5)?,
        title: r.get(6)?,
        position: r.get(7)?,
        duration: r.get(8)?,
        completed: r.get(9)?,
        updated: r.get(10)?,
    })
}

const PROGRESS_COLS: &str =
    "key, kind, tmdb, imdb, season, episode, title, position, duration, completed, updated";

pub fn get_progress(c: &Connection, profile: i64, key: &str) -> Result<Option<Progress>> {
    Ok(c.query_row(
        &format!("select {PROGRESS_COLS} from progress where profile = ?1 and key = ?2"),
        params![profile, key],
        row_progress,
    )
    .optional()?)
}

/// unfinished items, newest first
pub fn in_progress(c: &Connection, profile: i64, limit: i64) -> Result<Vec<Progress>> {
    let mut st = c.prepare(&format!(
        "select {PROGRESS_COLS} from progress where profile = ?1 and completed = 0 and position > 0
         order by updated desc limit ?2"
    ))?;
    let rows = st.query_map(params![profile, limit], row_progress)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// every episode row of a show (watched + partial) for the season views
pub fn show_progress(c: &Connection, profile: i64, show: i64) -> Result<Vec<Progress>> {
    let mut st = c.prepare(&format!(
        "select {PROGRESS_COLS} from progress where profile = ?1 and kind = 'episode' and tmdb = ?2"
    ))?;
    let rows = st.query_map(params![profile, show], row_progress)?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn add_history(c: &Connection, profile: i64, p: &Progress) -> Result<()> {
    c.execute(
        "insert into history (profile, key, kind, tmdb, season, episode, watched_at) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![profile, p.key, p.kind, p.tmdb, p.season, p.episode, now()],
    )?;
    Ok(())
}

pub fn history(c: &Connection, profile: i64, limit: i64) -> Result<Vec<Value>> {
    let mut st = c.prepare(
        "select kind, tmdb, season, episode, max(watched_at) from history
         where profile = ?1 group by key order by max(watched_at) desc limit ?2",
    )?;
    let rows = st.query_map(params![profile, limit], |r| {
        let kind: String = r.get(0)?;
        let tmdb: i64 = r.get(1)?;
        let season: Option<i64> = r.get(2)?;
        let episode: Option<i64> = r.get(3)?;
        let watched: i64 = r.get(4)?;
        Ok(if kind == "episode" {
            serde_json::json!({ "kind": kind, "show": tmdb, "season": season, "episode": episode, "watchedAt": watched })
        } else {
            serde_json::json!({ "kind": kind, "id": tmdb, "watchedAt": watched })
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

/// last watched episode per show (local up next for profiles without trakt)
pub fn recent_shows(c: &Connection, profile: i64, limit: i64) -> Result<Vec<(i64, i64, i64, i64)>> {
    let mut st = c.prepare(
        "select tmdb, season, episode, max(t) from (
            select tmdb, season, episode, watched_at as t from history where profile = ?1 and kind = 'episode'
            union all
            select tmdb, season, episode, updated as t from progress where profile = ?1 and kind = 'episode'
         ) group by tmdb order by max(t) desc limit ?2",
    )?;
    let rows = st.query_map(params![profile, limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// ---- watchlist

pub fn watchlist(c: &Connection, profile: i64) -> Result<Vec<(String, i64)>> {
    let mut st = c.prepare("select kind, tmdb from watchlist where profile = ?1 order by added desc")?;
    let rows = st.query_map(params![profile], |r| Ok((r.get(0)?, r.get(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn set_watchlist(c: &Connection, profile: i64, kind: &str, tmdb: i64, on: bool) -> Result<()> {
    if on {
        c.execute(
            "insert or ignore into watchlist (profile, kind, tmdb, added) values (?1, ?2, ?3, ?4)",
            params![profile, kind, tmdb, now()],
        )?;
    } else {
        c.execute("delete from watchlist where profile = ?1 and kind = ?2 and tmdb = ?3", params![profile, kind, tmdb])?;
    }
    Ok(())
}

// ---- source memory (same provider/quality for the next episode)

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SourceMemory {
    pub provider: Option<String>,
    pub resolution: Option<String>,
    pub binge_group: Option<String>,
}

pub fn source_memory(c: &Connection, profile: i64, show: i64) -> Result<Option<SourceMemory>> {
    Ok(c.query_row(
        "select provider, resolution, binge_group from source_memory where profile = ?1 and show = ?2",
        params![profile, show],
        |r| Ok(SourceMemory { provider: r.get(0)?, resolution: r.get(1)?, binge_group: r.get(2)? }),
    )
    .optional()?)
}

pub fn set_source_memory(c: &Connection, profile: i64, show: i64, m: &SourceMemory) -> Result<()> {
    c.execute(
        "insert into source_memory (profile, show, provider, resolution, binge_group, updated) values (?1, ?2, ?3, ?4, ?5, ?6)
         on conflict(profile, show) do update set provider = excluded.provider, resolution = excluded.resolution,
           binge_group = excluded.binge_group, updated = excluded.updated",
        params![profile, show, m.provider, m.resolution, m.binge_group, now()],
    )?;
    Ok(())
}

// ---- cache

pub fn cache_get(c: &Connection, key: &str) -> Result<Option<String>> {
    Ok(c.query_row("select value from cache where key = ?1 and expires > ?2", params![key, now()], |r| r.get(0))
        .optional()?)
}

/// even when expired (offline fallback)
pub fn cache_get_stale(c: &Connection, key: &str) -> Result<Option<String>> {
    Ok(c.query_row("select value from cache where key = ?1", params![key], |r| r.get(0)).optional()?)
}

pub fn cache_put(c: &Connection, key: &str, value: &str, ttl_secs: i64) -> Result<()> {
    c.execute(
        "insert into cache (key, value, expires) values (?1, ?2, ?3)
         on conflict(key) do update set value = excluded.value, expires = excluded.expires",
        params![key, value, now() + ttl_secs],
    )?;
    Ok(())
}

pub fn cache_drop_prefix(c: &Connection, prefix: &str) -> Result<usize> {
    Ok(c.execute("delete from cache where key like ?1 || '%'", params![prefix])?)
}

pub fn cache_prune(c: &Connection) -> Result<usize> {
    // keep a week of stale entries for offline use
    Ok(c.execute("delete from cache where expires < ?1", params![now() - 7 * 86400])?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trakt_relogin_moves_to_the_profile_that_had_trakt() {
        let c = Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..3] {
            c.execute_batch(sql).unwrap();
        }
        c.execute_batch(
            "insert into profiles (id, name, color, trakt, created) values (1, 'a', 'green', 'shared', 0), (2, 'b', 'pink', 'none', 0);
             insert into cache (key, value, expires) values ('trakt:1:/sync/history', '[]', 0);",
        )
        .unwrap();
        for sql in &MIGRATIONS[3..] {
            c.execute_batch(sql).unwrap();
        }
        assert_eq!(get_setting(&c, "profile:1", "trakt_relogin").unwrap(), Some(serde_json::json!(true)));
        assert_eq!(get_setting(&c, "profile:2", "trakt_relogin").unwrap(), None);
        assert_eq!(get_setting(&c, "app", "trakt_relogin").unwrap(), None);
    }

    #[test]
    fn progress_roundtrip_and_recent() {
        let c = open_memory().unwrap();
        let pid = add_profile(&c, "Ana", "green", "own").unwrap();
        let mut p = Progress {
            key: episode_key(2734, 1, 10),
            kind: "episode".into(),
            tmdb: 2734,
            season: Some(1),
            episode: Some(10),
            position: 600.0,
            duration: 2640.0,
            updated: 100,
            ..Default::default()
        };
        save_progress(&c, pid, &p).unwrap();
        p.position = 700.0;
        p.updated = 200;
        save_progress(&c, pid, &p).unwrap();
        let got = get_progress(&c, pid, &p.key).unwrap().unwrap();
        assert_eq!(got.position, 700.0);
        assert_eq!(in_progress(&c, pid, 10).unwrap().len(), 1);
        assert_eq!(recent_shows(&c, pid, 5).unwrap()[0].0, 2734);
        cache_put(&c, "k", "v", 60).unwrap();
        assert_eq!(cache_get(&c, "k").unwrap().as_deref(), Some("v"));
    }
}
