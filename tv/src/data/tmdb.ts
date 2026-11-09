// tmdb: the lists, details and art (core/src/tmdb.rs, the same shapes)
import { json, query, HttpError } from "./http"
import { cached } from "./store"
import * as settings from "./settings"

const api = "https://api.themoviedb.org/3"
export const imgBase = "https://image.tmdb.org/t/p/"
export const region = "RS"
const lang = "en-US"

// ttl, seconds
const ttlList = 6 * 3600
const ttlDetails = 3 * 86400
const ttlSeason = 12 * 3600

export type Kind = "movie" | "show"

export interface Item {
    kind: Kind
    id: number
    title: string
    year: number | null
    date: string | null
    overview: string
    poster: string | null
    backdrop: string | null
    rating: number | null
    genres: string[]
    originalLanguage?: string
}

export interface Details extends Item {
    logo: string | null
    imdb: string | null
    certification: string | null
    tagline: string | null
    titles: string[]
    cast: { name: string; role: string; photo: string | null }[]
    more: Item[]
    runtime: number | null
    network?: string | null
    status?: string | null
    seasons?: { number: number; name: string; episodes: number; poster: string | null; airDate: string | null }[]
    nextAir?: EpisodeBrief | null
    lastAir?: EpisodeBrief | null
}

export interface EpisodeBrief { season: number; episode: number; title: string; airDate: string | null }

export interface Episode {
    kind: "episode"
    show: number
    season: number
    episode: number
    episodeTitle: string
    overview: string
    still: string | null
    airDate: string | null
    runtime: number | null
    rating: number | null
}

/** tmdb said no to the key this run: settings offers your own */
export let refused = false
const refusedListeners: (() => void)[] = []
export function onRefused(fn: () => void): void { refusedListeners.push(fn) }

function get(path: string, q: [string, string | number][], ttl: number): Promise<any> {
    const key = "tmdb:" + path + "?" + q.map(function (p) { return p[0] + "=" + p[1] }).join("&")
    return cached(key, ttl, function () {
        const pairs: [string, string | number][] = [["language", lang]]
        const own = settings.secret("tmdbApiKey")
        const apiKey = own || __TMDB_KEY__
        const headers: { [k: string]: string } = {}
        if (apiKey) pairs.push(["api_key", apiKey])
        else if (__TMDB_TOKEN__) headers.authorization = "Bearer " + __TMDB_TOKEN__
        else return Promise.reject(new Error("no tmdb key"))
        return json({ url: api + path + "?" + query(pairs.concat(q)), headers: headers }).catch(function (e: HttpError) {
            if (e.status === 401 && !refused) {
                refused = true
                refusedListeners.forEach(function (f) { f() })
            }
            throw e
        })
    })
}

declare const __TMDB_KEY__: string
declare const __TMDB_TOKEN__: string

export function img(path: string | null | undefined, size: string): string | null {
    return path ? imgBase + size + path : null
}

function yearOf(date: string | null | undefined): number | null {
    const y = date ? parseInt(date.slice(0, 4), 10) : NaN
    return isNaN(y) ? null : y
}

const genreNames: { [id: number]: string } = {
    28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
    10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
    878: "Science Fiction", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western", 10759: "Action & Adventure",
    10762: "Kids", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk",
    10768: "War & Politics",
}

/** one shape for every list and card */
export function item(kind: Kind, v: any): Item {
    const movie = kind === "movie"
    const date: string | null = (movie ? v.release_date : v.first_air_date) || null
    const genres: string[] = v.genres
        ? v.genres.map(function (g: { name: string }) { return g.name })
        : (v.genre_ids || []).map(function (id: number) { return genreNames[id] }).filter(function (n: string) { return !!n })
    return {
        kind: movie ? "movie" : "show",
        id: v.id,
        title: (movie ? v.title : v.name) || v.title || v.name || "",
        year: yearOf(date),
        date: date,
        overview: v.overview || "",
        poster: img(v.poster_path, "w500"),
        backdrop: img(v.backdrop_path, "w1280"),
        rating: typeof v.vote_average === "number" ? Math.round(v.vote_average * 10) / 10 : null,
        genres: genres,
        originalLanguage: v.original_language,
    }
}

// dev: NOONIX_HIDE keeps titles out of tests and screenshots
const hidden: number[] = String(__HIDE__).split(",").map(function (s) { return parseInt(s, 10) }).filter(function (n) { return !isNaN(n) })
declare const __HIDE__: string

function listed(r: any): boolean {
    return !!r.poster_path && hidden.indexOf(r.id) < 0
}

function results(kind: Kind, v: any): Item[] {
    return ((v && v.results) || []).filter(listed).map(function (r: any) { return item(kind, r) })
}

const pathKind = function (kind: Kind): string { return kind === "movie" ? "movie" : "tv" }

export function popular(kind: Kind, page?: number): Promise<Item[]> {
    return get("/" + pathKind(kind) + "/popular", [["page", page || 1], ["region", region]], ttlList)
        .then(function (v) { return results(kind, v) })
}

export function trending(kind: Kind): Promise<Item[]> {
    return get("/trending/" + pathKind(kind) + "/week", [], ttlList).then(function (v) { return results(kind, v) })
}

export function topRated(kind: Kind): Promise<Item[]> {
    return get("/" + pathKind(kind) + "/top_rated", [["region", region]], ttlList).then(function (v) { return results(kind, v) })
}

/** discover with optional watch providers and genre */
export function discover(kind: Kind, providers: number[], genre: number | null, page?: number): Promise<Item[]> {
    const q: [string, string | number][] = [["sort_by", "popularity.desc"], ["page", page || 1]]
    if (providers.length) {
        q.push(["with_watch_providers", providers.join("|")])
        q.push(["watch_region", region])
    }
    if (genre) q.push(["with_genres", genre])
    return get("/discover/" + pathKind(kind), q, ttlList).then(function (v) { return results(kind, v) })
}

export function search(text: string): Promise<Item[]> {
    return get("/search/multi", [["query", text], ["include_adult", "false"]], 3600).then(function (v) {
        const out: Item[] = []
        ;((v && v.results) || []).forEach(function (r: any) {
            if (!listed(r)) return
            if (r.media_type === "movie") out.push(item("movie", r))
            else if (r.media_type === "tv") out.push(item("show", r))
        })
        return out
    })
}

function pickLogo(images: any): string | null {
    const logos: any[] = (images && images.logos) || []
    let best: any = null
    logos.forEach(function (l) {
        if (l.iso_639_1 === "en" && (!best || (l.vote_average || 0) > (best.vote_average || 0))) best = l
    })
    if (!best) best = logos[0]
    // svg logos come as .svg: the png renders better at size
    return best ? img(String(best.file_path).replace(".svg", ".png"), "w500") : null
}

/** a textless backdrop when there is one (hero art), else the default. sized for the tv's 1080p page */
function pickBackdrop(v: any): string | null {
    const backs: any[] = (v.images && v.images.backdrops) || []
    let textless: string | null = null
    for (let i = 0; i < backs.length; i++) {
        if (backs[i].iso_639_1 === null) { textless = backs[i].file_path; break }
    }
    return img(textless || v.backdrop_path, "w1280")
}

function certification(kind: Kind, v: any): string | null {
    const list: any[] = kind === "movie"
        ? (v.release_dates && v.release_dates.results) || []
        : (v.content_ratings && v.content_ratings.results) || []
    const regions = [region, "US", "GB"]
    for (let i = 0; i < regions.length; i++) {
        const r = list.filter(function (x) { return x.iso_3166_1 === regions[i] })[0]
        if (!r) continue
        if (kind === "movie") {
            const d = (r.release_dates || []).filter(function (x: any) { return !!x.certification })[0]
            if (d) return d.certification
        } else if (r.rating) {
            return r.rating
        }
    }
    return null
}

function brief(e: any): EpisodeBrief | null {
    return e ? { season: e.season_number, episode: e.episode_number, title: e.name, airDate: e.air_date || null } : null
}

export function details(kind: Kind, id: number): Promise<Details> {
    const append = kind === "movie"
        ? "images,external_ids,credits,release_dates,recommendations,alternative_titles"
        : "images,external_ids,credits,content_ratings,recommendations,alternative_titles"
    return get("/" + pathKind(kind) + "/" + id, [["append_to_response", append], ["include_image_language", "en,null"]], ttlDetails)
        .then(function (v) {
            const base = item(kind, v)
            const titles: string[] = []
            ;[v.title, v.name, v.original_title, v.original_name].forEach(function (t) { if (t && titles.indexOf(t) < 0) titles.push(t) })
            const alt = v.alternative_titles && (v.alternative_titles.titles || v.alternative_titles.results) || []
            alt.forEach(function (t: any) { if (t.title && titles.indexOf(t.title) < 0) titles.push(t.title) })
            const d: Details = {
                kind: base.kind, id: base.id, title: base.title, year: base.year, date: base.date, overview: base.overview,
                poster: base.poster, backdrop: pickBackdrop(v), rating: base.rating, genres: base.genres,
                originalLanguage: base.originalLanguage,
                logo: pickLogo(v.images),
                imdb: (v.external_ids && v.external_ids.imdb_id) || null,
                certification: certification(kind, v),
                tagline: v.tagline || null,
                titles: titles,
                cast: ((v.credits && v.credits.cast) || []).slice(0, 15).map(function (p: any) {
                    return { name: p.name, role: p.character, photo: img(p.profile_path, "w185") }
                }),
                more: results(kind, v.recommendations),
                runtime: null,
            }
            if (kind === "movie") {
                d.runtime = v.runtime || null
            } else {
                d.runtime = (v.episode_run_time && v.episode_run_time[0]) || (v.last_episode_to_air && v.last_episode_to_air.runtime) || null
                d.network = (v.networks && v.networks[0] && v.networks[0].name) || null
                d.status = v.status || null
                d.seasons = (v.seasons || []).filter(function (s: any) { return s.season_number > 0 }).map(function (s: any) {
                    return { number: s.season_number, name: s.name, episodes: s.episode_count, poster: img(s.poster_path, "w342"), airDate: s.air_date || null }
                })
                d.nextAir = brief(v.next_episode_to_air)
                d.lastAir = brief(v.last_episode_to_air)
            }
            return d
        })
}

export function episode(show: number, e: any): Episode {
    return {
        kind: "episode", show: show, season: e.season_number, episode: e.episode_number, episodeTitle: e.name,
        overview: e.overview || "", still: img(e.still_path, "w780"), airDate: e.air_date || null,
        runtime: e.runtime || null, rating: e.vote_average || null,
    }
}

export function season(show: number, n: number): Promise<{ number: number; name: string; episodes: Episode[] }> {
    return get("/tv/" + show + "/season/" + n, [], ttlSeason).then(function (v) {
        return { number: n, name: v.name, episodes: (v.episodes || []).map(function (e: any) { return episode(show, e) }) }
    })
}
