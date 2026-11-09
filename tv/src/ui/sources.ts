// the sources of a title (qml Sources): every addon's links, best first, with what they are
import { h, clear } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import { App, PlayReq, Screen } from "./app"
import * as tmdb from "../data/tmdb"
import * as sources from "../data/sources"

const rowH = 132
const visible = 6

function warnText(w: string): string {
    switch (w) {
        case "level": return tr("Too big for this TV")
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

    const back = h("img.backdrop", { alt: "" }) as HTMLImageElement
    const head = h("div.shead", null,
        h("div.stitle", { text: req.item.title }),
        h("div.ssub", { text: req.item.kind === "show" && req.season !== undefined
            ? "S" + req.season + " E" + req.episode + (req.episodeTitle ? "  ·  " + req.episodeTitle : "") : tr("Sources") }))
    const status = h("div.sstatus", { text: tr("Looking for sources…") })
    const track = h("div.strack")
    const listEl = h("div.slist", null, track)
    const el = h("div.sources", null, back, h("div.sshade"), head, status, listEl)

    const b = look.backdrop(req.item.backdrop)
    if (b) { back.onload = function () { back.className = "backdrop on" }; back.src = b }

    const imdb = req.imdb ? Promise.resolve(req.imdb) : tmdb.details(req.item.kind, req.item.id).then(function (d) { return d.imdb })
    imdb.then(function (id) {
        if (!id) throw new Error(tr("This title has no imdb id: addons can't look it up"))
        req.imdb = id
        return sources.streams({ kind: req.item.kind, imdb: id, season: req.season, episode: req.episode })
    }).then(function (got) {
        if (!alive) return
        list = got
        status.textContent = got.length ? "" : sources.addons().length ? tr("No sources found") : tr("No addons yet: add one in Settings")
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
            const line = [s.addon, sources.sizeText(s.size), s.codec || "", s.audio.slice(0, 2).join(" "), s.source || "",
                s.languages.filter(function (l) { return l !== "en" }).join(" ").toUpperCase()].filter(function (x) { return !!x }).join("  ·  ")
            const w = s.warn ? warnText(s.warn) : ""
            track.appendChild(h("div.srcrow", null, badges, h("div.stext", null,
                h("div.sname", { text: s.title }),
                h("div.sline", null, line, w ? h("span.warn", { text: "  ·  " + w }) : null))))
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
