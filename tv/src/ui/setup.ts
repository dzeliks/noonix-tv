// first run (qml Setup, cut to a tv): language, welcome, the terms, an addon, trakt, done
import { h, clear } from "./dom"
import { tr, setLanguage } from "../i18n"
import { Action } from "../keys"
import { App, Screen } from "./app"
import { inputScreen } from "./input"
import { traktScreen } from "./settings"
import * as settings from "../data/settings"
import * as sources from "../data/sources"
import * as store from "../data/store"
import * as trakt from "../data/trakt"

// bumped when the terms change: everyone agrees again
const termsVersion = 1

export function needed(): boolean { return store.get<number>("setup", 0) < termsVersion }

interface Button { label: string; run(): void }

export function setupScreen(app: App, done: () => void): Screen {
    const steps = ["language", "welcome", "terms", "sources"].concat(trakt.available() ? ["trakt"] : [], ["done"])
    // a language pick reloads the app: it comes back on the next step
    let step = Math.max(0, Math.min(steps.length - 1, store.get<number>("setupStep", 0)))
    let at = 0
    let buttons: Button[] = []
    const count = h("div.sstep")
    const title = h("div.stitle")
    const sub = h("div.ssub")
    const body = h("div.sbody")
    const row = h("div.sbuttons")
    const el = h("div.setup", null, h("div.sbox", null, count, title, sub, body, row))

    function go(n: number): void {
        step = n
        store.set("setupStep", n)
        at = 0
        draw()
    }
    function next(): void {
        if (step < steps.length - 1) { go(step + 1); return }
        store.set("setup", termsVersion)
        store.remove("setupStep")
        done()
    }
    function back(): void { if (step > 0) go(step - 1) }

    function draw(): void {
        const name = steps[step]
        count.textContent = tr("Step %1 of %2", step + 1, steps.length)
        clear(body)
        const added = sources.addons()
        const user = trakt.user()
        if (name === "language") {
            title.textContent = tr("Choose your language")
            sub.textContent = tr("You can change it any time in Settings.")
            const pick = function (l: "en" | "sr") {
                return function () {
                    store.set("setupStep", step + 1)
                    if (settings.all().language === l) { go(step + 1); return }
                    settings.put("language", l)
                    setLanguage(l)
                    location.reload()
                }
            }
            buttons = [{ label: "English", run: pick("en") }, { label: "Srpski", run: pick("sr") }]
            if (settings.all().language === "sr") at = 1
        } else if (name === "welcome") {
            title.textContent = tr("Welcome to Noonix TV")
            sub.textContent = tr("Your own movies and shows, and the sources you add, on this TV. A few steps and you're watching.")
            buttons = [{ label: tr("Get Started"), run: next }]
        } else if (name === "terms") {
            title.textContent = tr("Before you start")
            sub.textContent = tr("Please read this, then agree to go on.")
            body.appendChild(h("div.sterms", null,
                h("p", { text: tr("Noonix TV is only a player. It comes with no videos and no sources: it plays the files on your device and whatever addons or extensions you add yourself.") }),
                h("p", { text: tr("You're responsible for what you watch and download with it. Only use videos you have the right to, and follow the laws where you live.") }),
                h("p.small", { text: tr("Noonix TV is free software (GNU GPL 3.0) and comes with no warranty. Full terms: github.com/dzeliks/noonix-tv › TERMS.md") })))
            buttons = [{ label: tr("I Agree"), run: next }]
        } else if (name === "sources") {
            title.textContent = tr("Your videos")
            sub.textContent = tr("Sources come from Stremio addons: a debrid one plays best on a TV")
            body.appendChild(h("div.snote", { text: added.length ? added.map(function (a) { return a.name }).join("  ·  ")
                : tr("Its manifest link, e.g. from your debrid addon's configure page") }))
            buttons = [
                { label: tr("Add an addon"), run: function () {
                    app.push(inputScreen(tr("Add an addon"), tr("The manifest link (…/manifest.json)"), "https://", function (v) {
                        if (!v || v === "https://") return
                        app.toast(tr("Reading the addon…"))
                        sources.addAddon(v).then(function (a) { app.toast(tr("Added %1", a.name)); draw() }, function (e) {
                            app.toast(tr("Not added: %1", String(e.message || e)))
                        })
                    }, app.pop), false)
                } },
                { label: added.length ? tr("Continue") : tr("Skip for Now"), run: next },
            ]
            if (added.length) at = 1
        } else if (name === "trakt") {
            title.textContent = "Trakt"
            sub.textContent = tr("Optional: Trakt keeps what you watched in sync.")
            body.appendChild(h("div.snote", { text: user ? tr("Signed in as %1", user) : tr("Not signed in") }))
            buttons = user ? [{ label: tr("Continue"), run: next }]
                : [{ label: tr("Sign in"), run: function () { app.push(traktScreen(app), false) } }, { label: tr("Skip for Now"), run: next }]
        } else {
            title.textContent = tr("You're all set")
            sub.textContent = added.length ? tr("That's everything. You can change any of it later in Settings.")
                : tr("Almost there. You can start now and add the rest later in Settings.")
            buttons = [{ label: tr("Start Watching"), run: next }]
        }
        if (step > 0 && name !== "done") buttons.push({ label: tr("Back"), run: back })
        at = Math.min(at, buttons.length - 1)
        light()
    }

    function light(): void {
        clear(row)
        buttons.forEach(function (b, i) { row.appendChild(h("div.button" + (i === at ? ".lit" : ""), { text: b.label })) })
    }

    draw()
    return {
        el,
        action(a: Action): boolean {
            if (a === "left" && at > 0) at--
            else if (a === "right" && at < buttons.length - 1) at++
            else if (a === "ok") { buttons[at].run(); return true }
            else if (a === "back") { back(); return true }
            light()
            return true
        },
        // back from the keyboard or the trakt code: what changed shows
        shown(): void { draw() },
    }
}
