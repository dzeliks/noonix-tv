// a few dom helpers (no framework: the oldest tvs run chromium 53)

type Attrs = { [name: string]: string | number | boolean | EventListener | undefined }
type Child = Node | string | null | undefined | false

/** makes an element: h("div.card.lit", {id: "x"}, child, "text") */
export function h(tag: string, attrs?: Attrs | null, ...children: Child[]): HTMLElement {
    const parts = tag.split(".")
    const el = document.createElement(parts[0] || "div")
    if (parts.length > 1) el.className = parts.slice(1).join(" ")
    if (attrs) {
        for (const k in attrs) {
            const v = attrs[k]
            if (v === undefined || v === false) continue
            if (typeof v === "function") el.addEventListener(k.replace(/^on/, ""), v)
            else if (k === "text") el.textContent = String(v)
            else el.setAttribute(k, v === true ? "" : String(v))
        }
    }
    append(el, children)
    return el
}

export function append(el: Element, children: Child[]): void {
    for (let i = 0; i < children.length; i++) {
        const c = children[i]
        if (c === null || c === undefined || c === false) continue
        el.appendChild(typeof c === "string" ? document.createTextNode(c) : c)
    }
}

export function clear(el: Element): void {
    while (el.firstChild) el.removeChild(el.firstChild)
}

/** after the next frame is drawn: lets a style change animate from what was on screen */
export function nextFrame(fn: () => void): void {
    requestAnimationFrame(function () { requestAnimationFrame(fn) })
}
