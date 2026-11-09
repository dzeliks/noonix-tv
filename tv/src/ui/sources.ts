// the sources of a title (qml Sources): every addon's links, best first, with what they are
import { h, clear } from "./dom"
import { tr, trn } from "../i18n"
import { Action } from "../keys"
import { App, PlayReq, Screen } from "./app"
import * as tmdb from "../data/tmdb"
import * as sources from "../data/sources"
import * as settings from "../data/settings"
import * as memory from "../data/memory"

const rowH = 132
const visible = 5

function warnText(w: string): string {
    switch (w) {
        case "level": return settings.all().quality === "auto" ? tr("Too big for this TV") : tr("Above your picture quality")
        case "codec": return tr("This TV may not decode it")
        case "dv": return tr("Dolby Vision only: colours may be off")
        case "audio": return tr("No sound on this TV (DTS)")
    }
    return ""
}

export function sourcesScreen(app: App, req: PlayReq): Screen {
    let list: sources.Stream[] = []
    let at = 0
    let alive = true

    // a panel on the right over the page it came from (qml Sources: the glass sheet)
    const head = h("div.shead", null,
        h("div.stitle", { text: tr("Sources") }),
        h("div.ssub", { text: req.item.title + (req.item.kind === "show" && req.season !== undefined
            ? "  ·  S" + req.season + " E" + req.episode + (req.episodeTitle ? "  " + req.episodeTitle : "") : "") }))
    const status = h("div.sstatus", { text: tr("Looking for sources…") })
    const track = h("div.strack")
    const listEl = h("div.slist", null, track)
    const el = h("div.sources", null, h("div.spanel", null, head, status, listEl))

    const imdb = req.imdb ? Promise.resolve(req.imdb) : tmdb.details(req.item.kind, req.item.id).then(function (d) { return d.imdb })
    imdb.then(function (id) {
        if (!id) throw new Error(tr("This title has no imdb id: addons can't look it up"))
        req.imdb = id
        return sources.streams({ kind: req.item.kind, imdb: id, tmdb: req.item.id, season: req.season, episode: req.episode })
    }).then(function (got) {
        if (!alive) return
        list = got
        const skipped = sources.skippedTorrents()
        status.textContent = !sources.addons().length ? tr("No addons yet: add one in Settings")
            : skipped ? (got.length ? "" : tr("No sources found") + ". ") + (sources.skippedWhy() === "allow"
                ? trn("%n torrent source is hidden: allow torrents in Settings", skipped)
                : trn("%n torrent source needs a streaming server (Settings)", skipped))
            : got.length ? "" : tr("No sources found")
        // with sources listed the note goes under the title, out of the list's way
        if (got.length) status.className = "sstatus note"
        build()
    }).catch(function (e) {
        if (alive) status.textContent = String(e.message || e)
    })

    function badge(text: string, cls: string): HTMLElement { return h("span.badge" + (cls ? "." + cls : ""), { text: text }) }

    function build(): void {
        clear(track)
        list.forEach(function (s) {
            const badges = h("div.badges")
            badges.appendChild(badge(s.resolution >= 2160 ? "4K" : s.resolution ? s.resolution + "p" : "?", "res"))
            s.hdr.forEach(function (x) { badges.appendChild(badge(x, "hdr")) })
            if (s.cached === true) badges.appendChild(badge("⚡", "fast"))
            if (s.torrent) badges.appendChild(badge(s.seeders !== null ? "P2P · " + s.seeders : "P2P", ""))
            const line = [s.addon, sources.sizeText(s.size), s.codec || "", s.audio.slice(0, 2).join(" "), s.source || "",
                s.languages.filter(function (l) { return l !== "en" }).join(" ").toUpperCase()].filter(function (x) { return !!x }).join("  ·  ")
            // what the viewers said (how's this one?) before the tv's own warning
            const said = memory.isBad(s) ? h("span.warn", { text: "  ·  " + tr("Picture or sound problem") })
                : memory.isGood(req.item.kind, req.item.id, s) ? h("span.good", { text: "  ·  " + tr("Good match") }) : null
            const w = s.warn ? warnText(s.warn) : ""
            track.appendChild(h("div.srcrow", null, badges, h("div.stext", null,
                h("div.sname", { text: s.title }),
                h("div.sline", null, line, said, w ? h("span.warn", { text: "  ·  " + w }) : null))))
        })
        place()
    }

    function place(): void {
        const rows = track.childNodes
        for (let i = 0; i < rows.length; i++) (rows[i] as HTMLElement).className = "srcrow" + (i === at ? " lit" : "")
        const first = Math.max(0, Math.min(at - 2, list.length - visible))
        track.style.transform = track.style.webkitTransform = "translate3d(0," + (-first * rowH) + "px,0)"
    }

    function action(a: Action): boolean {
        if (a === "up" && at > 0) at--
        else if (a === "down" && at < list.length - 1) at++
        else if (a === "pageup") at = Math.max(0, at - visible)
        else if (a === "pagedown") at = Math.min(list.length - 1, at + visible)
        else if (a === "ok" && list[at]) {
            app.play({ item: req.item, imdb: req.imdb, season: req.season, episode: req.episode, episodeTitle: req.episodeTitle,
                start: req.start, stream: list[at], list: list.filter(function (s, i) { return i !== at }) })
            return true
        } else if (a === "back") return false
        else return true
        place()
        return true
    }

    return { el, action, closed(): void { alive = false } }
}
