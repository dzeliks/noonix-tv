// settings (qml Settings, cut to what a tv app has): language, low memory, addons, trakt, keys, history
import { h, clear } from "./dom"
import { tr, trn, language } from "../i18n"
import { Action } from "../keys"
import { platform } from "../platform"
import * as look from "./look"
import { inputScreen } from "./input"
import { App, Screen } from "./app"
import * as settings from "../data/settings"
import * as sources from "../data/sources"
import * as store from "../data/store"
import * as trakt from "../data/trakt"

declare const __VERSION__: string

interface Row { label: string; value(): string; ok(): void; hint?: string }

/** a titled list of rows, value on the right; ok runs the row */
function listScreen(title: string, rows: () => Row[]): Screen & { redraw(): void } {
    let at = 0
    let current: Row[] = []
    const track = h("div.ltrack")
    const hint = h("div.lhint")
    const el = h("div.list", null, h("div.ltitle", { text: title }), h("div.lbox", null, track), hint)
    function redraw(): void {
        current = rows()
        at = Math.min(at, current.length - 1)
        clear(track)
        current.forEach(function (r, i) {
            track.appendChild(h("div.lrow" + (i === at ? ".lit" : ""), null, h("span.llabel", { text: r.label }), h("span.lvalue", { text: r.value() })))
        })
        hint.textContent = (current[at] && current[at].hint) || ""
        const first = Math.max(0, Math.min(at - 3, current.length - 8))
        track.style.transform = track.style.webkitTransform = "translate3d(0," + (-first * 104) + "px,0)"
    }
    redraw()
    return {
        el,
        redraw,
        action(a: Action): boolean {
            if (a === "up" && at > 0) at--
            else if (a === "down" && at < current.length - 1) at++
            else if (a === "ok" && current[at]) { current[at].ok(); redraw(); return true }
            else if (a === "back") return false
            else return true
            redraw()
            return true
        },
        shown(): void { redraw() },
    }
}

export function settingsScreen(app: App): Screen {
    const lowNames: { [k: string]: string } = { auto: tr("Auto"), on: tr("On"), off: tr("Off") }
    return listScreen(tr("Settings"), function (): Row[] {
        const s = settings.all()
        const n = sources.addons().length
        return [
            { label: tr("Language"), value: function () { return language() === "sr" ? "Srpski" : "English" },
                ok: function () { settings.put("language", s.language === "sr" ? "en" : "sr"); location.reload() } },
            { label: tr("Low memory mode"), value: function () { return lowNames[s.lowMode] + (s.lowMode === "auto" ? " (" + (look.lowMemory ? tr("On") : tr("Off")) + ")" : "") },
                hint: tr("Lighter artwork and fewer cards kept, for older TVs"),
                ok: function () { settings.put("lowMode", s.lowMode === "auto" ? "on" : s.lowMode === "on" ? "off" : "auto"); location.reload() } },
            { label: tr("Addons"), value: function () { return n ? trn("%n installed", n) : tr("None") },
                hint: tr("Sources come from Stremio addons: a debrid one plays best on a TV"),
                ok: function () { app.push(addonsScreen(app), false) } },
            { label: "Trakt", value: function () { const u = trakt.user(); return u ? tr("Signed in as %1", u) : trakt.available() ? tr("Sign in") : tr("Not set up") },
                hint: tr("Scrobbles what you watch and brings back where you left off"),
                ok: function () {
                    if (trakt.user()) app.menu("Trakt", [{ label: tr("Sign out"), run: function () { trakt.signOut(); app.toast(tr("Signed out of Trakt")) } }])
                    else if (trakt.available()) app.push(traktScreen(app), false)
                    else app.toast(tr("This build has no Trakt app"))
                } },
            { label: tr("TMDB key"), value: function () { return settings.secret("tmdbApiKey") ? tr("Your own") : tr("Built-in") },
                hint: tr("Your own key from themoviedb.org, when the built-in one is refused"),
                ok: function () {
                    app.push(inputScreen(tr("TMDB key"), tr("Empty: the built-in key"), settings.secret("tmdbApiKey"), function (v) {
                        settings.setSecret("tmdbApiKey", v)
                        app.toast(v ? tr("Key saved") : tr("Built-in key"))
                    }, app.pop), false)
                } },
            { label: tr("Clear watch history"), value: function () { return "" },
                ok: function () {
                    app.menu(tr("Clear watch history?"), [{ label: tr("Clear"), run: function () {
                        store.remove("progress"); store.remove("watched"); app.toast(tr("Watch history cleared"))
                    } }, { label: tr("Cancel"), run: function () { /* nothing */ } }])
                } },
            { label: tr("Clear cache"), value: function () { return "" }, hint: tr("Lists and artwork are fetched again"),
                ok: function () { store.evict(1); app.toast(tr("Cache cleared")) } },
            { label: tr("About"), value: function () { return "Noonix TV " + __VERSION__ + "  ·  " + platform.label + "  ·  Chromium " + platform.chrome },
                ok: function () { /* nothing */ } },
        ]
    })
}

function addonsScreen(app: App): Screen {
    return listScreen(tr("Addons"), function (): Row[] {
        const rows: Row[] = [{
            label: tr("Add an addon"), value: function () { return "" }, hint: tr("Its manifest link, e.g. from your debrid addon's configure page"),
            ok: function () {
                app.push(inputScreen(tr("Add an addon"), tr("The manifest link (…/manifest.json)"), "https://", function (v) {
                    if (!v || v === "https://") return
                    app.toast(tr("Reading the addon…"))
                    sources.addAddon(v).then(function (a) { app.toast(tr("Added %1", a.name)) }, function (e) {
                        app.toast(tr("Not added: %1", String(e.message || e)))
                    })
                }, app.pop), false)
            },
        }]
        sources.addons().forEach(function (a) {
            rows.push({
                label: a.name, value: function () { return a.on ? tr("On") : tr("Off") }, hint: a.url.replace(/^https?:\/\//, "").slice(0, 60) + "…",
                ok: function () {
                    app.menu(a.name, [
                        { label: a.on ? tr("Turn off") : tr("Turn on"), run: function () { sources.toggleAddon(a.url) } },
                        { label: tr("Remove"), run: function () { sources.removeAddon(a.url); app.toast(tr("Removed %1", a.name)) } },
                    ])
                },
            })
        })
        return rows
    })
}

function traktScreen(app: App): Screen {
    let alive = true
    let timer = 0
    const code = h("div.tcode", { text: "· · · · · ·" })
    const url = h("div.turl")
    const note = h("div.tnote", { text: tr("Asking Trakt for a code…") })
    const el = h("div.trakt", null, h("div.tbox", null, h("div.ttitle", { text: tr("Sign in to Trakt") }),
        h("div.tsteps", { text: tr("On your phone or computer, open") }), url, h("div.tsteps", { text: tr("and type this code") }), code, note))

    trakt.deviceCode().then(function (c) {
        if (!alive) return
        code.textContent = c.user
        url.textContent = c.url.replace(/^https?:\/\//, "")
        note.textContent = tr("Waiting for you…")
        const until = Date.now() + c.expires * 1000
        const poll = function () {
            if (!alive) return
            if (Date.now() > until) { note.textContent = tr("The code expired: open this again"); return }
            trakt.poll(c).then(function (user) {
                if (!alive) return
                if (user) { app.toast(tr("Signed in as %1", user)); app.pop(); return }
                timer = window.setTimeout(poll, c.interval * 1000)
            }, function (e) {
                if (alive) note.textContent = tr("Not signed in: %1", String(e.message || e))
            })
        }
        timer = window.setTimeout(poll, c.interval * 1000)
    }, function (e) {
        if (alive) note.textContent = tr("Trakt didn't answer: %1", String(e.message || e))
    })

    return {
        el,
        action(a: Action): boolean { return a !== "back" },
        closed(): void { alive = false; clearTimeout(timer) },
    }
}
