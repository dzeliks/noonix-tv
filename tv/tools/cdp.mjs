// drives a tv simulator page over the devtools protocol (no screen permission needed)
//   node cdp.mjs <port> shot out.png | key left right ok back 461 ... | eval "js" | reload
// keys: names or raw keyCodes; ok held = "hold:13"
const [port, ...args] = process.argv.slice(2)
const list = await (await fetch(`http://localhost:${port}/json/list`)).json()
const page = list.find((p) => p.type === "page" && !p.url.includes("app.asar") && !p.url.startsWith("devtools")) || list[0]
const ws = new WebSocket(page.webSocketDebuggerUrl)
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j })
let id = 0
const waiting = new Map()
ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id) } }
const send = (method, params = {}) => new Promise((r) => { const i = ++id; waiting.set(i, r); ws.send(JSON.stringify({ id: i, method, params })) })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const names = { left: 37, up: 38, right: 39, down: 40, ok: 13, back: 461, tback: 10009, red: 403, green: 404, yellow: 405, blue: 406, play: 415, pause: 19, stop: 413, rew: 412, ff: 417, playpause: 10252 }
async function key(code, holdMs = 60) {
    const base = { windowsVirtualKeyCode: code, nativeVirtualKeyCode: code, keyCode: code }
    await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...base })
    await sleep(holdMs)
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...base })
    await sleep(140)
}
const cmd = args.shift()
if (cmd === "shot") {
    const r = await send("Page.captureScreenshot", { format: "png" });
    const fs = await import("node:fs"); fs.writeFileSync(args[0], Buffer.from(r.result.data, "base64"))
} else if (cmd === "key") {
    for (const a of args) {
        if (a.startsWith("wait:")) { await sleep(+a.slice(5)); continue }
        const hold = a.startsWith("hold:")
        const k = hold ? a.slice(5) : a
        await key(names[k] ?? +k, hold ? 900 : 60)
    }
} else if (cmd === "reload") {
    await send("Page.reload", { ignoreCache: true })
} else if (cmd === "eval") {
    let r = await send("Runtime.evaluate", { expression: args.join(" "), returnByValue: true, awaitPromise: true })
    // chromium 56 refuses awaitPromise on a plain value
    if (r.error) r = await send("Runtime.evaluate", { expression: args.join(" "), returnByValue: true })
    console.log(JSON.stringify(r.result ? r.result.result.value ?? r.result : r.error))
}
ws.close()
