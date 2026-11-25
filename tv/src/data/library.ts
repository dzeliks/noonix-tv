// the library (core library.rs) on a tv: folders on network shares, their videos read from the names
// and matched on tmdb, played as a source of their title. kept for the whole tv, not per profile
import * as store from "./store"
import * as shares from "./shares"
import * as tmdb from "./tmdb"
import { parseRelease } from "./release"
import type { Stream, Target } from "./sources"

export interface File {
    path: string
    size: number
    mtime: number
    kind: "movie" | "episode"
    tmdb: number | null
    season: number | null
    episode: number | null
    name: string
    year: number | null
}

export interface Guess { kind: "movie" | "episode"; name: string; year: number | null; season: number | null; episode: number | null }

export function on(): boolean { return store.get<boolean>("libraryOn", true) }
export function setOn(v: boolean): void { store.set("libraryOn", v) }
export function folders(): string[] { return store.get<string[]>("libraryFolders", []) }
function files(): File[] { return store.get<File[]>("libraryFiles", []) }

const listeners: (() => void)[] = []
/** the files changed (a scan, a folder in or out); gives the way to stop listening */
export function onChange(fn: () => void): () => void {
    listeners.push(fn)
    return function () { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1) }
}
function changed(): void { listeners.forEach(function (f) { f() }) }

export function addFolder(path: string): void {
    const p = path.replace(/\/+$/, "")
    const l = folders()
    // already in, or inside one that is
    if (l.some(function (f) { return p === f || p.indexOf(f + "/") === 0 })) return
    // a folder above ones already in takes their place
    store.set("libraryFolders", l.filter(function (f) { return f.indexOf(p + "/") !== 0 }).concat([p]))
}

export function removeFolder(path: string): void {
    store.set("libraryFolders", folders().filter(function (f) { return f !== path }))
    store.set("libraryFiles", files().filter(function (f) { return !inside(f.path, path) }))
    changed()
}

/** a share forgotten: its folders and files leave too */
export function forgetShare(path: string): void {
    const s = shares.remove(path)
    if (!s) return
    const r = shares.root(s)
    folders().filter(function (f) { return inside(f, r) }).forEach(removeFolder)
}

function inside(path: string, folder: string): boolean { return path === folder || path.indexOf(folder + "/") === 0 }

export function folderFiles(folder: string): number {
    return files().filter(function (f) { return inside(f.path, folder) }).length
}

// ---- reading names (library.rs guess, title_year)

const SXE = /\bs(\d{1,2})[ ._-]?e(\d{1,3})\b|\b(\d{1,2})x(\d{2,3})\b/i
const EP_ONLY = /(?:^|[ ._-])(?:e|ep|episode)[ ._-]?(\d{1,3})\b/i
const SEASON_DIR = /^(?:season|series|staffel|sezona|saison|temporada)[ ._-]*(\d{1,2})$|^s(\d{1,2})$/i
const YEAR = /[(\[]?\b(19[2-9]\d|20[0-4]\d)\b[)\]]?/g
const TAGS = /\b(2160p|1080p|720p|576p|480p|4k|uhd|web[ .-]?dl|webrip|web|bluray|blu-ray|bdrip|brrip|remux|hdtv|dvdrip|x264|x265|h264|h265|hevc|hdr|proper|repack)\b/i

function tidy(s: string): string {
    return s.replace(/\[[^\]]*\]/g, " ").replace(/[._]/g, " ").split(/\s+/).filter(function (w) { return !!w }).join(" ")
        .replace(/^[\s(-]+|[\s(-]+$/g, "")
}

export function titleYear(raw: string): { name: string; year: number | null } {
    const t = tidy(raw)
    const tag = TAGS.exec(t)
    const head = tag ? t.slice(0, tag.index) : t
    // the last year in it, not at the very start ("2001 A Space Odyssey 1968")
    let last: RegExpExecArray | null = null
    let m: RegExpExecArray | null
    YEAR.lastIndex = 0
    while ((m = YEAR.exec(head))) if (m.index > 0) last = m
    if (last) return { name: tidy(head.slice(0, last.index)), year: parseInt(last[1], 10) }
    return { name: tidy(head), year: null }
}

/** what a file is, from its name and the folders between the library folder and it */
export function guess(path: string, rootPath: string): Guess {
    const fname = path.split("/").pop() || ""
    const dot = fname.lastIndexOf(".")
    const stem = dot > 0 ? fname.slice(0, dot) : fname
    const between = path.slice(rootPath.length).replace(/^\/+/, "").split("/")
    between.pop()
    const dirs = between.reverse()
    let seasonDir = -1
    for (let i = 0; i < dirs.length; i++) if (SEASON_DIR.test(dirs[i].trim())) { seasonDir = i; break }
    let dirSeason: number | null = null
    if (seasonDir >= 0) {
        const c = SEASON_DIR.exec(dirs[seasonDir].trim())
        if (c) dirSeason = parseInt(c[1] || c[2], 10)
    }
    const showDir = seasonDir >= 0 ? dirs[seasonDir + 1] : dirs[0]

    let season: number | null = null
    let episode: number | null = null
    let before = ""
    const sxe = SXE.exec(stem)
    const ep = EP_ONLY.exec(stem)
    if (sxe) {
        season = parseInt(sxe[1] || sxe[3], 10)
        episode = parseInt(sxe[2] || sxe[4], 10)
        before = stem.slice(0, sxe.index)
    } else if (dirSeason !== null && ep) {
        season = dirSeason
        episode = parseInt(ep[1], 10)
        before = stem.slice(0, ep.index)
    } else if (dirSeason !== null) {
        // "Season 1/03 - Pilot.mkv"
        const n = parseInt(stem.replace(/^\s+/, ""), 10)
        season = dirSeason
        episode = n > 0 && n < 300 ? n : null
    }
    if (season !== null && episode !== null) {
        let ty = titleYear(before)
        if (!ty.name && showDir) ty = titleYear(showDir)
        return { kind: "episode", name: ty.name, year: ty.year, season: season, episode: episode }
    }
    let ty = titleYear(stem)
    // "Movie (2010)/movie.mkv", or a release-named file in a folder named after the movie
    if (dirs[0]) {
        const d = titleYear(dirs[0])
        if (d.name && (!ty.name || (ty.year === null && d.year !== null))) ty = d
    }
    return { kind: "movie", name: ty.name, year: ty.year, season: null, episode: null }
}

// ---- scanning

let scanning: Promise<void> | null = null
export function isScanning(): boolean { return !!scanning }

/** walks the folders, reads new or changed files and matches them; one scan at a time. a share that
 *  doesn't answer keeps its files (like a drive that isn't there) */
export function scan(): Promise<void> {
    if (scanning) return scanning
    const roots = folders()
    const missing: string[] = []
    const found: { path: string; size: number; mtime: number }[] = []
    changed()
    scanning = roots.reduce(function (p, r) {
        return p.then(function () {
            return shares.walk(r).then(function (l) { l.forEach(function (f) { found.push(f) }) }, function (e) {
                console.warn("library " + shares.label(r) + ": " + (e && e.message || e))
                missing.push(r)
            })
        })
    }, Promise.resolve()).then(function () {
        const known: { [p: string]: File } = {}
        files().forEach(function (f) { known[f.path] = f })
        const keep: File[] = []
        const todo: { path: string; size: number; mtime: number }[] = []
        found.forEach(function (f) {
            const k = known[f.path]
            if (k && k.size === f.size && k.mtime === f.mtime) keep.push(k)
            else todo.push(f)
        })
        // gone from a share that answered: out; from one that didn't: kept
        const seen: { [p: string]: boolean } = {}
        found.forEach(function (f) { seen[f.path] = true })
        files().forEach(function (f) {
            if (!seen[f.path] && missing.some(function (m) { return inside(f.path, m) })) keep.push(f)
        })
        const out = keep
        let next = 0
        // four at a time, like the core
        const worker = function (): Promise<void> {
            const f = todo[next++]
            if (!f) return Promise.resolve()
            const r = roots.filter(function (x) { return inside(f.path, x) })[0] || ""
            const g = guess(f.path, r)
            const done = function (id: number | null): Promise<void> {
                out.push({ path: f.path, size: f.size, mtime: f.mtime, kind: g.kind, tmdb: id, season: g.season, episode: g.episode, name: g.name, year: g.year })
                return worker()
            }
            if (!g.name) return done(null)
            return tmdb.find(g.kind === "movie" ? "movie" : "show", g.name, g.year).then(done, function () { return done(null) })
        }
        return Promise.all([worker(), worker(), worker(), worker()]).then(function () {
            store.set("libraryFiles", out)
        })
    }).then(function () { scanning = null; changed() }, function (e) { scanning = null; changed(); throw e })
    return scanning
}

export interface Status { files: number; matched: number; unmatchedNames: string[] }

export function status(): Status {
    const l = files()
    const un = l.filter(function (f) { return f.tmdb === null })
    return { files: l.length, matched: l.length - un.length, unmatchedNames: un.slice(0, 5).map(function (f) { return f.path.split("/").pop() || f.path }) }
}

// ---- what the app shows of it

/** the matched titles, newest file first, for the home row */
export function items(kind?: tmdb.Kind): { kind: tmdb.Kind; id: number }[] {
    if (!on()) return []
    const best: { [k: string]: { kind: tmdb.Kind; id: number; m: number } } = {}
    files().forEach(function (f) {
        if (f.tmdb === null) return
        const k: tmdb.Kind = f.kind === "movie" ? "movie" : "show"
        const key = k + ":" + f.tmdb
        if (!best[key] || best[key].m < f.mtime) best[key] = { kind: k, id: f.tmdb, m: f.mtime }
    })
    return Object.keys(best).map(function (k) { return best[k] }).filter(function (x) { return !kind || x.kind === kind })
        .sort(function (a, b) { return b.m - a.m }).map(function (x) { return { kind: x.kind, id: x.id } })
}

/** a title has files here */
export function has(kind: tmdb.Kind, id: number): boolean {
    return on() && files().some(function (f) { return f.tmdb === id && (f.kind === "movie") === (kind === "movie") })
}

/** the files of one title, as sources (the network share line, first) */
export function streams(t: Target): Stream[] {
    if (!on() || !t.tmdb) return []
    return files().filter(function (f) {
        if (f.tmdb !== t.tmdb) return false
        return t.kind === "movie" ? f.kind === "movie" : f.kind === "episode" && f.season === t.season && f.episode === t.episode
    }).map(function (f) {
        const name = f.path.split("/").pop() || f.path
        // the name without its extension (".ts" would read as a cam copy)
        const s = parseRelease(name.replace(/\.[^.]+$/, ""))
        s.addon = "Network share"
        s.title = name
        s.filename = name
        s.size = f.size
        s.url = f.path
        s.share = true
        return s
    })
}
