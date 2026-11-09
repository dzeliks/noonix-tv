// noonix tv for lg webOS and samsung tizen: boot
import { platform, registerKeys, exitApp } from "./platform"
import { listen, Action } from "./keys"
import { setLanguage } from "./i18n"
import * as settings from "./data/settings"
import * as tmdb from "./data/tmdb"
import * as look from "./ui/look"
import { nextFrame } from "./ui/dom"
import { showSplash } from "./ui/splash"
import { homeScreen } from "./ui/home"
import { App, PlayReq, Screen, MenuEntry } from "./ui/app"
import { playerScreen } from "./ui/player"
import { sourcesScreen } from "./ui/sources"
import { settingsScreen } from "./ui/settings"
import { menuScreen, toast } from "./ui/menu"
import { prepare as preparePlayback } from "./ui/backend"
import { pickerScreen } from "./ui/profiles"
import * as profiles from "./data/profiles"
import { detailsScreen } from "./ui/details"
import { exitPrompt } from "./ui/exitprompt"
import { searchScreen } from "./ui/search"

declare const __VERSION__: string

// details pages kept under the top one (more like this, again and again): older ones are let go
const keepDetails = 3

/** the ui is laid out on a 1920x1080 page, scaled to the window (webOS and tizen apps get 1080p) */
function fitStage(stage: HTMLElement): void {
    const k = Math.min(window.innerWidth / 1920, window.innerHeight / 1080)
    stage.style.transform = stage.style.webkitTransform = "scale(" + k + ")"
    stage.style.left = (window.innerWidth - 1920 * k) / 2 + "px"
    stage.style.top = (window.innerHeight - 1080 * k) / 2 + "px"
}

function boot(): void {
    const stage = document.getElementById("stage") as HTMLElement
    fitStage(stage)
    window.addEventListener("resize", function () { fitStage(stage) })
    registerKeys()
    preparePlayback()
    look.apply()
    setLanguage(settings.all().language)
    console.log("noonix tv " + __VERSION__ + " on " + platform.label + ", chromium " + platform.chrome
        + (look.lowMemory ? ", low memory" : ""))

    const screens: Screen[] = []
    const details: Screen[] = []

    /** a page over the others: fades in, what's under it stops drawing once it's covered */
    function push(s: Screen, over: boolean): void {
        const under = screens[screens.length - 1]
        screens.push(s)
        s.el.className += " screen"
        stage.appendChild(s.el)
        nextFrame(function () { s.el.className += " in" })
        if (under && !over) setTimeout(function () { if (screens[screens.length - 1] === s) under.el.style.display = "none" }, 260)
    }

    function pop(): void {
        const s = screens.pop()
        if (!s) return
        const di = details.indexOf(s)
        if (di >= 0) details.splice(di, 1)
        const under = screens[screens.length - 1]
        if (under) {
            under.el.style.display = ""
            if (under.shown) under.shown()
        }
        s.el.className = s.el.className.replace(/ in\b/g, "")
        setTimeout(function () { if (s.el.parentNode) s.el.parentNode.removeChild(s.el) }, 260)
        if (s.closed) s.closed()
    }

    let player: Screen | null = null

    const app: App = {
        open: openDetails,
        page(id: string): void {
            if (id === "search") push(searchScreen(openDetails), false)
            else if (id === "settings") push(settingsScreen(app), false)
        },
        play(req: PlayReq): void {
            // one player: a source picked while one plays takes its place
            if (player) {
                while (screens.length > 1 && screens[screens.length - 1] !== player) pop()
                if (screens[screens.length - 1] === player) pop()
            }
            const p = playerScreen(app, req)
            player = p
            const closed = p.closed
            p.closed = function () { if (player === p) player = null; if (closed) closed() }
            push(p, false)
        },
        sources(req: PlayReq): void { push(sourcesScreen(app, req), false) },
        menu(title: string, entries: MenuEntry[]): void {
            if (!entries.length) return
            push(menuScreen(title, entries, pop), true)
        },
        push: push,
        pop: pop,
        toast(text: string): void { toast(stage, text) },
    }

    function openDetails(it: tmdb.Item): void {
        const d = detailsScreen(it, app)
        push(d, false)
        details.push(d)
        if (details.length > keepDetails) {
            const old = details.shift() as Screen
            screens.splice(screens.indexOf(old), 1)
            if (old.el.parentNode) old.el.parentNode.removeChild(old.el)
            if (old.closed) old.closed()
        }
    }

    // the home builds under the splash, so its first rows are there when it lifts
    const homeEl = homeScreen(app)
    screens.push(homeEl)
    stage.appendChild(homeEl.el)
    let ready = false
    // more than one profile: who's watching, once a run (a switch reloads past it)
    let picked = false
    try { picked = sessionStorage.getItem("noonix:picked") === "1" } catch (e) { /* no session storage */ }
    if (profiles.list().length > 1 && !picked) {
        push(pickerScreen(function (p) {
            try { sessionStorage.setItem("noonix:picked", "1") } catch (e) { /* asked again next run */ }
            if (p.id !== profiles.current().id) { profiles.use(p.id); location.reload(); return }
            pop()
        }), true)
    }
    showSplash(stage, __VERSION__).then(function () { ready = true })
    listen(function (a: Action) {
        if (!ready) return
        if (a === "leave") { exitApp(); return }
        const top = screens[screens.length - 1]
        if (top.action(a) || a !== "back") return
        if (screens.length > 1) { pop(); return }
        // back with nothing left to close: ask first
        push(exitPrompt(exitApp, pop), true)
    })
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot)
else boot()
