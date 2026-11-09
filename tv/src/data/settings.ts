// settings and the user's own keys (localStorage: the tv keeps it per app)
import * as store from "./store"

export type LowMode = "auto" | "on" | "off"
/** the tallest picture to pick first: auto follows the tv */
export type Quality = "auto" | "2160" | "1080" | "720"

export interface Settings {
    lowMode: LowMode
    language: "en" | "sr"
    quality: Quality
    /** release patterns: words (whole, any case) or /a regex/; preferred lift, hidden drop */
    preferred: string[]
    hidden: string[]
    /** skip "who's watching?": open on the last profile */
    askProfile: boolean
    /** a stremio-compatible streaming server (stremio service, noonix tv on a computer): plays torrent
     *  sources for the tv, which has no torrent client of its own. "" = none */
    server: string
}

const defaults: Settings = { lowMode: "auto", language: "en", quality: "auto", preferred: [], hidden: [], askProfile: true, server: "" }

/** what the user typed, as a base url: "192.168.1.5" -> "http://192.168.1.5:11470" (stremio's port) */
export function serverUrl(typed: string): string {
    let t = typed.trim().replace(/\/+$/, "")
    if (!t) return ""
    if (!/^https?:\/\//i.test(t)) t = "http://" + t
    // no port: stremio's
    if (!/^https?:\/\/[^/]+:\d+/i.test(t) && /^http:/i.test(t)) t = t.replace(/^(http:\/\/[^/]+)/i, "$1:11470")
    return t
}

export function all(): Settings {
    const s = store.get<Partial<Settings>>("settings", {})
    const out = {} as Settings
    for (const k in defaults) (out as any)[k] = (s as any)[k] !== undefined ? (s as any)[k] : (defaults as any)[k]
    return out
}

export function put<K extends keyof Settings>(key: K, value: Settings[K]): void {
    const s = store.get<Partial<Settings>>("settings", {})
    s[key] = value
    store.set("settings", s)
}

/** an api key or token the user typed in (empty: the built-in one) */
export function secret(name: string): string {
    return store.get<{ [k: string]: string }>("secrets", {})[name] || ""
}

export function setSecret(name: string, value: string): void {
    const s = store.get<{ [k: string]: string }>("secrets", {})
    if (value) s[name] = value
    else delete s[name]
    store.set("secrets", s)
}
