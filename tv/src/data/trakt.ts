// trakt (core trakt.rs, cut down): sign-in by device code, scrobbles, and where things were left
import { json, HttpError } from "./http"
import * as profiles from "./profiles"
import * as store from "./store"
import * as settings from "./settings"
import * as tmdb from "./tmdb"

declare const __TRAKT_ID__: string
declare const __TRAKT_SECRET__: string

const api = "https://api.trakt.tv"

interface Token { access: string; refresh: string; expires: number; user: string; client: string }

/** the app a sign-in uses: the user's own when typed in settings, else the built-in one */
function app(): { id: string; secret: string } {
    const own = settings.secret("trakt_id")
    return own ? { id: own, secret: settings.secret("trakt_secret") } : { id: __TRAKT_ID__, secret: __TRAKT_SECRET__ }
}

export function available(): boolean { return !!app().id }

function token(): Token | null { return store.get<Token | null>(profiles.key("trakt"), null) }

export function user(): string | null {
    const t = token()
    return t ? t.user || "trakt" : null
}

export function signOut(): void { store.remove(profiles.key("trakt")) }

function headers(t: Token | null): { [k: string]: string } {
    const h: { [k: string]: string } = { "trakt-api-version": "2", "trakt-api-key": t ? t.client : app().id }
    if (t) h.Authorization = "Bearer " + t.access
    return h
}

// ---- sign-in

export interface Code { device: string; user: string; url: string; interval: number; expires: number }

export function deviceCode(): Promise<Code> {
    return json({ url: api + "/oauth/device/code", method: "POST", body: { client_id: app().id }, headers: headers(null) })
        .then(function (v: any) {
            return { device: v.device_code, user: v.user_code, url: v.verification_url, interval: v.interval || 5, expires: v.expires_in || 600 }
        })
}

/** one poll: null while the code isn't typed yet; throws when it's over (expired, denied) */
export function poll(c: Code): Promise<string | null> {
    const a = app()
    const body: { [k: string]: string } = { code: c.device, client_id: a.id }
    if (a.secret) body.client_secret = a.secret
    return json({ url: api + "/oauth/device/token", method: "POST", body: body, headers: headers(null), retries: 0 })
        .then(function (v: any) {
            const t: Token = { access: v.access_token, refresh: v.refresh_token, expires: (v.created_at + v.expires_in) * 1000, user: "", client: a.id }
            store.set(profiles.key("trakt"), t)
            return json({ url: api + "/users/settings", headers: headers(t) }).then(function (s: any) {
                t.user = (s && s.user && (s.user.name || s.user.username)) || "trakt"
                store.set(profiles.key("trakt"), t)
                return t.user
            }, function () { return "trakt" })
        }, function (e: HttpError) {
            if (e.status === 400 || e.status === 429) return null
            throw new Error(e.status === 410 ? "expired" : e.status === 418 ? "denied" : e.status === 409 ? "used" : String(e))
        })
}

/** a token near its end gets a new one (tvs stay on for weeks) */
function fresh(): Promise<Token | null> {
    const t = token()
    if (!t) return Promise.resolve(null)
    if (t.expires - Date.now() > 7 * 86400000) return Promise.resolve(t)
    const a = app()
    const body: { [k: string]: string } = {
        refresh_token: t.refresh, client_id: t.client, grant_type: "refresh_token",
        redirect_uri: t.client === __TRAKT_ID__ ? "https://github.com/dzeliks/noonix-tv" : "urn:ietf:wg:oauth:2.0:oob",
    }
    if (a.secret && a.id === t.client) body.client_secret = a.secret
    return json({ url: api + "/oauth/token", method: "POST", body: body, headers: headers(null) }).then(function (v: any) {
        const n: Token = { access: v.access_token, refresh: v.refresh_token, expires: (v.created_at + v.expires_in) * 1000, user: t.user, client: t.client }
        store.set(profiles.key("trakt"), n)
        return n
    }, function (e: HttpError) {
        // refused for good: signed out
        if (e.status === 400 || e.status === 401) signOut()
        console.warn("trakt refresh: " + e)
        return null
    })
}

// ---- scrobbles

export interface Target { kind: tmdb.Kind; tmdb: number; imdb?: string | null; season?: number; episode?: number }

function target(t: Target): any {
    if (t.kind === "movie") {
        const ids: any = { tmdb: t.tmdb }
        if (t.imdb) ids.imdb = t.imdb
        return { movie: { ids: ids } }
    }
    return { show: { ids: { tmdb: t.tmdb } }, episode: { season: t.season || 0, number: t.episode || 0 } }
}

/** start, pause or stop at a share (0..1) */
export function scrobble(action: "start" | "pause" | "stop", t: Target, share: number): void {
    fresh().then(function (tok) {
        if (!tok) return
        const body = target(t)
        body.progress = Math.max(0, Math.min(100, share * 100))
        return json({ url: api + "/scrobble/" + action, method: "POST", body: body, headers: headers(tok), retries: 1 })
    }).catch(function (e: HttpError) {
        // 409: already scrobbled in the last hour
        if (e.status !== 409) console.warn("trakt scrobble " + action + ": " + e)
    })
}

/** marked watched by hand */
export function addHistory(t: Target): void {
    fresh().then(function (tok) {
        if (!tok) return
        const b = target(t)
        const body = t.kind === "movie" ? { movies: [b.movie] } : { shows: [{ ids: b.show.ids, seasons: [{ number: t.season, episodes: [{ number: t.episode }] }] }] }
        return json({ url: api + "/sync/history", method: "POST", body: body, headers: headers(tok) })
    }).catch(function (e) { console.warn("trakt history: " + e) })
}

/** paused playbacks on trakt (other devices too): continue watching */
export interface Paused { kind: tmdb.Kind; tmdb: number; season?: number; episode?: number; episodeTitle?: string; share: number; at: number }

export function paused(): Promise<Paused[]> {
    return fresh().then(function (tok) {
        if (!tok) return []
        return store.cached("trakt:playback:" + tok.user, 300, function () {
            return json({ url: api + "/sync/playback?limit=30", headers: headers(tok) })
        }).then(function (list: any[]) {
            return (list || []).map(function (p: any): Paused | null {
                const show = p.type === "episode"
                const ids = show ? p.show && p.show.ids : p.movie && p.movie.ids
                if (!ids || !ids.tmdb) return null
                return {
                    kind: show ? "show" : "movie", tmdb: ids.tmdb, share: (p.progress || 0) / 100, at: Date.parse(p.paused_at) || 0,
                    season: show ? p.episode.season : undefined, episode: show ? p.episode.number : undefined,
                    episodeTitle: show ? p.episode.title : undefined,
                }
            }).filter(function (x): x is Paused { return !!x })
        })
    })
}
