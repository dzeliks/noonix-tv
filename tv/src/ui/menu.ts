// the options menu (ok held, qml OptionsMenu) and short notes at the bottom (qml Toast)
import { h } from "./dom"
import { Action } from "../keys"
import { icon } from "./icons"
import { MenuEntry, Screen } from "./app"

export function menuScreen(title: string, entries: MenuEntry[], close: () => void): Screen {
    let at = 0
    const rows = entries.map(function (e) {
        return h("div.mrow", null, e.icon ? icon(e.icon, 30) : h("span.ico.blank"), h("span", { text: e.label }))
    })
    const box = h("div.mbox", null, h("div.mtitle", { text: title }), ...rows)
    const el = h("div.menu", null, box)
    function light(): void { for (let i = 0; i < rows.length; i++) rows[i].className = "mrow" + (i === at ? " lit" : "") }
    light()
    return {
        el,
        action(a: Action): boolean {
            if (a === "up" && at > 0) at--
            else if (a === "down" && at < rows.length - 1) at++
            else if (a === "ok") { const e = entries[at]; close(); e.run(); return true }
            else if (a === "back" || a === "menu") { close(); return true }
            light()
            return true
        },
    }
}

let toastEl: HTMLElement | null = null
let toastTimer = 0

export function toast(stage: HTMLElement, text: string): void {
    if (!toastEl) {
        toastEl = h("div.toast")
        stage.appendChild(toastEl)
    }
    const t = toastEl
    t.textContent = text
    t.className = "toast on"
    clearTimeout(toastTimer)
    toastTimer = window.setTimeout(function () { t.className = "toast" }, 2600)
}
