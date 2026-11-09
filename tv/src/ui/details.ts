// a movie or a show (qml Details): backdrop, logo, meta, the story, actions, seasons + episodes, more like this
import { h, clear } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import { icon } from "./icons"
import { metaLine, length, day } from "./meta"
import { strip, step } from "./strip"
import { Screen, posterKind } from "./home"
import * as tmdb from "../data/tmdb"

type Part = "actions" | "seasons" | "episodes" | "more"

// the episode row's two text lines end this far above the screen edge; what sits under the story
const edge = 44
const underInfo = 90 + 60 + 225 + 92 + 4 * 34

export function detailsScreen(item: tmdb.Item, open: (it: tmdb.Item) => void): Screen {
    const isMovie = item.kind === "movie"
    let details: tmdb.Details | null = null
    let seasonNo = 1
    let seasonAt = 0
    let part: Part = "actions"
    let button = 0
    let alive = true

    const back = h("img.backdrop", { alt: "" }) as HTMLImageElement
    const logo = h("img.logo", { alt: "" }) as HTMLImageElement
    const title = h("div.title", { text: item.title })
    const meta = h("div.meta")
    const tagline = h("div.tagline")
    const plot = h("div.plot", { text: item.overview })
    const starring = h("div.starring")
    const facts = h("div.facts")
    const identity = h("div.identity", null, h("div.logobox", null, logo, title), meta)
    const story = h("div.story", null, tagline, plot, starring, facts)
    const spacer = h("div.spacer")
    const info = h("div.info", null, identity, story)

    const buttons = h("div.actions")
    const seasonsEl = h("div.seasons")
    const episodes = strip<tmdb.Episode>({
        width: 400, gap: 44, cls: "wide",
        art: function (e) { return look.still(e.still) },
        lines: function (e) {
            const sub = [e.runtime ? length(e.runtime) : "", day(e.airDate, true)].filter(function (x) { return !!x }).join("  ·  ")
            return [
                h("div.label", { text: e.episode + ".  " + (e.episodeTitle || tr("Episode %1", e.episode)) }),
                h("div.sublabel", { text: sub }),
            ]
        },
    })
    const episodesEl = h("div.episodes", null, episodes.track)
    const more = strip(posterKind)
    const moreEl = h("div.more", null, h("div.rowtitle", { text: tr("More Like This") }), more.track)
    const body = h("div.body", null, spacer, info, buttons, seasonsEl, episodesEl, moreEl)

    const el = h("div.details", null, back, h("div.shade-side"), h("div.shade-low"), body)

    // ---- what's on it

    metaLine(meta, item, null)
    setBackdrop(item.backdrop)
    episodesEl.style.display = seasonsEl.style.display = "none"
    moreEl.style.display = "none"

    function setBackdrop(url: string | null): void {
        const u = look.backdrop(url)
        if (!u || back.getAttribute("data-src") === u) return
        back.setAttribute("data-src", u)
        back.className = "backdrop"
        back.onload = function () { back.className = "backdrop on" }
        back.src = u
    }

    tmdb.details(item.kind, item.id).then(function (d) {
        if (!alive) return
        details = d
        setBackdrop(d.backdrop || item.backdrop)
        if (d.logo) {
            logo.onload = function () { logo.style.display = "block"; title.style.display = "none" }
            logo.src = d.logo
        }
        metaLine(meta, item, d)
        tagline.textContent = d.tagline || ""
        plot.textContent = d.overview || item.overview
        const cast = d.cast.slice(0, 4).map(function (c) { return c.name }).join(", ")
        starring.textContent = cast ? tr("Starring %1", cast) : ""
        facts.textContent = factLine(d)
        if (d.seasons && d.seasons.length) {
            buildSeasons(d.seasons)
            loadSeason(d.seasons[0].number, 0)
        }
        more.fill(d.more)
        moreEl.style.display = d.more.length ? "" : "none"
        layout()
        place()
    }, function (e) {
        console.warn("details " + item.kind + " " + item.id + ": " + e)
    })

    function factLine(d: tmdb.Details): string {
        const f: string[] = []
        if (d.network) f.push(d.network)
        if (d.nextAir && d.nextAir.airDate) f.push(tr("New episode %1", day(d.nextAir.airDate, false)))
        else if (d.status && d.status !== "Released" && d.status !== "Returning Series") f.push(tr(d.status))
        return f.join("  ·  ")
    }

    // ---- actions (play, sources)

    // TODO(F3e): play, start over, sources, library once the player and the addons are in
    const actionDefs = [
        { id: "play", icon: "play", label: function () {
            // nothing watched yet (no progress before trakt): a show starts at its first episode
            const first = details && details.seasons && details.seasons[0]
            return tr("Play") + (first ? "  S" + first.number + " E1" : "")
        } },
        { id: "sources", icon: "list", label: function () { return tr("Sources") } },
    ]
    const buttonEls = actionDefs.map(function (a) {
        const b = h("div.gbutton", null, icon(a.icon, 30), h("span", { text: a.label() }))
        buttons.appendChild(b)
        return b
    })

    // ---- seasons and their episodes

    let seasonEls: HTMLElement[] = []
    function buildSeasons(list: NonNullable<tmdb.Details["seasons"]>): void {
        clear(seasonsEl)
        seasonEls = list.map(function (s) {
            const name = !s.name || /^Season \d+$/.test(s.name) ? tr("Season %1", s.number) : s.name
            const p = h("div.season", { text: name })
            seasonsEl.appendChild(p)
            return p
        })
        seasonsEl.style.display = ""
    }

    let seasonRequest = 0
    /** a season's episodes; land: the card to rest on (-1: the last) */
    function loadSeason(n: number, land: number): void {
        seasonNo = n
        const request = ++seasonRequest
        tmdb.season(item.id, n).then(function (s) {
            if (!alive || request !== seasonRequest) return
            episodes.at = land < 0 ? Math.max(0, s.episodes.length - 1) : land
            episodes.fill(s.episodes)
            episodesEl.style.display = s.episodes.length ? "" : "none"
            if (!s.episodes.length && part === "episodes") part = "seasons"
            layout()
            place()
        }, function (e) { console.warn("season " + n + ": " + e) })
        place()
    }

    function seasonIndex(): number {
        const list = (details && details.seasons) || []
        for (let i = 0; i < list.length; i++) if (list[i].number === seasonNo) return i
        return 0
    }

    // ---- layout: shows put the story where the episode row still fits under it

    function layout(): void {
        const top = isMovie || !(details && details.seasons && details.seasons.length)
            ? Math.round(1080 * 0.2)
            : Math.max(60, 1080 - edge - (info.offsetHeight + underInfo))
        spacer.style.height = top + "px"
    }

    function place(): void {
        for (let i = 0; i < buttonEls.length; i++) {
            buttonEls[i].className = "gbutton" + (part === "actions" && i === button ? " lit" : "")
            ;(buttonEls[i].lastChild as HTMLElement).textContent = actionDefs[i].label()
        }
        const list = (details && details.seasons) || []
        for (let i = 0; i < seasonEls.length; i++) {
            seasonEls[i].className = "season" + (list[i].number === seasonNo ? " sel" : "") + (part === "seasons" && i === seasonAt ? " lit" : "")
        }
        episodes.place(part === "episodes", true)
        more.place(part === "more", part !== "actions" || isMovie)
        const y = part === "more" ? Math.max(0, moreEl.offsetTop - 1080 * 0.3) : 0
        body.style.transform = body.style.webkitTransform = "translate3d(0," + (-y) + "px,0)"
    }

    // ---- keys

    function order(): Part[] {
        const p: Part[] = ["actions"]
        if (seasonEls.length) p.push("seasons")
        if (episodes.items.length) p.push("episodes")
        if (more.items.length) p.push("more")
        return p
    }

    function action(a: Action): boolean {
        const parts = order()
        const at = parts.indexOf(part)
        if (a === "up" || a === "down") {
            const n = at + (a === "up" ? -1 : 1)
            if (n < 0 || n >= parts.length) return true
            part = parts[n]
            if (part === "seasons") seasonAt = seasonIndex()
        } else if (a === "left" || a === "right") {
            const dir = a === "left" ? -1 : 1
            if (part === "actions") button = Math.max(0, Math.min(buttonEls.length - 1, button + dir))
            else if (part === "seasons") seasonAt = Math.max(0, Math.min(seasonEls.length - 1, seasonAt + dir))
            else if (part === "episodes" && !step(episodes, dir)) {
                // past the row's end: the next (or last) season
                const list = (details && details.seasons) || []
                const s = list[seasonIndex() + dir]
                if (s) loadSeason(s.number, dir < 0 ? -1 : 0)
            } else if (part === "more") step(more, dir)
        } else if (a === "ok") {
            if (part === "seasons") {
                const list = (details && details.seasons) || []
                if (list[seasonAt] && list[seasonAt].number !== seasonNo) loadSeason(list[seasonAt].number, 0)
            } else if (part === "more") {
                const it = more.current()
                if (it) open(it)
                return true
            }
        } else if (a === "back" && part !== "actions") {
            // back first goes up to the buttons, then out
            part = "actions"
        } else {
            return false
        }
        place()
        return true
    }

    return {
        el,
        action,
        closed(): void { alive = false },
    }
}
