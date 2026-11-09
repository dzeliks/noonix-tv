// the speed check (core bench.rs, internet part): a few parallel downloads for 6 s, counted after
// the first second (tcp warming up). auto picture quality follows the result (core quality.rs)
import * as store from "./store"

// cloudflare answers any size from the nearest edge; then the public test files of two hosters
const DOWNS = [
    "https://speed.cloudflare.com/__down?bytes=8000000",
    "https://fsn1-speed.hetzner.com/100MB.bin",
    "https://proof.ovh.net/files/100Mb.dat",
]
const FOR = 6000
const WARM = 1000
// each answer held at most 8 mb (a tv keeps a download in memory until it ends)
const CHUNK = 8000000

export interface Result { mbps: number; at: number }

export function last(): Result | null {
    return store.get<Result | null>("speed", null)
}

/** the tallest picture this line carries smoothly (quality.rs levels: 4k wants 50 mbit/s, full hd 12) */
export function fits(mbps: number): number {
    return mbps >= 50 ? 2160 : mbps >= 12 ? 1080 : 720
}

let running: Promise<Result> | null = null

/** onMbps follows along; a run already going is shared */
export function run(onMbps: (m: number) => void): Promise<Result> {
    if (running) return running
    let i = 0
    const next = function (): Promise<number> {
        const url = DOWNS[i++]
        if (!url) return Promise.reject(new Error("couldn't reach the speed test"))
        return measure(url, onMbps).catch(next)
    }
    running = next().then(function (mbps: number): Result {
        const r = { mbps: Math.round(mbps), at: Date.now() }
        store.set("speed", r)
        return r
    })
    const done = function () { running = null }
    running.then(done, done)
    return running
}

function measure(url: string, onMbps: (m: number) => void): Promise<number> {
    return new Promise<number>(function (ok, fail) {
        const start = Date.now()
        let got = 0
        let from = -1
        let fromBytes = 0
        let failed = 0
        const xhrs: XMLHttpRequest[] = []
        const live = function () { return Date.now() - start < FOR }
        const worker = function () {
            if (!live()) return
            const x = new XMLHttpRequest()
            let seen = 0
            x.open("GET", url, true)
            // the hosters' big files: only a piece of one
            if (url.indexOf("cloudflare") < 0) x.setRequestHeader("Range", "bytes=0-" + (CHUNK - 1))
            x.responseType = "arraybuffer"
            x.onprogress = function (e) { got += e.loaded - seen; seen = e.loaded }
            x.onload = function () {
                if (x.status >= 400) { failed++; return }
                worker()
            }
            x.onerror = function () { failed++ }
            x.send()
            xhrs.push(x)
        }
        for (let k = 0; k < 4; k++) worker()
        const timer = setInterval(function () {
            const t = Date.now() - start
            if (from < 0 && t >= WARM) { from = Date.now(); fromBytes = got }
            if (from >= 0 && Date.now() > from) onMbps(Math.round((got - fromBytes) * 8 / ((Date.now() - from) / 1000) / 1e6))
            if (failed >= 4 && got === 0) { stop(); fail(new Error("no data")); return }
            if (t < FOR) return
            stop()
            const bytes = got - fromBytes
            if (bytes <= 0 || from < 0) fail(new Error("no data"))
            else ok(bytes * 8 / ((Date.now() - from) / 1000) / 1e6)
        }, 250)
        function stop(): void {
            clearInterval(timer)
            xhrs.forEach(function (x) { try { x.abort() } catch (e) { /* done */ } })
        }
    })
}
