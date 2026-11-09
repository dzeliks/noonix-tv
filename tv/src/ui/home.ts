// home: the top nav, the hero (whatever the focus is on) and the rows under it (qml Home, Hero, MediaRow)
import { h, clear } from "./dom"
import { tr, trn } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import * as home from "../data/home"
import * as tmdb from "../data/tmdb"

// the 1080 grid (qml Theme): side margin, poster card, where the focused row's title rests
const margin = 96
const posterW = 214
const posterH = 321
const gap = 30
const restSlot = 2
const rowTitleY = 590
const rowH = 56 + posterH + 74

interface Row {
    def: home.RowDef
    el: HTMLElement
    track: HTMLElement
    cards: HTMLElement[]
    items: tmdb.Item[]
    at: number
    top: number
}

export interface Screen {
    el: HTMLElement
    action(a: Action): boolean
}

export function homeScreen(): Screen {
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
    const hero = h("div.hero", null, h("div.story", null, logo, title, sub, meta), h("div.side", null, overview, extra))

    const rowsEl = h("div.rows")
    const hint = h("div.hint", null, h("span.cap", { text: "HOLD OK" }), h("span", { text: tr("Options") }))

    const el = h("div.home", null,
        h("div.backdrops", null, backA, backB),
        h("div.shade"),
        hero, rowsEl, hint, nav)

    const rows: Row[] = home.rows().map(function (def) {
        const track = h("div.track")
        const rowEl = h("div.row", null, h("div.rowtitle", { text: tr(def.title) }), track)
        rowsEl.appendChild(rowEl)
        return { def, el: rowEl, track, cards: [], items: [], at: 0, top: 0 }
    })
    let current = 0
    let inNav = false
    let tab = 1

    // ---- rows

    function layoutRows(): void {
        let y = 0
        for (let i = 0; i < rows.length; i++) {
            const r = rows[i]
            r.top = y
            r.el.style.top = y + "px"
            // an empty row (nothing came) takes no room
            if (r.items.length || !r.el.getAttribute("data-done")) y += rowH
            r.el.style.display = r.items.length || !r.el.getAttribute("data-done") ? "" : "none"
        }
    }

    function fill(r: Row, items: tmdb.Item[]): void {
        r.items = items
        r.cards = items.map(function (it) {
            const card = h("div.card", null, h("div.art"))
            r.track.appendChild(card)
            ;(card as any).item = it
            return card
        })
        r.el.setAttribute("data-done", "1")
        layoutRows()
        place()
    }

    /** cards near the view get their art, far ones let it go (low memory keeps fewer) */
    function art(r: Row, near: boolean): void {
        const keep = look.lowMemory ? 10 : 16
        for (let i = 0; i < r.cards.length; i++) {
            const c = r.cards[i]
            const box = c.firstChild as HTMLElement
            const want = near && i >= r.at - keep && i <= r.at + keep
            const url = want ? look.poster((c as any).item.poster) : null
            const has = box.getAttribute("data-src")
            if (url && has !== url) {
                box.style.backgroundImage = "url(\"" + url + "\")"
                box.setAttribute("data-src", url)
            } else if (!url && has) {
                box.style.backgroundImage = ""
                box.removeAttribute("data-src")
            }
        }
    }

    function slide(r: Row): void {
        const step = posterW + gap
        const first = Math.max(0, Math.min(r.at - restSlot, r.cards.length - Math.floor((1920 - 2 * margin + gap) / step)))
        r.track.style.transform = r.track.style.webkitTransform = "translate3d(" + (-Math.max(0, first) * step) + "px,0,0)"
    }

    function place(): void {
        const r = rows[current]
        rowsEl.style.transform = rowsEl.style.webkitTransform = "translate3d(0," + (rowTitleY - (r ? r.top : 0)) + "px,0)"
        for (let i = 0; i < rows.length; i++) {
            const row = rows[i]
            row.el.className = "row" + (i < current ? " gone" : "")
            for (let j = 0; j < row.cards.length; j++) row.cards[j].className = "card" + (!inNav && i === current && j === row.at ? " lit" : "")
            slide(row)
            art(row, Math.abs(i - current) <= (look.lowMemory ? 1 : 2))
        }
        for (let t = 0; t < tabEls.length; t++) {
            tabEls[t].className = "tab" + (tabs[t].icon ? " icon " + tabs[t].icon : "") + (t === tab ? " on" : "") + (inNav && t === tab ? " lit" : "")
        }
        hint.style.opacity = inNav ? "0" : "1"
        show(r && r.items[r.at])
    }

    // ---- the hero: the focused title, its details a moment later (moving fast fetches nothing)

    let shown = ""
    let detailTimer = 0
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
        meta.textContent = [it.year, it.genres.slice(0, 2).join(", "), it.rating ? "★ " + it.rating : ""]
            .filter(function (x) { return !!x }).join("  ·  ")
        overview.textContent = it.overview
        extra.textContent = ""
        detailTimer = window.setTimeout(function () {
            tmdb.details(it.kind, it.id).then(function (d) {
                if (shown !== key) return
                if (d.logo) {
                    logo.onload = function () { if (shown === key) { logo.style.display = ""; title.style.display = "none" } }
                    logo.src = d.logo
                }
                const parts: string[] = []
                if (d.genres.length) parts.push(d.genres.slice(0, 2).join(", "))
                if (d.kind === "movie" && d.runtime) parts.push(runtime(d.runtime))
                if (d.kind === "show" && d.seasons) parts.push(trn("%n season(s)", d.seasons.length))
                if (d.certification) parts.push(d.certification)
                if (d.rating) parts.push("★ " + d.rating)
                meta.textContent = (d.year ? d.year + "  ·  " : "") + parts.join("  ·  ")
                if (d.kind === "movie" && d.runtime) {
                    const end = new Date(Date.now() + d.runtime * 60000)
                    meta.appendChild(h("b", { text: "  ·  " + tr("Ends at %1", hhmm(end)) }))
                }
                const cast = d.cast.slice(0, 3).map(function (c) { return c.name }).join(", ")
                clear(extra)
                if (cast) extra.appendChild(h("div", { text: tr("Starring %1", cast) }))
                if (d.network) extra.appendChild(h("div.network", { text: d.network }))
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
    setInterval(tick, 15000)

    // ---- keys

    function action(a: Action): boolean {
        if (inNav) {
            if (a === "left" && tab > 0) tab--
            else if (a === "right" && tab < tabs.length - 1) tab++
            else if (a === "down") inNav = false
            else return a !== "back"
            place()
            return true
        }
        const r = rows[current]
        if (!r) return false
        if (a === "left" && r.at > 0) r.at--
        else if (a === "right" && r.at < r.cards.length - 1) r.at++
        else if (a === "down") { let n = current + 1; while (n < rows.length && !rows[n].items.length) n++; if (n < rows.length) current = n }
        else if (a === "up") { let n = current - 1; while (n >= 0 && !rows[n].items.length) n--; if (n >= 0) current = n; else inNav = true }
        else if (a === "back" && (current > 0 || r.at > 0)) { current = 0; rows[0].at = 0; rows.forEach(function (x) { x.at = 0 }) }
        else return false
        place()
        return true
    }

    // ---- loading: the first rows first, the rest after

    layoutRows()
    rows.forEach(function (r, i) {
        setTimeout(function () {
            home.row(r.def.id).then(function (items) { fill(r, items) }, function (e) {
                console.warn("row " + r.def.id + ": " + e)
                r.el.setAttribute("data-done", "1")
                layoutRows()
                place()
            })
        }, i < 3 ? 0 : 300 + i * 80)
    })
    place()
    return { el, action }
}

function hhmm(d: Date): string {
    const two = function (n: number) { return (n < 10 ? "0" : "") + n }
    return two(d.getHours()) + ":" + two(d.getMinutes())
}

function runtime(min: number): string {
    const hh = Math.floor(min / 60)
    return hh ? hh + "h " + (min % 60) + "m" : min + "m"
}
