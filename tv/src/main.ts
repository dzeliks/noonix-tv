// noonix tv for lg webOS and samsung tizen: boot
import { platform, registerKeys, exitApp } from "./platform"
import { listen, Action } from "./keys"
import { setLanguage } from "./i18n"
import * as settings from "./data/settings"
import * as look from "./ui/look"
import { showSplash } from "./ui/splash"
import { homeScreen, Screen } from "./ui/home"
import { exitPrompt } from "./ui/exitprompt"

declare const __VERSION__: string

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

    // the home builds under the splash, so its first rows are there when it lifts
    const screens: Screen[] = [homeScreen()]
    stage.appendChild(screens[0].el)
    let ready = false
    showSplash(stage, __VERSION__).then(function () { ready = true })
    listen(function (a: Action) {
        if (!ready) return
        if (a === "leave") { exitApp(); return }
        const top = screens[screens.length - 1]
        if (top.action(a) || a !== "back" || screens.length > 1) return
        // back with nothing left to close: ask first
        const prompt = exitPrompt(exitApp, function () { screens.pop() })
        screens.push(prompt)
        stage.appendChild(prompt.el)
    })
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot)
else boot()
