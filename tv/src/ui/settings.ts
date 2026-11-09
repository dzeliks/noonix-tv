// settings (qml Settings, cut to what a tv app has): language, low memory, addons, trakt, keys, history
import { h, clear } from "./dom"
import { tr, trn, language } from "../i18n"
import { Action } from "../keys"
import { platform } from "../platform"
import * as look from "./look"
import { inputScreen } from "./input"
import { askPrompt } from "./exitprompt"
import { App, Screen, MenuEntry } from "./app"
import { profileName } from "./profiles"
import * as settings from "../data/settings"
import * as sources from "../data/sources"
import * as engine from "../data/engine"
import * as speed from "../data/speed"
import * as profiles from "../data/profiles"
import * as store from "../data/store"
import * as trakt from "../data/trakt"
import * as subtitles from "../data/subs"
import * as updates from "../data/updates"

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

// the qml PatternField as a line of text: commas between them
function patternRow(app: App, key: "preferred" | "hidden", label: string, none: string): Row {
    return {
        label: label, value: function () { const l = settings.all()[key]; return l.length ? l.join(", ") : tr("None") },
        hint: settings.all()[key].length ? tr("Commas between them. Words match whole words in any case; /…/ is a regular expression. Empty clears it") : none,
        ok: function () {
            app.push(inputScreen(label, tr("Commas between them. Words match whole words in any case; /…/ is a regular expression. Empty clears it"),
                settings.all()[key].join(", "), function (v) {
                    // a regex may hold commas: /a,b/ stays one
                    const out = (v.match(/\s*\/[^/]+\/\s*|[^,]+/g) || []).map(function (x) { return x.trim() }).filter(function (x) { return !!x })
                    settings.put(key, out)
                    app.toast(tr("Saved"))
                }, app.pop), false)
        },
    }
}

function qualityName(r: number): string { return r >= 2160 ? "4K" : r + "p" }

// what github said this run: undefined while it's asked
let latestSeen: string | null | undefined

export function settingsScreen(app: App): Screen {
    // the speed check running: mbit/s so far (-1: not yet)
    let checking: number | null = null
    const lowNames: { [k: string]: string } = { auto: tr("Auto"), on: tr("On"), off: tr("Off") }
    const screen = listScreen(tr("Settings"), function (): Row[] {
        const s = settings.all()
        const n = sources.addons().length
        return [
            { label: tr("Profiles"), value: function () { return profileName(profiles.current()) },
                hint: tr("Each profile keeps its own progress, list and Trakt"),
                ok: function () { app.push(profilesScreen(app), false) } },
            { label: tr("Language"), value: function () { return language() === "sr" ? "Srpski" : "English" },
                ok: function () { settings.put("language", s.language === "sr" ? "en" : "sr"); location.reload() } },
            { label: tr("Audio"), value: function () { const c = subtitles.audio(); return c ? subtitles.languageName(c) : tr("Automatic") },
                hint: tr("When a video has more than one language"),
                ok: function () {
                    const cur = subtitles.audio()
                    app.menu(tr("Audio"), [{ label: tr("Automatic"), icon: cur ? undefined : "check", run: function () { subtitles.setAudio("") } }]
                        .concat(subtitles.languages.map(function (l) {
                            return { label: l.name, icon: cur === l.code ? "check" : undefined, run: function () { subtitles.setAudio(l.code) } }
                        })))
                } },
            { label: tr("Subtitles"), value: function () { const c = subtitles.preferred(); return c ? subtitles.languageName(c) : tr("Off") },
                hint: tr("Turned on when a video has them, found online when it doesn't (OpenSubtitles)"),
                ok: function () {
                    const cur = subtitles.preferred()
                    app.menu(tr("Subtitles"), [{ label: tr("Off"), icon: cur ? undefined : "check", run: function () { subtitles.setPreferred("") } }]
                        .concat(subtitles.languages.map(function (l) {
                            return { label: l.name, icon: cur === l.code ? "check" : undefined, run: function () { subtitles.setPreferred(l.code) } }
                        })))
                } },
            { label: tr("Second subtitles"), value: function () { const c = subtitles.second(); return c ? subtitles.languageName(c) : tr("None") },
                hint: tr("For videos without the first language"),
                ok: function () {
                    const first = subtitles.preferred(), cur = subtitles.second()
                    if (!first) { app.toast(tr("Choose the first language above")); return }
                    app.menu(tr("Second subtitles"), [{ label: tr("None"), icon: cur ? undefined : "check", run: function () { subtitles.setSecond("") } }]
                        .concat(subtitles.languages.filter(function (l) { return l.code !== first }).map(function (l) {
                            return { label: l.name, icon: cur === l.code ? "check" : undefined, run: function () { subtitles.setSecond(l.code) } }
                        })))
                } },
            { label: tr("Picture quality"), value: function () {
                    return s.quality === "auto" ? tr("Auto") + " (" + qualityName(sources.maxResolution()) + ")" : qualityName(parseInt(s.quality, 10))
                },
                hint: tr("Sources above it still show, last and marked"),
                ok: function () {
                    const pick = function (q: settings.Quality): MenuEntry {
                        return { label: q === "auto" ? tr("Auto") : qualityName(parseInt(q, 10)), icon: s.quality === q ? "check" : undefined,
                            run: function () { settings.put("quality", q) } }
                    }
                    app.menu(tr("Picture quality"), [pick("auto"), pick("2160"), pick("1080"), pick("720")])
                } },
            { label: tr("Speed check"), value: function () {
                    if (checking !== null) return checking < 0 ? tr("Checking…") : tr("%1 Mbit/s…", String(checking))
                    const l = speed.last()
                    return l ? tr("%1 Mbit/s", String(l.mbps)) : tr("Not run")
                },
                hint: tr("Measures this TV's internet for a few seconds: Auto picture quality follows it"),
                ok: function () {
                    if (checking !== null) return
                    checking = -1
                    speed.run(function (m) { checking = m; screen.redraw() }).then(function (r) {
                        checking = null
                        screen.redraw()
                        app.toast(tr("%1 Mbit/s: up to %2", String(r.mbps), qualityName(speed.fits(r.mbps))))
                    }, function () {
                        checking = null
                        screen.redraw()
                        app.toast(tr("Couldn't reach the speed test"))
                    })
                } },
            patternRow(app, "preferred", tr("Preferred release patterns"), tr("None. Words in a release name you like, best first, like REMUX or a language tag")),
            patternRow(app, "hidden", tr("Hidden release patterns"), tr("None. Releases with these words never show")),
            { label: tr("Low memory mode"), value: function () { return lowNames[s.lowMode] + (s.lowMode === "auto" ? " (" + (look.lowMemory ? tr("On") : tr("Off")) + ")" : "") },
                hint: tr("Lighter artwork and fewer cards kept, for older TVs"),
                ok: function () { settings.put("lowMode", s.lowMode === "auto" ? "on" : s.lowMode === "on" ? "off" : "auto"); location.reload() } },
            { label: tr("Addons"), value: function () { return n ? trn("%n installed", n) : tr("None") },
                hint: tr("Sources come from Stremio addons: a debrid one plays best on a TV"),
                ok: function () { app.push(addonsScreen(app), false) } },
            { label: tr("Allow torrents"), value: function () { return settings.all().torrents ? tr("On") : tr("Off") },
                hint: tr("Download only, at your own risk. While it's off, torrent sources stay hidden"),
                ok: function () {
                    if (settings.all().torrents) { settings.put("torrents", false); app.toast(tr("Torrent sources are off")); return }
                    app.push(askPrompt(tr("Allow torrents?"), torrentLines(), tr("Allow Torrents"), tr("Not Now"), function () {
                        settings.put("torrents", true)
                        app.pop()
                        app.toast(engine.base() ? tr("Torrent sources are on") : tr("Torrent sources need a streaming server"))
                    }, app.pop), true)
                } },
            { label: tr("Streaming server"), value: function () {
                    const server = settings.all().server
                    return server ? server.replace(/^https?:\/\//, "") : engine.onTv() ? tr("This TV") : tr("None")
                },
                hint: engine.onTv() ? tr("Torrents play on this TV. Or set a computer on your network: Stremio Service or Noonix TV")
                    : tr("Plays torrent sources: Stremio Service or Noonix TV running on a computer on your network"),
                ok: function () { app.push(serverScreen(app), false) } },
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
                        store.remove(profiles.key("progress")); store.remove(profiles.key("watched")); app.toast(tr("Watch history cleared"))
                    } }, { label: tr("Cancel"), run: function () { /* nothing */ } }])
                } },
            { label: tr("Clear cache"), value: function () { return "" }, hint: tr("Lists and artwork are fetched again"),
                ok: function () { store.evict(1); app.toast(tr("Cache cleared")) } },
            { label: tr("Run setup again"), value: function () { return "" },
                ok: function () { store.remove("setup"); store.remove("setupStep"); location.reload() } },
            { label: tr("Updates"), value: function () {
                    return latestSeen === undefined ? tr("Checking…") : latestSeen && updates.newer(latestSeen, __VERSION__) ? tr("%1 is out", latestSeen) : tr("Up to date")
                }, hint: tr("Looks for a new version once a day") + ". " + tr("Install it from github.com/dzeliks/noonix-tv › Releases"),
                ok: function () { /* nothing to run on a tv */ } },
            { label: tr("About"), value: function () { return "Noonix TV " + __VERSION__ + "  ·  " + platform.label + "  ·  Chromium " + platform.chrome },
                ok: function () { /* nothing */ } },
            { label: tr("License"), value: function () { return "GPL 3.0" },
                hint: tr("Free software under the GNU GPL 3.0 or later. Source: github.com/dzeliks/noonix-tv"), ok: function () { /* nothing */ } },
            { label: tr("Terms"), value: function () { return "" },
                hint: tr("A player for your own videos and the sources you add; you answer for what you watch. github.com/dzeliks/noonix-tv › TERMS.md"),
                ok: function () { /* nothing */ } },
            { label: tr("Credits"), value: function () { return "TMDB · Trakt · OpenSubtitles" },
                ok: function () { app.push(creditsScreen(), false) } },
        ]
    })
    updates.latest().then(function (v) { latestSeen = v; screen.redraw() })
    return screen
}

// the qml credits; tmdb's terms: their logo and this exact notice
function creditsScreen(): Screen {
    const line = function (label: string, hint: string): Row { return { label: label, value: function () { return "" }, hint: hint, ok: function () { /* nothing */ } } }
    const screen = listScreen(tr("Credits"), function (): Row[] {
        return [
            line("TMDB", tr("This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB.")),
            line("Trakt", tr("Up Next, watch history and scrobbling through the Trakt API. Not affiliated with Trakt.")),
            line("OpenSubtitles.com", tr("Extra subtitles")),
            line("IntroDB", tr("Intro, recap and credits times")),
            line(tr("Stremio addons"), tr("Noonix TV ships no sources: videos come from your library and the addons and extensions you add")),
            line("torrent-stream", tr("Torrents on this TV (MIT and ISC licenses: engine/NOTICES.txt in the app)")),
            line("Inter", tr("Font by Rasmus Andersson (SIL Open Font License)")),
        ]
    })
    screen.el.appendChild(h("img.tmdblogo", { src: "icons/tmdb.svg" }))
    return screen
}

/** what allowing torrents means (qml SourcesHelp's words) */
function torrentLines(): string[] {
    return [
        tr("A source of yours can answer with torrents: the video comes straight from other people who have it. Noonix TV only downloads, it never shares pieces back, and deletes the file when you stop."),
        tr("It can be slower to start, and videos few people have may not play. Others in the swarm can see your IP address."),
        tr("Downloading videos you have no right to is illegal in many countries. Use it at your own risk, and only for what you're allowed to watch."),
    ]
}

/** the streaming server's address, checked before it's kept */
function serverScreen(app: App): Screen {
    const empty = engine.onTv() ? tr("Its address, e.g. 192.168.1.20 (port 11470 unless you type one). Empty: this TV")
        : tr("Its address, e.g. 192.168.1.20 (port 11470 unless you type one). Empty: none")
    return inputScreen(tr("Streaming server"), empty,
        settings.all().server.replace(/^http:\/\//, "").replace(/:11470$/, ""), function (v) {
            const url = settings.serverUrl(v)
            if (!url) {
                settings.put("server", "")
                app.toast(engine.onTv() ? tr("Torrents play on this TV") : tr("Torrent sources are off"))
                return
            }
            app.toast(tr("Checking %1…", url.replace(/^https?:\/\//, "")))
            sources.checkServer(url).then(function () {
                settings.put("server", url)
                app.toast(tr("Streaming server saved: torrent sources play through it"))
            }, function () {
                app.toast(tr("No streaming server answered at %1", url.replace(/^https?:\/\//, "")))
            })
        }, app.pop)
}

function profilesScreen(app: App): Screen {
    return listScreen(tr("Profiles"), function (): Row[] {
        const cur = profiles.current()
        const rows: Row[] = profiles.list().map(function (p): Row {
            return {
                label: profileName(p), value: function () { return p.id === cur.id ? tr("Watching now") : "" },
                ok: function () {
                    const entries = []
                    if (p.id !== cur.id) entries.push({ label: tr("Switch to %1", profileName(p)), run: function () { profiles.use(p.id); location.reload() } })
                    entries.push({ label: tr("Rename"), run: function () {
                        app.push(inputScreen(tr("Rename"), profileName(p), p.name, function (v) { profiles.rename(p.id, v) }, app.pop), false)
                    } })
                    if (profiles.list().length > 1) entries.push({ label: tr("Remove"), run: function () {
                        app.menu(tr("Remove %1 and what it watched?", profileName(p)), [
                            { label: tr("Remove"), run: function () { const was = cur.id === p.id; profiles.remove(p.id); if (was) location.reload() } },
                            { label: tr("Cancel"), run: function () { /* nothing */ } },
                        ])
                    } })
                    app.menu(profileName(p), entries)
                },
            }
        })
        if (profiles.list().length > 1) rows.push({
            label: tr("Ask who's watching"), value: function () { return settings.all().askProfile ? tr("On") : tr("Off") },
            hint: tr("Open on the last profile without asking who's watching"),
            ok: function () { settings.put("askProfile", !settings.all().askProfile) },
        })
        rows.push({ label: tr("Add a profile"), value: function () { return "" }, ok: function () {
            app.push(inputScreen(tr("Add a profile"), tr("A name"), "", function (v) {
                if (v) { profiles.add(v); app.toast(tr("Added %1", v)) }
            }, app.pop), false)
        } })
        return rows
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

export function traktScreen(app: App): Screen {
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
