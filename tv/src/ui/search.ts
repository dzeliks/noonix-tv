// search for a remote (qml Search, the tv terminal): results on the left, a column on the right with the
// query, the on-screen keyboard and suggestions. results come in two rows, shows then movies
import { h, clear } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"
import * as look from "./look"
import { keyboard } from "./keyboard"
import { strip, step, Strip } from "./strip"
import { Screen } from "./home"
import * as tmdb from "../data/tmdb"

type Zone = "keys" | "suggestions" | "rows"

const columnW = 575
const columnX = 1920 - 96 - columnW
const areaW = columnX - 56
const kind = { width: 180, gap: 26, cls: "small", room: areaW - 96, art: function (it: tmdb.Item) { return look.poster(it.poster) } }

export function searchScreen(open: (it: tmdb.Item) => void): Screen {
    let query = ""
    let zone: Zone = "keys"
    let suggestions: string[] = []
    let sugAt = 0
    let rowAt = 0
    let alive = true

    const text = h("span.text")
    const field = h("div.field", null, text, h("span.caret"))
    const kb = keyboard(48, tr("search"), function (s) { setQuery(query + s) }, function (name) {
        if (name === "backspace") setQuery(query.slice(0, -1))
        else if (name === "clear") setQuery("")
        else if (name === "enter" && rows.some(function (r) { return r.items.length > 0 })) { zone = "rows"; place() }
    })
    const sugEl = h("div.suggestions")
    const column = h("div.column", null, field, kb.el, sugEl)

    const showStrip = strip(kind)
    const movieStrip = strip(kind)
    const rows: Strip<tmdb.Item>[] = [showStrip, movieStrip]
    const titles = [h("div.rowtitle"), h("div.rowtitle")]
    const rowEls = [h("div.srow", null, titles[0], showStrip.track), h("div.srow", null, titles[1], movieStrip.track)]
    const empty = h("div.empty")
    const area = h("div.area", null, rowEls[0], rowEls[1], empty)

    const el = h("div.searchpage", null, area, column)

    // ---- what's typed: suggestions right away, results a moment later

    let request = 0
    let timer = 0
    function setQuery(q: string): void {
        query = q
        text.textContent = q || ""
        field.className = "field" + (q ? "" : " placeholder")
        if (!q) text.textContent = tr("Search")
        clearTimeout(timer)
        const mine = ++request
        if (q.trim().length < 2) {
            suggestions = []
            showPopular()
            place()
            return
        }
        timer = window.setTimeout(function () {
            tmdb.suggest(q).then(function (list) {
                if (!alive || mine !== request) return
                suggestions = list.slice(0, 6)
                place()
            }, function () { /* the results still come */ })
            tmdb.search(q).then(function (items) {
                if (!alive || mine !== request) return
                fill(items.filter(function (x) { return x.kind === "show" }), items.filter(function (x) { return x.kind === "movie" }), false)
                empty.textContent = items.length ? "" : tr("No results for “%1”", q.trim())
            }, function (e) { console.warn("search: " + e) })
        }, 350)
    }

    let popular: { shows: tmdb.Item[]; movies: tmdb.Item[] } | null = null
    function showPopular(): void {
        empty.textContent = ""
        if (popular) { fill(popular.shows, popular.movies, true); return }
        Promise.all([tmdb.popular("show"), tmdb.popular("movie")]).then(function (v) {
            popular = { shows: v[0], movies: v[1] }
            if (alive && query.trim().length < 2) fill(v[0], v[1], true)
        }, function (e) { console.warn("popular: " + e) })
    }

    function fill(shows: tmdb.Item[], movies: tmdb.Item[], pop: boolean): void {
        showStrip.at = movieStrip.at = 0
        showStrip.fill(shows)
        movieStrip.fill(movies)
        titles[0].textContent = pop ? tr("Popular Shows") : tr("Shows")
        titles[1].textContent = pop ? tr("Popular Movies") : tr("Movies")
        if (!rows[rowAt].items.length) rowAt = rows[0].items.length ? 0 : 1
        if (zone === "rows" && !rows[rowAt].items.length) zone = "keys"
        place()
    }

    // ---- drawing

    function place(): void {
        kb.setActive(zone === "keys")
        clear(sugEl)
        suggestions.forEach(function (s, i) {
            sugEl.appendChild(h("div.suggestion" + (zone === "suggestions" && i === sugAt ? ".lit" : ""), { text: s }))
        })
        let y = 0
        for (let i = 0; i < rows.length; i++) {
            const has = rows[i].items.length > 0
            rowEls[i].style.display = has ? "" : "none"
            rowEls[i].style.top = y + "px"
            if (has) y += 400
            rows[i].place(zone === "rows" && i === rowAt, true)
        }
    }

    // ---- keys

    function action(a: Action): boolean {
        if (zone === "keys") {
            if (kb.action(a)) return true
            if (a === "left" && rows[rowAt].items.length) zone = "rows"
            else if (a === "down" && suggestions.length) { zone = "suggestions"; sugAt = 0 }
            else return a !== "back"
        } else if (zone === "suggestions") {
            if (a === "up") { if (sugAt > 0) sugAt--; else zone = "keys" }
            else if (a === "down") { if (sugAt < suggestions.length - 1) sugAt++ }
            else if (a === "left" && rows[rowAt].items.length) zone = "rows"
            else if (a === "ok") { const s = suggestions[sugAt]; zone = "keys"; setQuery(s); return true }
            else if (a === "back") zone = "keys"
            else return true
        } else {
            const r = rows[rowAt]
            if (a === "left") step(r, -1)
            else if (a === "right") { if (!step(r, 1)) zone = "keys" }
            else if (a === "up" && rowAt === 1 && rows[0].items.length) rowAt = 0
            else if (a === "down" && rowAt === 0 && rows[1].items.length) rowAt = 1
            else if (a === "ok") { const it = r.current(); if (it) open(it); return true }
            else if (a === "back") zone = "keys"
            else return true
        }
        place()
        return true
    }

    setQuery("")
    return { el, action, closed(): void { alive = false; clearTimeout(timer) } }
}
