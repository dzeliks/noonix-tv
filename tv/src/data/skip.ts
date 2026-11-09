// intro, recap and credits of an episode (core skip.rs: the introdb part; tvs have no chapters)
import { json } from "./http"
import * as store from "./store"

export interface Segment { kind: "intro" | "recap" | "outro"; start: number; end: number }

export function segments(imdb: string, season: number, episode: number): Promise<Segment[]> {
    return store.cached("introdb:" + imdb + ":" + season + ":" + episode, 7 * 86400, function () {
        return json({ url: "https://api.introdb.app/segments?imdb_id=" + imdb + "&season=" + season + "&episode=" + episode, timeout: 6, retries: 0 })
    }).then(function (v: any) {
        const out: Segment[] = []
        const kinds: Segment["kind"][] = ["intro", "recap", "outro"]
        kinds.forEach(function (k) {
            const s = v && v[k]
            if (s && typeof s.start_sec === "number" && s.end_sec > s.start_sec) out.push({ kind: k, start: s.start_sec, end: s.end_sec })
        })
        return out
    }, function () { return [] as Segment[] })
}
