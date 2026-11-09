// sources: stremio addons (core stremio.rs, addons.rs, ranking.rs, cut down for a tv). a tv plays what an
// addon hands over as a link (debrid, http): torrents need an engine it doesn't have
import { json } from "./http"
import * as store from "./store"
import * as settings from "./settings"
import * as memory from "./memory"
import { platform } from "../platform"
import * as look from "../ui/look"

export interface Addon {
    url: string
    id: string
    name: string
    resources: string[]
    types: string[]
    idPrefixes: string[]
    on: boolean
}

export interface Stream {
    addon: string
    title: string
    url: string
    filename: string | null
    size: number | null
    resolution: number
    hdr: string[]
    codec: string | null
    audio: string[]
    source: string | null
    cached: boolean | null
    service: string | null
    bingeGroup: string | null
    languages: string[]
    /** why it may not play well on this tv */
    warn: string | null
}

/** a title's sources ask: a movie or one episode */
export interface Target {
    kind: "movie" | "show"
    imdb: string
    /** the viewers' word on its sources (memory.ts) */
    tmdb?: number
    season?: number
    episode?: number
}

// ---- the addon list

export function addons(): Addon[] {
    return store.get<Addon[]>("addons", [])
}

function save(list: Addon[]): void {
    store.set("addons", list)
}

/** reads the manifest and keeps the addon (a stremio link works too) */
export function addAddon(raw: string): Promise<Addon> {
    let url = raw.trim().replace(/^stremio:\/\//, "https://")
    if (!/^https?:\/\//.test(url)) url = "https://" + url
    if (!/manifest\.json$/.test(url)) url = url.replace(/\/$/, "") + "/manifest.json"
    return json({ url: url, timeout: 15 }).then(function (m: any) {
        if (!m || !m.id) throw new Error("not a stremio addon")
        const resources: string[] = (m.resources || []).map(function (r: any) { return typeof r === "string" ? r : r.name })
        const a: Addon = {
            url: url, id: m.id, name: m.name || m.id, resources: resources,
            types: m.types || [], idPrefixes: m.idPrefixes || [], on: true,
        }
        if (resources.indexOf("stream") < 0) throw new Error("this addon has no sources")
        const list = addons().filter(function (x) { return x.url !== url })
        list.push(a)
        save(list)
        return a
    })
}

export function removeAddon(url: string): void {
    save(addons().filter(function (x) { return x.url !== url }))
}

export function toggleAddon(url: string): void {
    save(addons().map(function (x) { if (x.url === url) x.on = !x.on; return x }))
}

function base(a: Addon): string { return a.url.replace(/\/manifest\.json$/, "") }

function provides(a: Addon, kind: string, id: string): boolean {
    return a.on && a.resources.indexOf("stream") >= 0
        && (!a.types.length || a.types.indexOf(kind) >= 0)
        && (!a.idPrefixes.length || a.idPrefixes.some(function (p) { return id.indexOf(p) === 0 }))
}

// ---- streams

/** every addon that serves this, side by side; one that fails or is slow is left out */
export function streams(t: Target): Promise<Stream[]> {
    const kind = t.kind === "movie" ? "movie" : "series"
    const id = t.kind === "movie" ? t.imdb : t.imdb + ":" + t.season + ":" + t.episode
    const asked = addons().filter(function (a) { return provides(a, kind, id) })
    return Promise.all(asked.map(function (a) {
        const key = "streams:" + a.url + ":" + id
        return store.cached(key, 600, function () {
            return json({ url: base(a) + "/stream/" + kind + "/" + encodeURIComponent(id) + ".json", timeout: 14, retries: 0 })
                .then(function (v: any) { return (v && v.streams) || [] })
        }).then(function (list: any[]) {
            return list.map(function (s) { return normalize(a.name, s) }).filter(function (s): s is Stream { return !!s })
        }, function (e) {
            console.warn("streams " + a.name + ": " + e)
            return [] as Stream[]
        })
    })).then(function (lists) {
        const ranked = rank(([] as Stream[]).concat.apply([], lists))
        return t.tmdb ? memory.order(t.kind, t.tmdb, ranked) : ranked
    })
}

function normalize(addon: string, s: any): Stream | null {
    if (!s || typeof s.url !== "string" || !/^https?:/.test(s.url)) return null
    const hints = s.behaviorHints || {}
    // a <video> can't send the headers a proxied stream needs
    if (hints.proxyHeaders && hints.proxyHeaders.request) return null
    const name = s.name || ""
    const desc = s.description || s.title || ""
    const filename: string | null = hints.filename || null
    const text = name + "\n" + desc + "\n" + (filename || "")
    const st = parseRelease(text)
    st.addon = addon
    st.url = s.url
    st.filename = filename
    st.title = filename || (desc.split("\n")[0] || name).trim()
    st.size = hints.videoSize || parseSize(text)
    st.bingeGroup = hints.bingeGroup || null
    const lower = text.toLowerCase()
    st.cached = text.indexOf("⚡") >= 0 || text.indexOf("+]") >= 0 || lower.indexOf("instant") >= 0 ? true
        : text.indexOf("⏳") >= 0 || lower.indexOf("download]") >= 0 || lower.indexOf("not ready") >= 0 ? false : null
    const svc = /\[(TB|RD|AD|PM|DL|ED|OC|PKP)\+?\]/.exec(text)
    st.service = svc ? svc[1].toUpperCase() : null
    return st
}

function has(text: string, pat: string): boolean {
    // a digit may follow (ddp5.1, hdr10)
    return new RegExp("(^|[^a-z0-9])" + pat + "($|[^a-z])", "i").test(text)
}

/** what a release name tells (stremio.rs parse_release) */
export function parseRelease(text: string): Stream {
    const r = /\b(2160|1440|1080|720|576|480)[pi]\b|\b(4k|uhd)\b|\b(2k)\b/i.exec(text)
    const resolution = !r ? 0 : r[1] ? parseInt(r[1], 10) : r[3] ? 1440 : 2160
    const hdr: string[] = []
    if (has(text, "(dv|dovi|dolby[ .]?vision)")) hdr.push("DV")
    if (has(text, "hdr10(\\+|plus)")) hdr.push("HDR10+")
    else if (has(text, "hdr(10)?")) hdr.push("HDR10")
    if (has(text, "hlg")) hdr.push("HLG")
    const codec = has(text, "(hevc|[xh][ .]?265)") ? "HEVC" : has(text, "av1") ? "AV1" : has(text, "(avc|[xh][ .]?264)") ? "AVC" : null
    const audio: string[] = []
    ;[["atmos", "Atmos"], ["truehd", "TrueHD"], ["dts[ .-]?(hd|x|ma)", "DTS-HD"], ["dts", "DTS"], ["(ddp|dd\\+|eac3|e-ac-3)", "DD+"],
        ["(dd|ac3|dolby digital)", "DD"], ["aac", "AAC"], ["opus", "Opus"], ["flac", "FLAC"]].forEach(function (p) {
        if (!has(text, p[0])) return
        if (p[1] === "DTS" && audio.indexOf("DTS-HD") >= 0) return
        if (p[1] === "DD" && audio.indexOf("DD+") >= 0) return
        audio.push(p[1])
    })
    const sources: [string, string][] = [["remux", "Remux"], ["(blu-?ray|bdrip|brrip)", "BluRay"], ["web-?dl", "WEB-DL"],
        ["web-?rip", "WEBRip"], ["web", "WEB"], ["hdtv", "HDTV"], ["(cam|hdcam|telesync|ts|hdts)", "CAM"], ["(dvdrip|dvd)", "DVD"]]
    let source: string | null = null
    for (let i = 0; i < sources.length && !source; i++) if (has(text, sources[i][0])) source = sources[i][1]
    const langs: string[] = []
    ;[["en", "eng|english"], ["sr", "srp|serbian|srpski"], ["hr", "hrv|croatian"], ["bs", "bos|bosnian"], ["de", "ger|deu|german"],
        ["fr", "fre|fra|french|vff|truefrench"], ["es", "spa|spanish|latino|castellano"], ["it", "ita|italian"], ["ru", "rus|russian"],
        ["multi", "multi"]].forEach(function (l) { if (has(text, "(" + l[1] + ")")) langs.push(l[0]) })
    return {
        addon: "", title: "", url: "", filename: null, size: null, resolution: resolution, hdr: hdr, codec: codec, audio: audio,
        source: source, cached: null, service: null, bingeGroup: null, languages: langs, warn: null,
    }
}

function parseSize(text: string): number | null {
    const m = /(\d+(?:[.,]\d+)?)\s*(GB|MB|GiB|MiB)\b/i.exec(text)
    if (!m) return null
    const n = parseFloat(m[1].replace(",", "."))
    return Math.round(n * (/^g/i.test(m[2]) ? 1073741824 : 1048576))
}

// ---- ranking for this tv

declare const webapis: any

/** a full hd panel says so (samsung); lg's answer needs a service call, so it counts as 4k */
function fullHdPanel(): boolean {
    try { return typeof webapis !== "undefined" && webapis.productinfo && webapis.productinfo.isUdPanelSupported() === false } catch (e) { return false }
}

/** the tallest picture worth asking for here: the user's pick, else low memory and full hd tvs stay at 1080p */
export function maxResolution(): number {
    const q = settings.all().quality
    if (q !== "auto") return parseInt(q, 10)
    return look.lowMemory || fullHdPanel() ? 1080 : 2160
}

/** what this tv's player is known to trip on */
function trouble(s: Stream): string | null {
    if (s.source === "CAM") return "cam"
    if (s.resolution > maxResolution()) return "level"
    if (s.codec === "AV1" && (platform.os !== "webos" || platform.version < 6)) return "codec"
    // dolby vision with nothing under it: a tv without dv shows it purple and green
    if (s.hdr.length === 1 && s.hdr[0] === "DV") return "dv"
    // samsung dropped dts in 2018
    if (platform.os === "tizen" && s.audio.length && s.audio.every(function (a) { return a === "DTS" || a === "DTS-HD" })) return "audio"
    return null
}

const patterns: { [p: string]: RegExp | null } = {}

/** a release pattern as the user writes it (core ranking.rs pattern): words, whole and in any case,
 *  or /a regex/. a broken one matches nothing */
export function pattern(p: string): RegExp | null {
    p = p.trim()
    if (!p) return null
    if (patterns[p] !== undefined) return patterns[p]
    // no \p{L} before chromium 64: latin, greek and cyrillic letters count as word letters
    const edge = "[^0-9A-Za-z\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff]"
    let re: RegExp | null = null
    try {
        re = p.length > 2 && p.charAt(0) === "/" && p.charAt(p.length - 1) === "/" ? new RegExp(p.slice(1, -1), "i")
            : new RegExp("(^|" + edge + ")" + p.replace(/[.*+?^${}()|[\]\\\/-]/g, "\\$&").replace(/ +/g, "[ ._\\-]+") + "(" + edge + "|$)", "i")
    } catch (e) { re = null }
    patterns[p] = re
    return re
}

function releaseText(s: Stream): string { return (s.filename || "") + "\n" + s.title }

export function rank(list: Stream[]): Stream[] {
    const seen: { [k: string]: boolean } = {}
    const set = settings.all()
    const hidden = set.hidden.map(pattern).filter(function (r): r is RegExp { return !!r })
    const liked = set.preferred.map(pattern).filter(function (r): r is RegExp { return !!r })
    const out = list.filter(function (s) {
        const k = (s.filename || s.title) + "|" + s.size
        if (seen[k]) return false
        seen[k] = true
        s.warn = trouble(s)
        const t = releaseText(s)
        return s.warn !== "cam" && !hidden.some(function (r) { return r.test(t) })
    })
    const score = function (s: Stream): number {
        let n = 0
        if (!s.warn) n += 1e7
        if (s.cached === true) n += 4e6
        else if (s.cached === null) n += 2e6
        n += Math.min(s.resolution, maxResolution()) * 1000
        // over the limit: the closest one first
        if (s.warn === "level") n -= s.resolution * 10
        if (s.hdr.length && s.hdr[0] !== "DV" || s.hdr.length > 1) n += 500
        // a liked pattern lifts it within its tier (resolutions are 360000 apart), the first one most
        const t = releaseText(s)
        for (let i = 0; i < liked.length; i++) if (liked[i].test(t)) { n += (liked.length - i) * 1000; break }
        if (s.source === "Remux") n -= 200 // a remux is huge for what a tv's wifi can carry
        // bigger is better within a tier, to about 40 gb
        n += Math.min(s.size || 0, 40 * 1073741824) / 1073741824
        return n
    }
    out.sort(function (a, b) { return score(b) - score(a) })
    return out
}

export function sizeText(n: number | null): string {
    if (!n) return ""
    return n >= 1073741824 ? (n / 1073741824).toFixed(1) + " GB" : Math.round(n / 1048576) + " MB"
}
