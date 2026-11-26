// the options menu (ok held, qml OptionsMenu) and short notes at the bottom (qml Toast)
import { h } from "./dom"
import { Action } from "../keys"
import { icon } from "./icons"
import * as frost from "./frost"
import { MenuEntry, MenuAt, Screen } from "./app"

export function menuScreen(title: string, entries: MenuEntry[], close: () => void, place?: MenuAt): Screen {
    let at = 0
    // the icon column only when one of them has an icon (a check)
    const icons = entries.some(function (e) { return !!e.icon })
    const texts: HTMLElement[] = []
    const rows = entries.map(function (e) {
        const t = h("div.mtext", null, h("span", { text: e.label }))
        texts.push(t)
        return icons ? h("div.mrow", null, e.icon ? icon(e.icon, 30) : h("span.ico.blank"), t) : h("div.mrow", null, t)
    })
    const track = h("div.mtrack", null, ...rows)
    const box = h("div.mbox", null, h("div.mtitle", { text: title }), h("div.mlist", null, track))
    const el = h("div.menu" + (place ? ".at" : ""), null, box)
    if (place) { box.style.left = place.left + "px"; box.style.bottom = place.bottom + "px" }
    frost.glass(box)
    // a long one scrolls: the lit row stays a couple in from the edges
    const shown = 9
    if (rows.length > shown) box.className += " long"
    // the lit row's text, too long for the box, runs to its end and back (qml Marquee)
    let run = 0
    function marquee(): void {
        const mine = ++run
        texts.forEach(function (t) {
            t.className = "mtext"
            const sp = t.firstChild as HTMLElement
            sp.style.webkitTransition = sp.style.transition = "none"
            sp.style.webkitTransform = sp.style.transform = ""
        })
        const t = texts[at]
        if (!t) return
        const sp = t.firstChild as HTMLElement
        const go = function (): void {
            if (mine !== run || !el.parentNode) return
            t.className = "mtext run"
            const over = sp.offsetWidth - t.clientWidth
            if (over <= 0) { t.className = "mtext"; return }
            const secs = Math.max(1.5, over / 80)
            sp.style.webkitTransition = sp.style.transition = "-webkit-transform " + secs + "s linear, transform " + secs + "s linear"
            sp.style.webkitTransform = sp.style.transform = "translate3d(" + (-over) + "px,0,0)"
            setTimeout(function () {
                if (mine !== run) return
                sp.style.webkitTransition = sp.style.transition = "none"
                sp.style.webkitTransform = sp.style.transform = ""
                setTimeout(go, 1200)
            }, secs * 1000 + 1500)
        }
        setTimeout(go, 1000)
    }
    function light(): void {
        for (let i = 0; i < rows.length; i++) rows[i].className = "mrow" + (i === at ? " lit" : "")
        marquee()
        const first = Math.max(0, Math.min(at - 4, rows.length - shown))
        track.style.transform = track.style.webkitTransform = "translate3d(0," + (-first * 84) + "px,0)"
    }
    light()
    return {
        el,
        action(a: Action): boolean {
            if (a === "up" && at > 0) at--
            else if (a === "down" && at < rows.length - 1) at++
            else if (a === "ok") { const e = entries[at]; run++; close(); e.run(); return true }
            else if (a === "back" || a === "menu") { run++; close(); return true }
            light()
            return true
        },
    }
}

let toastEl: HTMLElement | null = null
let toastTimer = 0

export function toast(stage: HTMLElement, text: string, ms: number): void {
    if (!toastEl) {
        toastEl = h("div.toast")
        stage.appendChild(toastEl)
    }
    const t = toastEl
    t.textContent = text
    t.className = "toast on"
    clearTimeout(toastTimer)
    toastTimer = window.setTimeout(function () { t.className = "toast" }, ms || 2600)
}
