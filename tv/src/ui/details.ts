// a movie or a show (qml Details): backdrop, logo, meta, the story, actions, seasons + episodes, more like this
import { h, clear, fitScrim } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import { icon } from "./icons"
import { metaLine, length, day } from "./meta"
import { strip, step } from "./strip"
import { posterKind } from "./home"
import { App, PlayReq, Screen, MenuEntry } from "./app"
import * as tmdb from "../data/tmdb"
import * as progress from "../data/progress"
import * as trakt from "../data/trakt"

type Part = "actions" | "seasons" | "episodes" | "more"

// the episode row's two text lines end this far above the screen edge; what sits under the story
const edge = 44
const underInfo = 90 + 60 + 225 + 92 + 4 * 34

export function detailsScreen(item: tmdb.Item, app: App): Screen {
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
    const scrim = h("div.scrim.s55")
    const info = h("div.info", null, scrim, identity, story)

    const buttons = h("div.actions")
    const seasonsEl = h("div.seasons")
    const episodes = strip<tmdb.Episode>({
        width: 400, gap: 44, cls: "wide",
        art: function (e) { return look.still(e.still) },
        lines: function (e) {
            const sub = [e.runtime ? length(e.runtime) : "", day(e.airDate, true)].filter(function (x) { return !!x }).join("  ·  ")
            const seen = progress.watched(item.id)[e.season + ":" + e.episode]
            return [
                h("div.label", null, seen ? icon("check", 26) : null, e.episode + ".  " + (e.episodeTitle || tr("Episode %1", e.episode))),
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
            // the season of the episode up next
            const p = progress.get("show", item.id)
            const s = p && p.season !== undefined && d.seasons.some(function (x) { return x.number === p.season }) ? p.season : d.seasons[0].number
            loadSeason(s, p && p.episode ? p.episode - 1 : 0)
            findUp()
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

    // ---- actions: play (or resume), start over, sources, my list

    /** a show's episode to play: the one left off, the one after the last finished, else the first */
    let up: { season: number; episode: number; title?: string } | null = null

    function findUp(): void {
        const p = progress.get("show", item.id)
        const first = details && details.seasons && details.seasons[0]
        if (!p || p.season === undefined || p.episode === undefined) {
            up = first ? { season: first.number, episode: 1 } : null
            place()
            return
        }
        if (!p.finished) { up = { season: p.season, episode: p.episode, title: p.episodeTitle }; place(); return }
        const s = p.season, e = p.episode
        tmdb.season(item.id, s).then(function (cur) {
            const n = cur.episodes.filter(function (x) { return x.episode === e + 1 })[0]
            if (n) return n
            return tmdb.season(item.id, s + 1).then(function (nx) { return nx.episodes[0] || null }, function () { return null })
        }).then(function (n: tmdb.Episode | null) {
            if (!alive) return
            up = n ? { season: n.season, episode: n.episode, title: n.episodeTitle } : first ? { season: first.number, episode: 1 } : null
            place()
        }, function () { /* the first episode stays */ })
    }

    function resumable(): boolean {
        if (isMovie) return progress.resumeAt("movie", item.id, undefined, undefined, 1e9) > 0
        return !!up && progress.resumeAt("show", item.id, up.season, up.episode, 1e9) > 0
    }

    function req(start?: number): PlayReq {
        const r: PlayReq = { item: details || item, imdb: details && details.imdb, start: start }
        if (!isMovie && up) { r.season = up.season; r.episode = up.episode; r.episodeTitle = up.title }
        return r
    }

    function episodeReq(e: tmdb.Episode, start?: number): PlayReq {
        return { item: details || item, imdb: details && details.imdb, season: e.season, episode: e.episode, episodeTitle: e.episodeTitle, start: start }
    }

    interface Act { id: string; icon(): string; label(): string; show(): boolean; run(): void }
    const actionDefs: Act[] = [
        { id: "play", icon: function () { return "play" }, show: function () { return true },
            label: function () {
                const where = !isMovie && up ? "  S" + up.season + " E" + up.episode : ""
                return (resumable() ? tr("Resume") : tr("Play")) + where
            },
            run: function () { if (isMovie || up) app.play(req()) } },
        { id: "restart", icon: function () { return "restart" }, show: resumable, label: function () { return tr("Start Over") },
            run: function () { app.play(req(0)) } },
        { id: "sources", icon: function () { return "list" }, show: function () { return isMovie || !!up }, label: function () { return tr("Sources") },
            run: function () { app.sources(req()) } },
        { id: "library", icon: function () { return progress.inLibrary(item.kind, item.id) ? "check" : "plus" }, show: function () { return true },
            label: function () { return tr("My List") },
            run: function () { app.toast(progress.toggleLibrary(details || item) ? tr("Added to My List") : tr("Removed from My List")) } },
    ]
    let shownActs: Act[] = []
    let buttonEls: HTMLElement[] = []
    function buildButtons(): void {
        const now = actionDefs.filter(function (a) { return a.show() })
        const same = now.length === shownActs.length && now.every(function (a, i) { return a === shownActs[i] })
        if (!same) {
            const was = shownActs[button]
            shownActs = now
            clear(buttons)
            buttonEls = now.map(function () { const b = h("div.gbutton"); buttons.appendChild(b); return b })
            button = Math.max(0, was ? now.indexOf(was) : 0)
        }
        for (let i = 0; i < shownActs.length; i++) {
            const b = buttonEls[i]
            clear(b)
            b.appendChild(icon(shownActs[i].icon(), 30))
            b.appendChild(h("span", { text: shownActs[i].label() }))
            b.className = "gbutton" + (part === "actions" && i === button ? " lit" : "")
        }
    }

    function episodeOptions(e: tmdb.Episode): void {
        const seen = progress.watched(item.id)[e.season + ":" + e.episode]
        const entries: MenuEntry[] = [
            { label: tr("Play"), icon: "play", run: function () { app.play(episodeReq(e)) } },
            { label: tr("Play from the start"), icon: "restart", run: function () { app.play(episodeReq(e, 0)) } },
            { label: tr("Sources"), icon: "list", run: function () { app.sources(episodeReq(e)) } },
            { label: seen ? tr("Mark as unwatched") : tr("Mark as watched"), icon: seen ? "minus" : "check", run: function () {
                if (seen) progress.markUnwatched(details || item, e.season, e.episode)
                else {
                    progress.markWatched(details || item, e.season, e.episode)
                    trakt.addHistory({ kind: "show", tmdb: item.id, season: e.season, episode: e.episode })
                }
                episodes.fill(episodes.items)
                findUp()
                place()
            } },
        ]
        app.menu("S" + e.season + " E" + e.episode + "  ·  " + e.episodeTitle, entries)
    }

    function titleOptions(): void {
        const entries: MenuEntry[] = []
        if (isMovie) {
            entries.push({ label: tr("Mark as watched"), icon: "check", run: function () {
                progress.markWatched(details || item)
                trakt.addHistory({ kind: "movie", tmdb: item.id, imdb: details && details.imdb })
                app.toast(tr("Marked as watched"))
                place()
            } })
        }
        const kept = progress.inLibrary(item.kind, item.id)
        entries.push({ label: kept ? tr("Remove from My List") : tr("Add to My List"), icon: kept ? "minus" : "plus", run: function () {
            app.toast(progress.toggleLibrary(details || item) ? tr("Added to My List") : tr("Removed from My List"))
            place()
        } })
        app.menu(item.title, entries)
    }

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
        fitScrim(scrim, story, 0, 0)
    }

    function place(): void {
        buildButtons()
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
        } else if (a === "menu") {
            if (part === "episodes") { const e = episodes.current(); if (e) episodeOptions(e) }
            else if (part === "more") { const it = more.current(); if (it) app.open(it) }
            else titleOptions()
            return true
        } else if (a === "ok") {
            if (part === "actions") {
                const act = shownActs[button]
                if (act) act.run()
            } else if (part === "episodes") {
                const e = episodes.current()
                if (e) app.play(episodeReq(e))
                return true
            } else if (part === "seasons") {
                const list = (details && details.seasons) || []
                if (list[seasonAt] && list[seasonAt].number !== seasonNo) loadSeason(list[seasonAt].number, 0)
            } else if (part === "more") {
                const it = more.current()
                if (it) app.open(it)
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

    place()
    return {
        el,
        action,
        shown(): void {
            // back from the player: what's watched and where to go on
            if (episodes.items.length) episodes.fill(episodes.items)
            if (!isMovie && details) findUp()
            place()
        },
        closed(): void { alive = false },
    }
}
