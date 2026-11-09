// the home rows (core/src/home.rs): the lists a tv without a library or trakt can fill
import * as tmdb from "./tmdb"

export interface RowDef {
    id: string
    title: string
    style: "poster" | "landscape" | "episode"
    brand?: "netflix" | "max"
}

// TODO(F3c): up next, continue watching, recently played and the library once trakt and progress are in
export function rows(): RowDef[] {
    return [
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

export function row(id: string): Promise<tmdb.Item[]> {
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
