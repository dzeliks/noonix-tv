// what a release name tells, and the user's release patterns: the tv's port of the core's stremio.rs
// parse_release / parse_size and ranking.rs pattern. no imports that need a tv or a browser: the tests
// run it under node against the cases the core passes too (core/fixtures/release-names.json)
import type { Stream } from "./sources"

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
        source: source, cached: null, service: null, torrent: false, seeders: null, bingeGroup: null, languages: langs, warn: null,
    }
}

export function parseSize(text: string): number | null {
    const m = /(\d+(?:[.,]\d+)?)\s*(GB|MB|GiB|MiB)\b/i.exec(text)
    if (!m) return null
    const n = parseFloat(m[1].replace(",", "."))
    return Math.round(n * (/^g/i.test(m[2]) ? 1073741824 : 1048576))
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

/** a pasted address (stremio.rs address): stremio:// and stremio's share links, no scheme, stray line breaks */
export function address(input: string): string {
    const s = input.replace(/\s+/g, "")
    if (s.indexOf("#/addons") >= 0) {
        const enc = s.split("addon=")[1]
        if (enc !== undefined) {
            let d = ""
            try { d = decodeURIComponent(enc.split("&")[0]) } catch (e) { d = "" }
            if (d.indexOf("://") >= 0 && d.indexOf("#/addons") < 0) return address(d)
        }
    }
    if (s.indexOf("stremio://") === 0) return "https://" + s.slice(10)
    if (s && s.indexOf("://") < 0) return "https://" + s
    return s
}
