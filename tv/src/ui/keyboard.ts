// on-screen keyboard for search (qml Keyboard): the remote moves a focus over the keys
import { h, clear } from "./dom"
import { tr } from "../i18n"
import { Action } from "../keys"

interface Key { t: string; w: number; k: "c" | "f" | "gap"; v: string }

function c(ch: string): Key { return { t: ch, w: 1, k: "c", v: ch } }
function f(label: string, w: number, v: string): Key { return { t: label, w: w, k: "f", v: v } }
function g(w: number): Key { return { t: "", w: w, k: "gap", v: "" } }
function chars(s: string): Key[] { return s.split(" ").map(c) }

function pages(enter: string): { [name: string]: Key[][] } {
    const last = function (page: Key): Key[] { return [page, f(tr("space"), 4.5, "space"), f(tr("clear"), 1.5, "clear"), f(enter, 2.5, "enter")] }
    return {
        abc: [
            chars("q w e r t y u i o p"),
            [g(0.5)].concat(chars("a s d f g h j k l"), [g(0.5)]),
            [f("⇧", 1.5, "shift")].concat(chars("z x c v b n m"), [f("⌫", 1.5, "backspace")]),
            last(f("123", 1.5, "page:123")),
        ],
        "123": [
            chars("1 2 3 4 5 6 7 8 9 0"),
            chars("- / : ; ( ) $ & @ \""),
            [f("#+=", 1.5, "page:sym")].concat(chars(". , ? ! ' | ~"), [f("⌫", 1.5, "backspace")]),
            last(f("ABC", 1.5, "page:abc")),
        ],
        sym: [
            chars("[ ] { } # % ^ * + ="),
            chars("_ \\ < > & ` $ ~ : \""),
            [f("123", 1.5, "page:123")].concat(chars(". , ? ! ' @ %"), [f("⌫", 1.5, "backspace")]),
            last(f("ABC", 1.5, "page:abc")),
        ],
    }
}

export interface Keyboard {
    el: HTMLElement
    /** a remote key while the focus is here; false: it leaves (the direction it went) */
    action(a: Action): boolean
    setActive(on: boolean): void
}

/** typed: a character; special: backspace, clear, enter; the unit is a key's width in px */
export function keyboard(unit: number, enter: string, typed: (s: string) => void, special: (name: string) => void): Keyboard {
    const gap = 10
    const keyH = Math.round(unit * 1.3)
    const all = pages(enter)
    let page = "abc"
    let shift = false
    let row = 2
    let col = 4
    let active = false
    let keyEls: HTMLElement[][] = []
    const el = h("div.kb")

    function x(r: number, i: number): number {
        // the centre of key i in row r, in units
        let at = 0
        const keys = all[page][r]
        for (let j = 0; j < i; j++) at += keys[j].w
        return at + keys[i].w / 2
    }

    function nearest(r: number, cx: number): number {
        const keys = all[page][r]
        let best = 0
        let bestD = 1e9
        for (let i = 0; i < keys.length; i++) {
            if (keys[i].k === "gap") continue
            const d = Math.abs(x(r, i) - cx)
            if (d < bestD) { bestD = d; best = i }
        }
        return best
    }

    function build(): void {
        clear(el)
        keyEls = all[page].map(function (keys, r) {
            const rowEl = h("div.kbrow")
            rowEl.style.height = keyH + "px"
            el.appendChild(rowEl)
            return keys.map(function (k) {
                const w = k.w * unit + (k.w - 1) * gap
                const kEl = h("div.key" + (k.k === "f" ? ".fn" : "") + (k.k === "gap" ? ".gap" : ""), { text: label(k) })
                kEl.style.width = w + "px"
                kEl.style.height = keyH + "px"
                kEl.style.lineHeight = keyH + "px"
                rowEl.appendChild(kEl)
                return kEl
            })
        })
        if (col >= all[page][row].length || all[page][row][col].k === "gap") col = nearest(row, 5)
        light()
    }

    function label(k: Key): string {
        return k.k === "c" && shift ? k.t.toUpperCase() : k.t
    }

    function light(): void {
        for (let r = 0; r < keyEls.length; r++) {
            for (let i = 0; i < keyEls[r].length; i++) {
                const k = all[page][r][i]
                keyEls[r][i].className = "key" + (k.k === "f" ? " fn" : "") + (k.k === "gap" ? " gap" : "")
                    + (k.v === "shift" && shift ? " on" : "") + (active && r === row && i === col ? " lit" : "")
            }
        }
    }

    function press(): void {
        const k = all[page][row][col]
        if (k.k === "c") {
            typed(shift ? k.v.toUpperCase() : k.v)
            if (shift) { shift = false; build() }
        } else if (k.v === "shift") { shift = !shift; build() }
        else if (k.v === "space") typed(" ")
        else if (k.v.indexOf("page:") === 0) { page = k.v.slice(5); shift = false; build() }
        else special(k.v)
    }

    function action(a: Action): boolean {
        const keys = all[page]
        if (a === "left" || a === "right") {
            const dir = a === "left" ? -1 : 1
            let n = col + dir
            while (n >= 0 && n < keys[row].length && keys[row][n].k === "gap") n += dir
            if (n < 0 || n >= keys[row].length) return false
            col = n
        } else if (a === "up" || a === "down") {
            const n = row + (a === "up" ? -1 : 1)
            if (n < 0 || n >= keys.length) return false
            col = nearest(n, x(row, col))
            row = n
        } else if (a === "ok") press()
        else if (a === "back") return false
        else return true
        light()
        return true
    }

    build()
    return {
        el,
        action,
        setActive(on: boolean): void { active = on; light() },
    }
}
