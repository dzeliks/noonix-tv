// a sideways row of cards (qml MediaRow): the focus rests a couple of slots in, art only near the view
import { h } from "./dom"
import * as look from "./look"

export interface StripKind<T> {
    width: number
    gap: number
    /** the card's art url (already sized) */
    art(it: T): string | null
    /** extra lines under the art (episode cards) */
    lines?(it: T): HTMLElement[]
    /** the class on the card: "card" plus this */
    cls?: string
}

export interface Strip<T> {
    track: HTMLElement
    items: T[]
    cards: HTMLElement[]
    at: number
    fill(items: T[]): void
    /** lit: the focused card shows it; near: this strip is close enough to the view to keep art */
    place(lit: boolean, near: boolean): void
    current(): T | undefined
}

const restSlot = 2
const room = 1920 - 2 * 96

export function strip<T>(kind: StripKind<T>): Strip<T> {
    const track = h("div.track")
    const s: Strip<T> = {
        track,
        items: [],
        cards: [],
        at: 0,
        fill(items: T[]): void {
            while (track.firstChild) track.removeChild(track.firstChild)
            s.items = items
            s.at = Math.min(s.at, Math.max(0, items.length - 1))
            s.cards = items.map(function (it) {
                const card = h("div.card" + (kind.cls ? "." + kind.cls : ""), null, h("div.art"), ...(kind.lines ? kind.lines(it) : []))
                track.appendChild(card)
                return card
            })
        },
        place(lit: boolean, near: boolean): void {
            const step = kind.width + kind.gap
            const first = Math.max(0, Math.min(s.at - restSlot, s.cards.length - Math.floor((room + kind.gap) / step)))
            track.style.transform = track.style.webkitTransform = "translate3d(" + (-first * step) + "px,0,0)"
            const keep = look.lowMemory ? 10 : 16
            const base = "card" + (kind.cls ? " " + kind.cls : "")
            for (let i = 0; i < s.cards.length; i++) {
                const c = s.cards[i]
                c.className = base + (lit && i === s.at ? " lit" : "")
                const box = c.firstChild as HTMLElement
                const url = near && i >= s.at - keep && i <= s.at + keep ? kind.art(s.items[i]) : null
                const has = box.getAttribute("data-src")
                if (url && has !== url) {
                    box.style.backgroundImage = "url(\"" + url + "\")"
                    box.setAttribute("data-src", url)
                } else if (!url && has) {
                    box.style.backgroundImage = ""
                    box.removeAttribute("data-src")
                }
            }
        },
        current(): T | undefined { return s.items[s.at] },
    }
    return s
}

/** a step left or right; false at the ends */
export function step<T>(s: Strip<T>, dir: number): boolean {
    const n = s.at + dir
    if (n < 0 || n >= s.items.length) return false
    s.at = n
    return true
}
