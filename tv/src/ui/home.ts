// home: the top nav, the hero (whatever the focus is on) and the rows under it (qml Home, Hero, MediaRow)
import { h, clear, fitScrim } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import { metaLine, hhmm } from "./meta"
import { strip, step, Strip } from "./strip"
import * as home from "../data/home"
import * as tmdb from "../data/tmdb"
import * as progress from "../data/progress"
import * as trakt from "../data/trakt"
import { App, Screen } from "./app"
import { icon } from "./icons"

// where the focused row's title rests on the 1080 page, and a row's height (title, poster, room)
const rowTitleY = 590
const rowH = 56 + 321 + 74

export const posterKind = {
    width: 214, gap: 30,
    art: function (it: tmdb.Item) { return look.poster(it.poster) },
    // part watched: a bar along the bottom of the poster
    lines: function (it: tmdb.Item): HTMLElement[] {
        const p = progress.get(it.kind, it.id)
        if (p && p.finished && it.kind === "movie") return [h("div.pdone", null, icon("check", 26))]
        const share = !p || p.finished ? 0 : p.duration ? p.position / p.duration : p.share || 0
        if (share < 0.02) return []
        const fill = h("div.pfill")
        fill.style.width = Math.min(100, share * 100).toFixed(1) + "%"
        return [h("div.pbar", null, fill)]
    },
}

interface Row {
    def: home.RowDef
    el: HTMLElement
    strip: Strip<tmdb.Item>
    done: boolean
    top: number
}

export type { Screen } from "./app"

export function homeScreen(app: App): Screen {
    const tabs = [
        { id: "search", label: "", icon: "search" },
        { id: "home", label: tr("Home") },
        { id: "movies", label: tr("Movies") },
        { id: "shows", label: tr("Shows") },
        { id: "library", label: tr("Library") },
        { id: "settings", label: "", icon: "settings" },
    ]
    const tabEls = tabs.map(function (t) {
        return h("div.tab" + (t.icon ? ".icon." + t.icon : ""), { text: t.label })
    })
    const clock = h("div.clock")
    const nav = h("div.nav", null, h("div.pill", null, ...tabEls), clock)

    const backA = h("img.backdrop", { alt: "" }) as HTMLImageElement
    const backB = h("img.backdrop", { alt: "" }) as HTMLImageElement
    let front = backA

    const logo = h("img.logo", { alt: "" }) as HTMLImageElement
    const title = h("div.title")
    const sub = h("div.sub")
    const meta = h("div.meta")
    const overview = h("div.overview")
    const extra = h("div.extra")
    const side = h("div.side", null, overview, extra)
    const scrim = h("div.scrim.s70")
    const hero = h("div.hero", null, scrim, h("div.story", null, logo, title, sub, meta), side)

    const rowsEl = h("div.rows")
    const emptyEl = h("div.homeempty")
    const hint = h("div.hint", null, h("span.cap", { text: "HOLD OK" }), h("span", { text: tr("Options") }))

    const el = h("div.home", null,
        h("div.backdrops", null, backA, backB),
        h("div.shade"),
        hero, rowsEl, emptyEl, hint, nav)

    let rows: Row[] = []
    let current = 0
    let inNav = false
    let tab = 1
    let page = "home"
    let shown = ""
    let detailTimer = 0

    // ---- pages: home, movies, shows (each its own rows, built fresh, the first ones asked for first)

    const pages: { [id: string]: () => home.RowDef[] } = { home: home.rows, movies: home.movieRows, shows: home.showRows, library: home.libraryRows }

    function build(defs: home.RowDef[]): void {
        clear(rowsEl)
        const mine = rows = defs.map(function (def) {
            const s = strip(posterKind)
            // grey cards until it comes (qml Skeleton); fill() replaces them
            for (let k = 0; k < 8; k++) s.track.appendChild(h("div.card.skel", null, h("div.art")))
            const rowEl = h("div.row", null, h("div.rowtitle", { text: tr(def.title) }), s.track)
            rowsEl.appendChild(rowEl)
            return { def, el: rowEl, strip: s, done: false, top: 0 }
        })
        current = 0
        shown = ""
        layoutRows()
        mine.forEach(function (r, i) {
            setTimeout(function () {
                if (rows !== mine) return
                home.row(r.def.id).then(function (items) {
                    if (rows !== mine) return
                    r.strip.fill(items)
                    loaded(r)
                }, function (e) {
                    console.warn("row " + r.def.id + ": " + e)
                    if (rows === mine) loaded(r)
                })
            }, i < 3 ? 0 : 300 + i * 80)
        })
        place()
    }

    function loaded(r: Row): void {
        r.done = true
        layoutRows()
        place()
    }

    /** the rows kept on the tv change under home (played, added): asked again when it's back on top */
    function refreshLocal(): void {
        const mine = rows
        mine.forEach(function (r) {
            if (!home.isLocal(r.def.id)) return
            home.row(r.def.id).then(function (items) {
                if (rows !== mine) return
                const was = r.strip.current()
                r.strip.fill(items)
                if (was) for (let i = 0; i < items.length; i++) if (items[i].kind === was.kind && items[i].id === was.id) r.strip.at = i
                r.done = true
                layoutRows()
                if (!rows[current] || !rows[current].strip.items.length) {
                    let n = 0
                    while (n < rows.length && !rows[n].strip.items.length) n++
                    current = n < rows.length ? n : 0
                }
                place()
            }, function () { /* kept as it was */ })
        })
    }

    function options(r: Row, it: tmdb.Item): void {
        const entries = []
        const kept = progress.inLibrary(it.kind, it.id)
        entries.push({ label: kept ? tr("Remove from My List") : tr("Add to My List"), icon: kept ? "minus" : "plus", run: function () {
            const added = progress.toggleLibrary(it)
            refreshLocal()
            app.toast(added ? tr("Added to My List") : tr("Removed from My List"),
                added ? undefined : function () { progress.toggleLibrary(it); refreshLocal() })
        } })
        if (r.def.id === "continue" || r.def.id === "upnext" || r.def.id === "history") {
            entries.push({ label: tr("Remove from %1", tr(r.def.title)), icon: "minus", run: function () {
                const was = progress.forget(it.kind, it.id)
                refreshLocal()
                app.toast(tr("Removed %1", it.title), was ? function () { progress.restore(was); refreshLocal() } : undefined)
            } })
        }
        if (it.kind === "movie") {
            entries.push({ label: tr("Mark as watched"), icon: "check", run: function () {
                progress.markWatched(it)
                trakt.addHistory({ kind: "movie", tmdb: it.id })
                app.toast(tr("Marked as watched"))
                refreshLocal()
            } })
            entries.push({ label: tr("Sources"), icon: "list", run: function () { app.sources({ item: it }) } })
        }
        entries.push({ label: tr("Details"), icon: "eye", run: function () { app.open(it) } })
        app.menu(it.title, entries)
    }

    function choose(id: string): void {
        if (!pages[id] || id === page) return
        page = id
        build(pages[id]())
    }

    // ---- rows

    function layoutRows(): void {
        let y = 0
        for (let i = 0; i < rows.length; i++) {
            const r = rows[i]
            // an empty row (nothing came) takes no room
            const there = r.strip.items.length > 0 || !r.done
            r.top = y
            r.el.style.top = y + "px"
            r.el.style.display = there ? "" : "none"
            if (there) y += rowH
        }
    }

    function place(): void {
        const r = rows[current]
        rowsEl.style.transform = rowsEl.style.webkitTransform = "translate3d(0," + (rowTitleY - (r ? r.top : 0)) + "px,0)"
        for (let i = 0; i < rows.length; i++) {
            rows[i].el.className = "row" + (i < current ? " gone" : "")
            rows[i].strip.place(!inNav && i === current, Math.abs(i - current) <= (look.lowMemory ? 1 : 2))
        }
        for (let t = 0; t < tabEls.length; t++) {
            tabEls[t].className = "tab" + (tabs[t].icon ? " icon " + tabs[t].icon : "") + (t === tab ? " on" : "") + (inNav && t === tab ? " lit" : "")
        }
        const any = rows.some(function (x) { return x.strip.items.length > 0 })
        const settled = rows.every(function (x) { return x.done })
        hint.style.opacity = inNav || !any ? "0" : "1"
        emptyEl.textContent = settled && !any
            ? page === "library" ? tr("Nothing here yet: hold OK on a title to add it to My List") : tr("Nothing came: is the TV online?") : ""
        if (!any && settled) inNav = true
        show(r && r.strip.current())
    }

    // ---- the hero: the focused title, its details a moment later (moving fast fetches nothing)

    function show(it: tmdb.Item | undefined): void {
        const key = it ? it.kind + ":" + it.id : ""
        if (key === shown) return
        shown = key
        clearTimeout(detailTimer)
        if (!it) return
        setBackdrop(look.backdrop(it.backdrop))
        logo.style.display = "none"
        title.style.display = ""
        title.textContent = it.title
        sub.textContent = ""
        metaLine(meta, it, null)
        overview.textContent = it.overview
        extra.textContent = ""
        fitScrim(scrim, side, 0, 0)
        detailTimer = window.setTimeout(function () {
            tmdb.details(it.kind, it.id).then(function (d) {
                if (shown !== key) return
                if (d.logo) {
                    logo.onload = function () { if (shown === key) { logo.style.display = ""; title.style.display = "none" } }
                    logo.src = d.logo
                }
                metaLine(meta, it, d)
                const cast = d.cast.slice(0, 3).map(function (c) { return c.name }).join(", ")
                clear(extra)
                if (cast) extra.appendChild(h("div", { text: tr("Starring %1", cast) }))
                if (d.network) extra.appendChild(h("div.network", { text: d.network }))
                fitScrim(scrim, side, 0, 0)
            }, function () { /* the list's own words stay */ })
        }, 350)
    }

    function setBackdrop(url: string | null): void {
        const back = front === backA ? backB : backA
        if (!url) { front.className = "backdrop"; return }
        back.onload = function () {
            back.className = "backdrop on"
            front.className = "backdrop"
            front = back
        }
        back.src = url
    }

    // ---- the clock

    function tick(): void { clock.textContent = hhmm(new Date()) }
    tick()
    const ticker = setInterval(tick, 15000)

    // ---- keys

    function action(a: Action): boolean {
        if (inNav) {
            if (a === "left" && tab > 0) { tab--; choose(tabs[tab].id) }
            else if (a === "right" && tab < tabs.length - 1) { tab++; choose(tabs[tab].id) }
            else if ((a === "down" || a === "ok") && !pages[tabs[tab].id]) app.page(tabs[tab].id)
            else if (a === "down" || a === "ok") { if (rows.some(function (r) { return r.strip.items.length > 0 })) inNav = false }
            else return a !== "back"
            place()
            return true
        }
        const r = rows[current]
        if (!r) return false
        if (a === "left" || a === "right") step(r.strip, a === "left" ? -1 : 1)
        else if (a === "down") { let n = current + 1; while (n < rows.length && !rows[n].strip.items.length) n++; if (n < rows.length) current = n }
        else if (a === "up") { let n = current - 1; while (n >= 0 && !rows[n].strip.items.length) n--; if (n >= 0) current = n; else inNav = true }
        else if (a === "ok") { const it = r.strip.current(); if (it) app.open(it); return true }
        else if (a === "menu") { const it = r.strip.current(); if (it) options(r, it); return true }
        else if (a === "back" && (current > 0 || r.strip.at > 0)) { current = 0; rows.forEach(function (x) { x.strip.at = 0 }) }
        else return false
        place()
        return true
    }

    build(home.rows())
    return {
        el,
        action,
        shown(): void { tick(); refreshLocal() },
        closed(): void { clearInterval(ticker); clearTimeout(detailTimer) },
    }
}
