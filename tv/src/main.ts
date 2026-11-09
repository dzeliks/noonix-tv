// noonix tv for lg webOS and samsung tizen: boot
import { platform, registerKeys, exitApp } from "./platform"
import { listen, Action } from "./keys"
import { setLanguage } from "./i18n"
import * as settings from "./data/settings"
import * as tmdb from "./data/tmdb"
import * as look from "./ui/look"
import { nextFrame } from "./ui/dom"
import { showSplash } from "./ui/splash"
import { homeScreen, Screen } from "./ui/home"
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

    function openDetails(it: tmdb.Item): void {
        const d = detailsScreen(it, openDetails)
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
    const homeEl = homeScreen({
        open: openDetails,
        page(id: string): void {
            if (id === "search") push(searchScreen(openDetails), false)
            // TODO(F3d): library and settings
        },
    })
    screens.push(homeEl)
    stage.appendChild(homeEl.el)
    let ready = false
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
