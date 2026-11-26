// glass on tvs that can't blur what's behind a panel (chromium < 76, low memory mode):
// a tiny blurred copy of the page's backdrop and shade, made once per backdrop, and each panel
// draws its own bit of it under a tint. nothing blurs while a frame is drawn, so it costs about nothing
// over video there's nothing to copy (the video is its own plane): panels there stay solid

/** paints a page's shade over its backdrop, on a w x h canvas standing for the 1920x1080 page */
export type Shade = (ctx: CanvasRenderingContext2D, w: number, h: number) => void

interface Source { canvas: HTMLCanvasElement; ready: boolean }
interface Glass { el: HTMLElement; canvas: HTMLCanvasElement; next: HTMLCanvasElement; drawn: Source | null; fade: number }

// the copy is a tenth of the page: 192x108, stretched back up it's blurred enough on its own
const SCALE = 10
const W = 1920 / SCALE
const H = 1080 / SCALE

let on = false
let base: HTMLElement | null = null
const sources: { page: HTMLElement; src: Source }[] = []
let glasses: Glass[] = []

export function enable(yes: boolean): void { on = yes }
export function enabled(): boolean { return on }

/** the page's backdrop changed (it has loaded): its panels redraw */
export function source(page: HTMLElement, img: HTMLImageElement | null, shade: Shade): void {
    if (!on) return
    let entry = sources.filter(function (s) { return s.page === page })[0]
    if (!entry) { entry = { page, src: { canvas: document.createElement("canvas"), ready: false } }; sources.push(entry) }
    // a new copy object per backdrop: panels showing the old one fade over to it
    const canvas = document.createElement("canvas")
    canvas.width = W
    canvas.height = H
    entry.src = { canvas, ready: !!img && paint(canvas, img as HTMLImageElement, shade) }
    redraw(true)
    forget()
}

function paint(canvas: HTMLCanvasElement, img: HTMLImageElement, shade: Shade): boolean {
    const ctx = canvas.getContext("2d")
    if (!ctx) return false
    try {
        if ((ctx as any).filter !== undefined) {
            ctx.filter = "blur(3px) saturate(1.5)"
            // the blur pulls in black at the edges: drawn a little bigger than the page
            ctx.drawImage(img, -8, -8, W + 16, H + 16)
            ctx.filter = "none"
        } else {
            // no canvas filters: down to a few pixels and back up is soft enough
            const small = document.createElement("canvas")
            small.width = 32
            small.height = 18
            const sx = small.getContext("2d") as CanvasRenderingContext2D
            sx.drawImage(img, 0, 0, 32, 18)
            ctx.drawImage(small, 0, 0, W, H)
        }
        shade(ctx, W, H)
        return true
    } catch (e) {
        return false
    }
}

/** the page now under everything (the topmost that isn't a panel or a menu) */
export function setBase(page: HTMLElement | null): void {
    base = page
    if (on) redraw(false)
}

/** puts glass under a panel; again after its children were cleared is fine */
export function glass(el: HTMLElement): void {
    if (!on) return
    let g = glasses.filter(function (x) { return x.el === el })[0]
    if (!g) {
        const canvas = document.createElement("canvas")
        canvas.className = "frostglass"
        canvas.width = canvas.height = 2
        g = { el, canvas, next: document.createElement("canvas"), drawn: null, fade: 0 }
        glasses.push(g)
        el.style.zIndex = "0"
    }
    if (g.canvas.parentNode !== el) {
        el.insertBefore(g.canvas, el.firstChild)
        // the panel's edge line goes back over the glass
        const line = document.createElement("i")
        line.className = "frostline"
        el.insertBefore(line, g.canvas.nextSibling)
    }
    const mine = g
    requestAnimationFrame(function () { draw(mine, false) })
}

/** panels moved (a page scrolled): they draw what's behind them now */
export function refresh(): void {
    if (on) redraw(false)
}

function redraw(fade: boolean): void {
    glasses = glasses.filter(function (g) { return document.body.contains(g.el) })
    glasses.forEach(function (g) { draw(g, fade) })
}

// pages gone from the stage take their copies with them
function forget(): void {
    for (let i = sources.length - 1; i >= 0; i--) if (!document.body.contains(sources[i].page)) sources.splice(i, 1)
}

function current(): Source | null {
    const s = sources.filter(function (x) { return x.page === base })[0]
    return s && s.src.ready ? s.src : null
}

function draw(g: Glass, fade: boolean): void {
    const src = current()
    if (!src) { g.canvas.style.visibility = "hidden"; g.drawn = null; return }
    // hidden (a covered page): it draws when it's back
    if (!g.el.offsetParent && g.el.style.position !== "fixed") return
    const stage = document.getElementById("stage")
    if (!stage) return
    const sr = stage.getBoundingClientRect()
    const k = sr.width / 1920 || 1
    const r = g.el.getBoundingClientRect()
    const x = (r.left - sr.left) / k
    const y = (r.top - sr.top) / k
    const w = r.width / k
    const ht = r.height / k
    if (w < 1 || ht < 1) return
    const cw = Math.max(2, Math.ceil(w / SCALE))
    const ch = Math.max(2, Math.ceil(ht / SCALE))
    const css = getComputedStyle(g.el)
    const under = css.getPropertyValue("--glass-under").trim()
    const tint = css.getPropertyValue("--glass").trim()

    const fresh = g.next
    fresh.width = cw
    fresh.height = ch
    const fx = fresh.getContext("2d")
    if (!fx) return
    fx.drawImage(src.canvas, x / SCALE, y / SCALE, w / SCALE, ht / SCALE, 0, 0, cw, ch)
    if (under) { fx.fillStyle = under; fx.fillRect(0, 0, cw, ch) }
    if (tint) { fx.fillStyle = tint; fx.fillRect(0, 0, cw, ch) }

    const sized = g.canvas.width === cw && g.canvas.height === ch
    const ctx = g.canvas.getContext("2d")
    if (!ctx) return
    g.canvas.style.visibility = ""
    // a new backdrop fades in like the page's own does (0.6 s); a move or a first draw is at once
    if (!fade || !sized || !g.drawn || g.drawn === src) {
        if (!sized) { g.canvas.width = cw; g.canvas.height = ch }
        ctx.globalAlpha = 1
        ctx.drawImage(fresh, 0, 0)
        g.drawn = src
        return
    }
    g.drawn = src
    const start = Date.now()
    const id = ++g.fade
    let was = 0
    const step = function (): void {
        if (id !== g.fade) return
        const p = Math.min(1, (Date.now() - start) / 600)
        // drawing over what's there: this alpha makes the mix exactly p of the new one
        ctx.globalAlpha = p >= 1 ? 1 : 1 - (1 - p) / (1 - was)
        ctx.drawImage(fresh, 0, 0)
        was = p
        if (p < 1) requestAnimationFrame(step)
        else ctx.globalAlpha = 1
    }
    requestAnimationFrame(step)
}

// ---- the pages' shades (style.css .shade, .details .shade-side + .shade-low)

function vertical(ctx: CanvasRenderingContext2D, y0: number, y1: number, w: number, stops: [number, number][]): void {
    const g = ctx.createLinearGradient(0, y0, 0, y1)
    stops.forEach(function (s) { g.addColorStop(s[0], "rgba(0,0,0," + s[1] + ")") })
    ctx.fillStyle = g
    ctx.fillRect(0, y0, w, y1 - y0)
}

function horizontal(ctx: CanvasRenderingContext2D, w: number, h: number, stops: [number, number][]): void {
    const g = ctx.createLinearGradient(0, 0, w, 0)
    stops.forEach(function (s) { g.addColorStop(s[0], "rgba(0,0,0," + s[1] + ")") })
    ctx.fillStyle = g
    ctx.fillRect(0, 0, w, h)
}

export const homeShade: Shade = function (ctx, w, h) {
    horizontal(ctx, w, h, [[0, 0.7], [0.5, 0.25], [0.75, 0]])
    vertical(ctx, 0, h, w, [[0, 0.35], [0.22, 0], [0.4, 0], [0.62, 0.88], [0.82, 1], [1, 1]])
}

export const detailsShade: Shade = function (ctx, w, h) {
    horizontal(ctx, w, h, [[0, 0.88], [0.55, 0.5], [1, 0.15]])
    vertical(ctx, h - h * 594 / 1080, h, w, [[0, 0], [0.6, 0.9], [1, 1]])
}
