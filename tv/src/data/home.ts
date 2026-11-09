// the home rows (core/src/home.rs): the lists a tv without a library or trakt can fill
import * as tmdb from "./tmdb"
import * as progress from "./progress"
import * as trakt from "./trakt"

export interface RowDef {
    id: string
    title: string
    style: "poster" | "landscape" | "episode"
    brand?: "netflix" | "max"
}

/** rows filled from what's kept on the tv (and trakt): asked again whenever home comes back */
export function isLocal(id: string): boolean { return /^(continue|upnext|library|watchlist|history)/.test(id) }

export function rows(): RowDef[] {
    return [
        { id: "continue", title: "Continue Watching", style: "landscape" },
        { id: "upnext", title: "Up Next", style: "episode" },
        { id: "library", title: "My List", style: "poster" },
        { id: "popular-tv", title: "Popular TV Shows", style: "poster" },
        { id: "popular-movie", title: "Popular Movies", style: "poster" },
        { id: "trending-tv", title: "Trending Shows", style: "poster" },
        { id: "trending-movie", title: "Trending Movies", style: "poster" },
        { id: "netflix-tv", title: "Netflix Shows", style: "poster", brand: "netflix" },
        { id: "netflix-movie", title: "Netflix Movies", style: "poster", brand: "netflix" },
        { id: "max-tv", title: "Max Shows", style: "poster", brand: "max" },
        { id: "max-movie", title: "Max Movies", style: "poster", brand: "max" },
    ]
}

export function movieRows(): RowDef[] {
    return [
        { id: "popular-movie", title: "Popular", style: "poster" },
        { id: "trending-movie", title: "Trending", style: "poster" },
        { id: "netflix-movie", title: "Netflix", style: "poster", brand: "netflix" },
        { id: "max-movie", title: "Max", style: "poster", brand: "max" },
        { id: "genre-movie-28", title: "Action", style: "poster" },
        { id: "genre-movie-35", title: "Comedy", style: "poster" },
        { id: "genre-movie-53", title: "Thriller", style: "poster" },
        { id: "genre-movie-878", title: "Science Fiction", style: "poster" },
        { id: "genre-movie-16", title: "Animation", style: "poster" },
    ]
}

export function showRows(): RowDef[] {
    return [
        { id: "popular-tv", title: "Popular", style: "poster" },
        { id: "trending-tv", title: "Trending", style: "poster" },
        { id: "netflix-tv", title: "Netflix", style: "poster", brand: "netflix" },
        { id: "max-tv", title: "Max", style: "poster", brand: "max" },
        { id: "genre-tv-18", title: "Drama", style: "poster" },
        { id: "genre-tv-35", title: "Comedy", style: "poster" },
        { id: "genre-tv-80", title: "Crime", style: "poster" },
        { id: "genre-tv-10765", title: "Sci-Fi & Fantasy", style: "poster" },
        { id: "genre-tv-16", title: "Animation", style: "poster" },
    ]
}

export function libraryRows(): RowDef[] {
    const out: RowDef[] = [
        { id: "continue", title: "Continue Watching", style: "landscape" },
        { id: "library-show", title: "Shows", style: "poster" },
        { id: "library-movie", title: "Movies", style: "poster" },
    ]
    if (trakt.user()) out.push({ id: "watchlist", title: "Watchlist", style: "poster" })
    out.push({ id: "history", title: "Recently watched", style: "poster" })
    return out
}

/** local progress first, then what trakt has paused elsewhere */
function continuing(): Promise<tmdb.Item[]> {
    const local = progress.continuing().map(function (p) { return p.item })
    const seen: { [k: string]: boolean } = {}
    local.forEach(function (it) { seen[it.kind + ":" + it.id] = true })
    return trakt.paused().then(function (list) {
        const more = list.filter(function (p) { return !seen[p.kind + ":" + p.tmdb] }).slice(0, 10)
        return Promise.all(more.map(function (p) {
            seen[p.kind + ":" + p.tmdb] = true
            return tmdb.details(p.kind, p.tmdb).then(function (d) {
                // kept like a local one, so play resumes there
                progress.save({ item: d, season: p.season, episode: p.episode, episodeTitle: p.episodeTitle,
                    position: 0, duration: 0, share: p.share, updated: 0, finished: false })
                return d as tmdb.Item
            }, function () { return null })
        }))
    }, function () { return [] as (tmdb.Item | null)[] }).then(function (got: (tmdb.Item | null)[]) {
        const out = local.slice()
        got.forEach(function (x) { if (x) out.push(x) })
        return out
    })
}

export function row(id: string): Promise<tmdb.Item[]> {
    if (id === "continue") return continuing()
    if (id === "upnext") {
        const going: { [k: string]: boolean } = {}
        progress.continuing().forEach(function (p) { going[p.item.kind + ":" + p.item.id] = true })
        return Promise.resolve(progress.upNext().map(function (p) { return p.item }).filter(function (it) { return !going[it.kind + ":" + it.id] }))
    }
    if (id === "library") return Promise.resolve(progress.library())
    if (id === "history") return Promise.resolve(progress.history())
    if (id === "watchlist") {
        return trakt.watchlist().then(function (list) {
            return Promise.all(list.slice(0, 30).map(function (w) {
                return tmdb.details(w.kind, w.tmdb).then(function (d) { return d as tmdb.Item }, function () { return null })
            }))
        }).then(function (got: (tmdb.Item | null)[]) {
            const out: tmdb.Item[] = []
            got.forEach(function (x) { if (x) out.push(x) })
            return out
        })
    }
    if (id === "library-show" || id === "library-movie") {
        const k = id === "library-show" ? "show" : "movie"
        return Promise.resolve(progress.library().filter(function (it) { return it.kind === k }))
    }
    const parts = id.split("-")
    const kind: tmdb.Kind = parts[1] === "tv" ? "show" : "movie"
    switch (parts[0]) {
        case "popular": return tmdb.popular(kind)
        case "trending": return tmdb.trending(kind)
        case "toprated": return tmdb.topRated(kind)
        // tmdb watch providers: 8 netflix, 1899 max
        case "netflix": return tmdb.discover(kind, [8], null)
        case "max": return tmdb.discover(kind, [1899], null)
        case "genre": return tmdb.discover(kind, [], parseInt(parts[2], 10))
    }
    return Promise.reject(new Error("unknown row " + id))
}
