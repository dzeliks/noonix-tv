// what was watched and the library, kept on the tv (core library.rs + playback.rs progress, local only).
// trakt, when signed in, gets the same through scrobbles
import * as store from "./store"
import * as tmdb from "./tmdb"

export interface Progress {
    item: tmdb.Item
    season?: number
    episode?: number
    episodeTitle?: string
    /** seconds */
    position: number
    duration: number
    updated: number
    finished: boolean
    /** from trakt: only the share is known, the seconds come with the video's length */
    share?: number
}

/** under this share it never started, over it it's done (the qt player's 2% / 92%) */
const startedAt = 0.02
const doneAt = 0.92
const keep = 60

function key(kind: tmdb.Kind, id: number): string { return kind + ":" + id }

/** a bare item: details carry casts and lists the tv's small storage doesn't need */
function bare(it: tmdb.Item): tmdb.Item {
    return { kind: it.kind, id: it.id, title: it.title, year: it.year, date: it.date, overview: it.overview,
        poster: it.poster, backdrop: it.backdrop, rating: it.rating, genres: it.genres }
}

function all(): { [k: string]: Progress } { return store.get<{ [k: string]: Progress }>("progress", {}) }

/** the place in a title: a movie, or the last episode played of a show */
export function get(kind: tmdb.Kind, id: number): Progress | null {
    return all()[key(kind, id)] || null
}

/** the watched episodes of a show: "s:e" -> true */
export function watched(show: number): { [se: string]: boolean } {
    return store.get<{ [k: string]: { [se: string]: boolean } }>("watched", {})[show] || {}
}

function setWatched(show: number, season: number, episode: number, on: boolean): void {
    const w = store.get<{ [k: string]: { [se: string]: boolean } }>("watched", {})
    const s = w[show] || {}
    if (on) s[season + ":" + episode] = true
    else delete s[season + ":" + episode]
    w[show] = s
    store.set("watched", w)
}

/** while playing and at the end; a short look doesn't count */
export function save(p: Progress): void {
    const share = p.share !== undefined ? p.share : p.duration > 0 ? p.position / p.duration : 0
    if (share < startedAt && !p.finished) return
    p.finished = p.finished || share >= doneAt
    p.updated = Date.now()
    p.item = bare(p.item)
    const list = all()
    list[key(p.item.kind, p.item.id)] = p
    // the newest are kept
    const keys = Object.keys(list).sort(function (a, b) { return list[b].updated - list[a].updated })
    for (let i = keep; i < keys.length; i++) delete list[keys[i]]
    store.set("progress", list)
    if (p.finished && p.item.kind === "show" && p.season !== undefined && p.episode !== undefined) setWatched(p.item.id, p.season, p.episode, true)
}

export function forget(kind: tmdb.Kind, id: number): void {
    const list = all()
    delete list[key(kind, id)]
    store.set("progress", list)
}

export function markWatched(item: tmdb.Item, season?: number, episode?: number): void {
    if (item.kind === "show" && season !== undefined && episode !== undefined) {
        setWatched(item.id, season, episode, true)
        save({ item: item, season: season, episode: episode, position: 1, duration: 1, updated: 0, finished: true })
    } else {
        save({ item: item, position: 1, duration: 1, updated: 0, finished: true })
    }
}

export function markUnwatched(item: tmdb.Item, season?: number, episode?: number): void {
    if (item.kind === "show" && season !== undefined && episode !== undefined) setWatched(item.id, season, episode, false)
    forget(item.kind, item.id)
}

/** where to resume: seconds in, or 0; duration: the video's length */
export function resumeAt(kind: tmdb.Kind, id: number, season: number | undefined, episode: number | undefined, duration: number): number {
    const p = get(kind, id)
    if (!p || p.finished) return 0
    if (kind === "show" && (p.season !== season || p.episode !== episode)) return 0
    const secs = p.share !== undefined ? p.share * duration : p.position
    return Math.max(0, secs - 5)
}

/** continue watching: started, not done, newest first */
export function continuing(): Progress[] {
    const list = all()
    return Object.keys(list).map(function (k) { return list[k] })
        .filter(function (p) { return !p.finished })
        .sort(function (a, b) { return b.updated - a.updated })
}

/** shows whose last played episode was finished: the next one is up (the season list decides if it exists) */
export function upNext(): Progress[] {
    const list = all()
    return Object.keys(list).map(function (k) { return list[k] })
        .filter(function (p) { return p.finished && p.item.kind === "show" })
        .sort(function (a, b) { return b.updated - a.updated })
}

// ---- library

export function library(): tmdb.Item[] { return store.get<tmdb.Item[]>("library", []) }

export function inLibrary(kind: tmdb.Kind, id: number): boolean {
    return library().some(function (x) { return x.kind === kind && x.id === id })
}

/** adds or removes; true: it's in now */
export function toggleLibrary(it: tmdb.Item): boolean {
    const list = library()
    const at = list.filter(function (x) { return x.kind === it.kind && x.id === it.id }).length
    if (at) {
        store.set("library", list.filter(function (x) { return !(x.kind === it.kind && x.id === it.id) }))
        return false
    }
    list.unshift(bare(it))
    store.set("library", list)
    return true
}
