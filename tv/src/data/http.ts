// http over xhr (fetch has no timeout before chromium 66, and webOS 3 has no fetch at all)

export class HttpError extends Error {
    constructor(public status: number, public url: string, public body: string) {
        super(status ? "http " + status + " for " + redact(url) : "network error for " + redact(url))
        // es5: the prototype chain of a subclassed Error has to be set by hand
        Object.setPrototypeOf(this, HttpError.prototype)
    }
}

export interface Req {
    url: string
    method?: "GET" | "POST" | "DELETE"
    headers?: { [name: string]: string }
    body?: unknown
    /** seconds */
    timeout?: number
    retries?: number
    /** read the body as utf-8 whatever the server says (old engines fall back to latin-1) */
    utf8?: boolean
}

function once(req: Req): Promise<string> {
    return new Promise<string>(function (resolve, reject) {
        const x = new XMLHttpRequest()
        x.open(req.method || "GET", req.url, true)
        x.timeout = (req.timeout || 15) * 1000
        if (req.utf8 && x.overrideMimeType) x.overrideMimeType("text/plain; charset=utf-8")
        const headers = req.headers || {}
        for (const k in headers) x.setRequestHeader(k, headers[k])
        if (req.body !== undefined) x.setRequestHeader("content-type", "application/json")
        x.onload = function () {
            if (x.status >= 200 && x.status < 300) resolve(x.responseText)
            else reject(new HttpError(x.status, req.url, (x.responseText || "").slice(0, 300)))
        }
        x.onerror = x.ontimeout = function () { reject(new HttpError(0, req.url, "")) }
        x.send(req.body !== undefined ? JSON.stringify(req.body) : null)
    })
}

/** sends, retrying network errors and 5xx/429 with a growing wait */
export function send(req: Req): Promise<string> {
    const tries = (req.retries === undefined ? 2 : req.retries) + 1
    let attempt = 0
    const go = function (): Promise<string> {
        attempt++
        return once(req).catch(function (e: HttpError) {
            const again = e.status === 0 || e.status === 429 || e.status >= 500
            if (!again || attempt >= tries) throw e
            return new Promise<string>(function (r) { setTimeout(function () { r(go()) }, 400 * attempt * attempt) })
        })
    }
    return go()
}

export function json<T = any>(req: Req): Promise<T> {
    return send(req).then(function (text) { return text ? parseLenient(text) : null })
}

/** some apis put raw control characters inside strings */
export function parseLenient(text: string): any {
    try {
        return JSON.parse(text)
    } catch (e) {
        let out = ""
        let inStr = false
        let esc = false
        for (let i = 0; i < text.length; i++) {
            let c = text.charAt(i)
            const code = text.charCodeAt(i)
            if (inStr) {
                if (esc) esc = false
                else if (c === "\\") esc = true
                else if (c === "\"") inStr = false
                else if (code < 32) c = " "
            } else if (c === "\"") {
                inStr = true
            }
            out += c
        }
        return JSON.parse(out)
    }
}

/** keys and tokens out of logged urls */
export function redact(s: string): string {
    return s.replace(/(api_key|token|apikey|key)=[^&\s"]+/gi, "$1=…")
}

/** a query string from pairs (URLSearchParams arrived in chromium 49, and webOS 3 is 38) */
export function query(pairs: [string, string | number][]): string {
    return pairs.map(function (p) { return encodeURIComponent(p[0]) + "=" + encodeURIComponent(String(p[1])) }).join("&")
}
