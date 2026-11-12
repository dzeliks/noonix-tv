// sources: stremio addons (core stremio.rs, addons.rs, ranking.rs, cut down for a tv). a tv plays what an
// addon hands over as a link (debrid, http). torrents, once allowed, play through a streaming server
// (stremio's model: /<infohash>/<file index>): the tv's own engine (data/engine), or one set in settings
import { json } from "./http"
import * as store from "./store"
import * as settings from "./settings"
import * as engine from "./engine"
import * as speed from "./speed"
import * as memory from "./memory"
import { platform } from "../platform"
import * as look from "../ui/look"
import { address, parseRelease, parseSize, pattern } from "./release"

export { parseRelease, pattern }

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
    /** played through the streaming server */
    torrent: boolean
    seeders: number | null
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
    let url = address(raw)
    if (!/manifest\.json$/.test(url.split("?")[0])) url = url.replace(/\/$/, "") + "/manifest.json"
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
    let skipped = 0
    return Promise.all(asked.map(function (a) {
        const key = "streams:" + a.url + ":" + id
        return store.cached(key, 600, function () {
            return json({ url: base(a) + "/stream/" + kind + "/" + encodeURIComponent(id) + ".json", timeout: 14, retries: 0 })
                .then(function (v: any) { return (v && v.streams) || [] })
        }).then(function (list: any[]) {
            return list.map(function (s) {
                const st = normalize(a.name, s)
                if (st === "torrent") { skipped++; return null }
                return st
            }).filter(function (s): s is Stream { return !!s })
        }, function (e) {
            console.warn("streams " + a.name + ": " + e)
            return [] as Stream[]
        })
    })).then(function (lists) {
        torrentsSkipped = skipped
        torrentsWhy = settings.all().torrents !== true ? "allow" : "server"
        const ranked = rank(([] as Stream[]).concat.apply([], lists))
        return t.tmdb ? memory.order(t.kind, t.tmdb, ranked) : ranked
    })
}

let torrentsSkipped = 0
let torrentsWhy: "allow" | "server" = "allow"
/** torrent sources the last ask left out: torrents not allowed, or nowhere to play them (a browser) */
export function skippedTorrents(): number { return torrentsSkipped }
export function skippedWhy(): "allow" | "server" { return torrentsWhy }

/** a torrent source's info hash (infoHash, or a magnet link's btih), else null */
function hashOf(s: any): string | null {
    let hash = typeof s.infoHash === "string" ? s.infoHash : null
    if (!hash && typeof s.url === "string") {
        const m = /^magnet:\?.*xt=urn:btih:([0-9a-f]{40})/i.exec(s.url)
        if (m) hash = m[1]
    }
    return hash && /^[0-9a-f]{40}$/i.test(hash) ? hash.toLowerCase() : null
}

/** the streaming server's link for a torrent, the way stremio builds it: the file index (-1 = the server
 *  picks the biggest video), trackers as tr=, file name hints as f= */
export function torrentUrl(server: string, s: any, hash: string): string {
    const q: string[] = []
    const trackers: string[] = (s.sources || []).filter(function (t: any) { return typeof t === "string" })
    if (typeof s.url === "string" && s.url.indexOf("magnet:") === 0) {
        (s.url.match(/[?&]tr=[^&]+/g) || []).forEach(function (p: string) {
            try { trackers.push("tracker:" + decodeURIComponent(p.slice(4))) } catch (e) { /* a broken one */ }
        })
    }
    trackers.forEach(function (t) { q.push("tr=" + encodeURIComponent(t)) })
    ;(s.fileMustInclude || []).forEach(function (f: any) { if (typeof f === "string") q.push("f=" + encodeURIComponent(f)) })
    const idx = typeof s.fileIdx === "number" && s.fileIdx >= 0 ? s.fileIdx : -1
    return server + "/" + hash + "/" + idx + (q.length ? "?" + q.join("&") : "")
}

function normalize(addon: string, s: any): Stream | "torrent" | null {
    if (!s) return null
    const hash = typeof s.url === "string" && /^https?:/.test(s.url) ? null : hashOf(s)
    let url: string
    if (hash) {
        const server = engine.base()
        if (settings.all().torrents !== true || !server) return "torrent"
        url = torrentUrl(server, s, hash)
    } else if (typeof s.url === "string" && /^https?:/.test(s.url)) url = s.url
    else return null
    const hints = s.behaviorHints || {}
    // a <video> can't send the headers a proxied stream needs
    if (hints.proxyHeaders && hints.proxyHeaders.request) return null
    const name = s.name || ""
    const desc = s.description || s.title || ""
    const filename: string | null = hints.filename || null
    const text = name + "\n" + desc + "\n" + (filename || "")
    const st = parseRelease(text)
    st.addon = addon
    st.url = url
    st.torrent = !!hash
    const seed = /(?:👤|seeds?|seeders?)\s*:?\s*(\d+)/i.exec(text)
    st.seeders = seed ? parseInt(seed[1], 10) : null
    st.filename = filename
    st.title = filename || (desc.split("\n")[0] || name).trim()
    st.size = hints.videoSize || parseSize(text)
    st.bingeGroup = hints.bingeGroup || null
    const lower = text.toLowerCase()
    st.cached = hash ? null : text.indexOf("⚡") >= 0 || text.indexOf("+]") >= 0 || lower.indexOf("instant") >= 0 ? true
        : text.indexOf("⏳") >= 0 || lower.indexOf("download]") >= 0 || lower.indexOf("not ready") >= 0 ? false : null
    const svc = /\[(TB|RD|AD|PM|DL|ED|OC|PKP)\+?\]/.exec(text)
    st.service = svc ? svc[1].toUpperCase() : null
    return st
}

/** a streaming server answers there (stremio's server has /settings, as stremio web asks it) */
export function checkServer(url: string): Promise<void> {
    // noonix tv on a computer holds a new tv's first request while it asks there (a minute)
    return json({ url: url + "/settings", timeout: 65, retries: 0 }).then(function (v: any) {
        if (!v || typeof v !== "object") throw new Error("not a streaming server")
    })
}

// ---- ranking for this tv

declare const webapis: any

/** a full hd panel says so (samsung); lg's answer needs a service call, so it counts as 4k */
function fullHdPanel(): boolean {
    try { return typeof webapis !== "undefined" && webapis.productinfo && webapis.productinfo.isUdPanelSupported() === false } catch (e) { return false }
}

/** the tallest picture worth asking for here: the user's pick, else low memory and full hd tvs stay at
 *  1080p, and a speed check run here caps it to what the line carries */
export function maxResolution(): number {
    const q = settings.all().quality
    if (q !== "auto") return parseInt(q, 10)
    const tv = look.lowMemory || fullHdPanel() ? 1080 : 2160
    const line = speed.last()
    return line ? Math.min(tv, speed.fits(line.mbps)) : tv
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
        // a torrent comes after the links that are ready: it has to find people first; nearly nobody sharing, last
        // (below what any resolution adds, as the core's tier does: a 4k copy nobody shares stalls)
        else if (s.torrent) n += s.seeders !== null && s.seeders < 3 ? -3e6 : 1e6 + Math.min(s.seeders || 0, 500) * 100
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
