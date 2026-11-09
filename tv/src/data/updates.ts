// a new version (qml Settings › Updates): a tv can't install it itself, so it only says so
import { json } from "./http"
import * as store from "./store"

declare const __VERSION__: string

/** the latest release's version, looked up once a day; null when github can't say */
export function latest(): Promise<string | null> {
    // only the tag is kept: the release itself lists every asset
    return store.cached("update:tag", 86400, function () {
        return json({ url: "https://api.github.com/repos/dzeliks/noonix-tv/releases/latest", timeout: 15, retries: 0 }).then(function (v: any) {
            return v && v.tag_name ? String(v.tag_name).replace(/^v/, "") : null
        })
    }).then(function (v) { return v || null }, function () { return null })
}

/** a newer than b, by numbers (0.4.10 > 0.4.9) */
export function newer(a: string, b: string): boolean {
    const x = a.split(/[.-]/), y = b.split(/[.-]/)
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        const p = parseInt(x[i] || "0", 10) || 0, q = parseInt(y[i] || "0", 10) || 0
        if (p !== q) return p > q
    }
    return false
}

/** a version newer than this one, once per version: told at start */
export function announce(say: (version: string) => void): void {
    latest().then(function (v) {
        if (!v || !newer(v, __VERSION__) || store.get<string>("updateTold", "") === v) return
        store.set("updateTold", v)
        say(v)
    })
}
