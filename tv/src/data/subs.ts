// subtitles a video doesn't have (core subtitles.rs, cut down): stremio's opensubtitles addon and the
// user's own subtitle addons; srt/vtt parsed here and drawn by the player, so avplay and <video> alike
import { json, send } from "./http"
import * as store from "./store"
import * as sources from "./sources"

export interface Found { id: string; lang: string; url: string; name: string; addon: string }
export interface Cue { start: number; end: number; text: string }

const opensubs = "https://opensubtitles-v3.strem.io"

// the ones offered in settings: iso 639-2 as the addons send them
export const languages: { code: string; name: string }[] = [
    { code: "eng", name: "English" }, { code: "srp", name: "Srpski / Hrvatski / Bosanski" }, { code: "ger", name: "Deutsch" },
    { code: "spa", name: "Español" }, { code: "fre", name: "Français" }, { code: "ita", name: "Italiano" },
    { code: "por", name: "Português" }, { code: "dut", name: "Nederlands" }, { code: "pol", name: "Polski" },
    { code: "rus", name: "Русский" }, { code: "tur", name: "Türkçe" }, { code: "gre", name: "Ελληνικά" },
    { code: "hun", name: "Magyar" }, { code: "rum", name: "Română" }, { code: "slv", name: "Slovenščina" },
    { code: "mac", name: "Македонски" }, { code: "bul", name: "Български" }, { code: "ara", name: "العربية" },
]

// one choice, the neighbours count too (balkan mode is always on here)
const same: { [code: string]: string[] } = {
    srp: ["srp", "scc", "hrv", "scr", "bos", "cnr"], ger: ["ger", "deu"], fre: ["fre", "fra"], dut: ["dut", "nld"],
    gre: ["gre", "ell"], rum: ["rum", "ron"], mac: ["mac", "mkd"], por: ["por", "pob"], eng: ["eng", "en"],
}

export function matches(choice: string, lang: string): boolean {
    return (same[choice] || [choice]).indexOf(lang) >= 0
}

export function languageName(lang: string): string {
    for (let i = 0; i < languages.length; i++) if (matches(languages[i].code, lang)) return languages[i].name.split(" / ")[0]
    return lang.toUpperCase()
}

/** "" is off */
export function preferred(): string { return store.get<string>("subLang", "") }
export function setPreferred(code: string): void { store.set("subLang", code) }

/** every subtitle the addons know for it; a slow or broken addon is left out */
export function find(t: sources.Target): Promise<Found[]> {
    const kind = t.kind === "movie" ? "movie" : "series"
    const id = t.kind === "movie" ? t.imdb : t.imdb + ":" + (t.season || 0) + ":" + (t.episode || 0)
    const bases = [{ base: opensubs, name: "OpenSubtitles" }].concat(sources.addons().filter(function (a) {
        return a.on && a.resources.indexOf("subtitles") >= 0 && a.url.indexOf(opensubs) < 0
    }).map(function (a) { return { base: a.url.replace(/\/manifest\.json$/, ""), name: a.name } }))
    return Promise.all(bases.map(function (b) {
        return store.cached("subs:" + b.base + ":" + id, 3600, function () {
            return json({ url: b.base + "/subtitles/" + kind + "/" + encodeURIComponent(id) + ".json", timeout: 12, retries: 0 })
        }).then(function (v: any) {
            return ((v && v.subtitles) || []).filter(function (s: any) { return s && s.url && /^https?:/.test(s.url) }).map(function (s: any): Found {
                return { id: String(s.id || s.url), lang: String(s.lang || "und").toLowerCase(), url: s.url, name: s.subtitleFileName || s.movieReleaseName || "", addon: b.name }
            })
        }, function () { return [] as Found[] })
    })).then(function (lists) {
        const out: Found[] = []
        const seen: { [u: string]: boolean } = {}
        lists.forEach(function (l: Found[]) { l.forEach(function (f: Found) { if (!seen[f.url]) { seen[f.url] = true; out.push(f) } }) })
        return out
    })
}

function words(s: string): string[] {
    return s.toLowerCase().replace(/\.[a-z0-9]{2,4}$/, "").split(/[^a-z0-9]+/).filter(function (w) { return w.length > 1 })
}

/** of one language, the closest to the release playing first (same group and source: the timing fits) */
export function best(found: Found[], choice: string, release: string): Found[] {
    const mine = words(release)
    const score = function (f: Found): number {
        const theirs = words(f.name)
        let n = 0
        for (let i = 0; i < theirs.length; i++) if (mine.indexOf(theirs[i]) >= 0) n++
        return n
    }
    return found.filter(function (f) { return matches(choice, f.lang) })
        .map(function (f, i) { return { f: f, s: score(f), i: i } })
        .sort(function (a, b) { return b.s - a.s || a.i - b.i })
        .map(function (x) { return x.f })
}

const parsed: { [url: string]: Cue[] } = {}

export function load(url: string): Promise<Cue[]> {
    if (parsed[url]) return Promise.resolve(parsed[url])
    return send({ url: url, timeout: 20, retries: 1, utf8: true }).then(function (text) {
        const cues = parse(unmangle(text))
        if (!cues.length) throw new Error("no cues")
        parsed[url] = cues
        return cues
    })
}

// cp1252's 0x80-0x9f, as the characters they turn into
const cp1252: { [ch: string]: number } = {
    "\u20ac": 0x80, "\u201a": 0x82, "\u0192": 0x83, "\u201e": 0x84, "\u2026": 0x85, "\u2020": 0x86, "\u2021": 0x87, "\u02c6": 0x88,
    "\u2030": 0x89, "\u0160": 0x8a, "\u2039": 0x8b, "\u0152": 0x8c, "\u017d": 0x8e, "\u2018": 0x91, "\u2019": 0x92, "\u201c": 0x93,
    "\u201d": 0x94, "\u2022": 0x95, "\u2013": 0x96, "\u2014": 0x97, "\u02dc": 0x98, "\u2122": 0x99, "\u0161": 0x9a, "\u203a": 0x9b,
    "\u0153": 0x9c, "\u017e": 0x9e, "\u0178": 0x9f,
}

/** utf-8 that was read as cp1252 and saved again ("â™ª" for "♪"): put back; anything else stays */
export function unmangle(text: string): string {
    if (!/[\u00c2-\u00f4][\u0080-\u00bf\u0152-\u2122]/.test(text)) return text
    let enc = ""
    for (let i = 0; i < text.length; i++) {
        const c = text.charCodeAt(i)
        const b = c < 0x100 ? c : cp1252[text.charAt(i)]
        // a real character past latin-1: not mangled after all
        if (b === undefined) return text
        enc += b < 0x80 && b !== 0x25 ? text.charAt(i) : "%" + (b < 16 ? "0" : "") + b.toString(16)
    }
    try { return decodeURIComponent(enc) } catch (e) { return text }
}

function secs(t: string): number {
    const m = /(?:(\d+):)?(\d+):(\d+)[,.](\d+)/.exec(t)
    if (!m) return -1
    return (m[1] ? parseInt(m[1], 10) * 3600 : 0) + parseInt(m[2], 10) * 60 + parseInt(m[3], 10) + parseInt((m[4] + "00").slice(0, 3), 10) / 1000
}

/** srt or vtt */
export function parse(text: string): Cue[] {
    const out: Cue[] = []
    const blocks = text.replace(/^﻿/, "").replace(/\r/g, "").split(/\n\s*\n/)
    for (let i = 0; i < blocks.length; i++) {
        const lines = blocks[i].split("\n").filter(function (l) { return l.trim() !== "" })
        let k = 0
        while (k < lines.length && lines[k].indexOf("-->") < 0) k++
        if (k >= lines.length) continue
        const parts = lines[k].split("-->")
        const start = secs(parts[0]), end = secs(parts[1])
        if (start < 0 || end <= start) continue
        const body = lines.slice(k + 1).join("\n")
            .replace(/<[^>]+>/g, "").replace(/\{\\[^}]*\}/g, "")
            .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").trim()
        if (body) out.push({ start: start, end: end, text: body })
    }
    return out.sort(function (a, b) { return a.start - b.start })
}

/** the line(s) showing at t */
export function at(cues: Cue[], t: number): string {
    let lo = 0, hi = cues.length - 1, hit = -1
    while (lo <= hi) {
        const m = (lo + hi) >> 1
        if (cues[m].start <= t) { hit = m; lo = m + 1 } else hi = m - 1
    }
    const out: string[] = []
    // overlapping cues: the few before the last start can still be on
    for (let i = hit; i >= 0 && i > hit - 4; i--) if (cues[i].end > t) out.unshift(cues[i].text)
    return out.join("\n")
}
