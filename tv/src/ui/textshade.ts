// a soft shade behind text over artwork (qml TextShade): each row of text a rounded bar its own length,
// a logo by its own shape, blurred together once into a small canvas. nothing works while a frame draws

const SCALE = 4
// the bars reach a little past the words, the blur takes them out smoothly from there
const PAD_X = 18
const PAD_Y = 6
const BLUR = 22

/** the bars' reach and the blur: a lone short line (a clock) wants both close, a wide blur leaves nothing of it */
export interface ShadeLook { padX?: number; padY?: number; blur?: number }
/** the clocks: close round the line like a description's rows (qml TopNav/Osd) */
export const CLOCK_SHADE: ShadeLook = { padX: 13, padY: 5, blur: 11 }

export interface TextShade {
    el: HTMLCanvasElement
    /** the text or the logo changed: drawn again on the next frame */
    update(): void
}

/** host: a positioned element the canvas goes into (under its text); parts: what to shade */
export function textShade(host: HTMLElement, parts: () => HTMLElement[], strength: number, look?: ShadeLook): TextShade {
    const k = { padX: PAD_X, padY: PAD_Y, blur: BLUR, ...(look || {}) }
    const el = document.createElement("canvas")
    el.className = "tshade"
    el.style.opacity = String(strength)
    host.style.zIndex = "0"
    host.insertBefore(el, host.firstChild)
    let queued = false
    return {
        el,
        update(): void {
            if (queued) return
            queued = true
            requestAnimationFrame(function () { queued = false; draw(host, el, parts(), k) })
        },
    }
}

interface Bar { x: number; y: number; w: number; h: number }

function draw(host: HTMLElement, el: HTMLCanvasElement, parts: HTMLElement[], look: Required<ShadeLook>): void {
    const PAD_X = look.padX, PAD_Y = look.padY, BLUR = look.blur, EDGE = PAD_X + 3 * BLUR
    if (!host.offsetParent) return
    const stage = document.getElementById("stage")
    const k = stage ? stage.getBoundingClientRect().width / 1920 || 1 : 1
    const hr = host.getBoundingClientRect()
    const bars: Bar[] = []
    const imgs: { img: HTMLImageElement; r: Bar }[] = []
    const at = function (r: ClientRect): Bar {
        return { x: (r.left - hr.left) / k, y: (r.top - hr.top) / k, w: r.width / k, h: r.height / k }
    }
    parts.forEach(function (p) {
        if (!p.offsetParent || getComputedStyle(p).visibility === "hidden") return
        if (p.tagName === "IMG") {
            const img = p as HTMLImageElement
            if (img.complete && img.naturalWidth) imgs.push({ img, r: at(img.getBoundingClientRect()) })
            return
        }
        lines(p).forEach(function (r) { bars.push(at(r)) })
    })
    if (!bars.length && !imgs.length) { el.style.display = "none"; return }

    // the rows: fragments on one line (a bold word, a span) are one bar
    const rows: Bar[] = []
    bars.forEach(function (b) {
        const same = rows.filter(function (r) { return Math.abs(r.y + r.h / 2 - (b.y + b.h / 2)) < b.h / 2 })[0]
        if (!same) { rows.push({ x: b.x, y: b.y, w: b.w, h: b.h }); return }
        const x1 = Math.max(same.x + same.w, b.x + b.w)
        same.x = Math.min(same.x, b.x)
        same.w = x1 - same.x
    })

    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    rows.concat(imgs.map(function (i) { return i.r })).forEach(function (r) {
        x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y); x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h)
    })
    x0 -= EDGE; y0 -= EDGE; x1 += EDGE; y1 += EDGE
    const w = Math.ceil((x1 - x0) / SCALE)
    const h = Math.ceil((y1 - y0) / SCALE)

    const mask = document.createElement("canvas")
    mask.width = w
    mask.height = h
    const m = mask.getContext("2d")
    const ctx = el.getContext("2d")
    if (!m || !ctx) return
    m.fillStyle = "#000"
    rows.forEach(function (r) {
        pill(m, (r.x - PAD_X - x0) / SCALE, (r.y - PAD_Y - y0) / SCALE, (r.w + 2 * PAD_X) / SCALE, (r.h + 2 * PAD_Y) / SCALE)
    })
    // a logo a little thicker than it's drawn: thin letters still get some shade
    const grow = [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1], [0.7, 0.7], [-0.7, 0.7], [0.7, -0.7], [-0.7, -0.7]]
    imgs.forEach(function (i) {
        grow.forEach(function (g) {
            m.drawImage(i.img, (i.r.x - x0 + g[0] * PAD_Y) / SCALE, (i.r.y - y0 + g[1] * PAD_Y) / SCALE, i.r.w / SCALE, i.r.h / SCALE)
        })
    })
    // the logo's colours go: only its shape is kept
    m.globalCompositeOperation = "source-in"
    m.fillRect(0, 0, w, h)

    el.width = w
    el.height = h
    ctx.clearRect(0, 0, w, h)
    if ((ctx as any).filter !== undefined) {
        ctx.filter = "blur(" + (BLUR / SCALE) + "px)"
        ctx.drawImage(mask, 0, 0)
        ctx.filter = "none"
    } else {
        // no canvas filters: down and back up, twice, is soft enough
        const small = document.createElement("canvas")
        small.width = Math.max(1, Math.round(w / 6))
        small.height = Math.max(1, Math.round(h / 6))
        const s = small.getContext("2d") as CanvasRenderingContext2D
        s.drawImage(mask, 0, 0, small.width, small.height)
        ctx.drawImage(small, 0, 0, w, h)
    }
    el.style.left = x0 + "px"
    el.style.top = y0 + "px"
    el.style.width = (x1 - x0) + "px"
    el.style.height = (y1 - y0) + "px"
    el.style.display = ""
}

/** the boxes of the text's lines, as laid out, cut to the element (a clamped plot, an ellipsis) */
function lines(p: HTMLElement): ClientRect[] {
    const out: ClientRect[] = []
    const box = p.getBoundingClientRect()
    const walk = document.createTreeWalker(p, NodeFilter.SHOW_TEXT)
    const range = document.createRange()
    let n = walk.nextNode()
    while (n) {
        if (n.nodeValue && /\S/.test(n.nodeValue)) {
            range.selectNodeContents(n)
            const rs = range.getClientRects()
            for (let i = 0; i < rs.length; i++) {
                const r = rs[i]
                const left = Math.max(r.left, box.left), right = Math.min(r.right, box.right)
                const top = Math.max(r.top, box.top), bottom = Math.min(r.bottom, box.bottom)
                // a line mostly cut off (past a clamp) isn't seen
                if (right - left > 1 && bottom - top > r.height / 2) {
                    out.push({ left, right, top, bottom, width: right - left, height: bottom - top } as ClientRect)
                }
            }
        }
        n = walk.nextNode()
    }
    return out
}

function pill(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const r = Math.min(h / 2, w / 2)
    c.beginPath()
    c.moveTo(x + r, y)
    c.lineTo(x + w - r, y)
    c.arc(x + w - r, y + r, r, -Math.PI / 2, Math.PI / 2)
    c.lineTo(x + r, y + h)
    c.arc(x + r, y + r, r, Math.PI / 2, Math.PI * 1.5)
    c.closePath()
    c.fill()
}
