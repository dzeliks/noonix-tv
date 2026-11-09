// what the viewers said about a source (core matches.rs, cut down): a liked file first, then the
// show's liked groups; a reported file goes last. per profile
import type { Stream } from "./sources"
import * as profiles from "./profiles"
import * as store from "./store"

interface Memory {
    /** "movie:1" / "show:1" -> liked files and release groups */
    good: { [title: string]: { files: string[]; groups: string[] } }
    bad: string[]
}

function get(): Memory { return store.get<Memory>(profiles.key("sources"), { good: {}, bad: [] }) }
function put(m: Memory): void { store.set(profiles.key("sources"), m) }

export function fileKey(s: Stream): string { return (s.filename || s.title.split("\n")[0]).trim().toLowerCase() }

/** the release group as the name writes it ("…-GRP.mkv") */
export function groupOf(s: Stream): string | null {
    const m = /-([a-z0-9]{2,})(?:\[[^\]]*\])?(?:\.[a-z0-9]{2,4})?$/i.exec(s.filename || s.title.split("\n")[0])
    return m ? m[1].toLowerCase() : null
}

function keep<T>(list: T[], v: T, max: number): T[] {
    return [v].concat(list.filter(function (x) { return x !== v })).slice(0, max)
}

export function like(kind: string, tmdb: number, s: Stream): void {
    const m = get()
    const k = kind + ":" + tmdb
    const g = m.good[k] || { files: [], groups: [] }
    g.files = keep(g.files, fileKey(s), 20)
    const grp = groupOf(s)
    if (grp && kind === "show") g.groups = keep(g.groups, grp, 5)
    m.good[k] = g
    m.bad = m.bad.filter(function (f) { return f !== fileKey(s) })
    put(m)
}

export function report(s: Stream): void {
    const m = get()
    m.bad = keep(m.bad, fileKey(s), 200)
    put(m)
}

export function isGood(kind: string, tmdb: number, s: Stream): boolean {
    const g = get().good[kind + ":" + tmdb]
    return !!g && g.files.indexOf(fileKey(s)) >= 0
}

export function isBad(s: Stream): boolean { return get().bad.indexOf(fileKey(s)) >= 0 }

/** the list in the viewers' order; the rest keeps the ranking */
export function order(kind: string, tmdb: number, list: Stream[]): Stream[] {
    const m = get()
    const g = m.good[kind + ":" + tmdb]
    if (!g && !m.bad.length) return list
    const tier = function (s: Stream): number {
        const f = fileKey(s)
        if (m.bad.indexOf(f) >= 0) return 3
        if (g && g.files.indexOf(f) >= 0 && s.cached !== false) return 0
        const grp = groupOf(s)
        if (g && grp && g.groups.indexOf(grp) >= 0 && !s.warn) return 1
        return 2
    }
    return list.map(function (s, i) { return { s: s, t: tier(s), i: i } })
        .sort(function (a, b) { return a.t - b.t || a.i - b.i })
        .map(function (x) { return x.s })
}
