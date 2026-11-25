// network shares (core shares.rs): smb, webdav and ftp folders as library folders. the tv's engine
// (tv/engine/shares.js) speaks to the server; the app keeps the shares and names their folders and
// files as paths like smb://nas/Media/Movies/x.mkv
import { json } from "./http"
import * as store from "./store"
import * as engine from "./engine"
import { tr } from "../i18n"

export type Kind = "smb" | "dav" | "davs" | "ftp"
export const KINDS: Kind[] = ["smb", "dav", "davs", "ftp"]

export interface Share {
    id: string
    kind: Kind
    host: string
    port: number | null
    user: string
    /** the folder on the server it starts at ("" = the server: smb lists its shares) */
    base: string
    password: string
}

export interface Entry { name: string; dir: boolean; size: number; mtime: number }

/** what the engine says went wrong, as words (the core's own, so they're translated already) */
export class ShareError extends Error {
    constructor(public kind: string, detail: string) {
        super(message(kind) || detail)
        Object.setPrototypeOf(this, ShareError.prototype)
    }
}

function message(kind: string): string {
    switch (kind) {
        case "login": return tr("The name or password isn't right")
        case "noshare": return tr("That share isn't on the server")
        case "notfound": return tr("That folder isn't there")
        case "nolist": return tr("Add the share's name to the address, like nas.local/Media")
        case "notdav": return tr("That doesn't look like a WebDAV address")
        case "unreachable": return tr("Couldn't reach the server")
        case "cert": return tr("The server's certificate isn't valid")
        case "encryption": return tr("The server wants encryption this TV can't do")
        case "noengine": return tr("Network shares need Noonix TV on an LG or Samsung TV")
    }
    return ""
}

export function list(): Share[] { return store.get<Share[]>("shares", []) }
function save(l: Share[]): void { store.set("shares", l) }

function authority(s: { host: string; port: number | null }): string { return s.port ? s.host + ":" + s.port : s.host }

export function root(s: Share): string {
    const base = s.base.replace(/^\/+|\/+$/g, "")
    return s.kind + "://" + authority(s) + (base ? "/" + base : "")
}

export function isShare(path: string): boolean {
    return KINDS.some(function (k) { return path.indexOf(k + "://") === 0 })
}

function split(path: string): { kind: string; auth: string; rest: string } | null {
    const at = path.indexOf("://")
    if (at < 0) return null
    const r = path.slice(at + 3)
    const slash = r.indexOf("/")
    return { kind: path.slice(0, at), auth: slash < 0 ? r : r.slice(0, slash), rest: slash < 0 ? "" : r.slice(slash + 1).replace(/^\/+|\/+$/g, "") }
}

/** a share path as people read it (no login in it) */
export function label(path: string): string {
    const p = split(path)
    if (!p) return path
    const name = p.kind === "smb" ? "SMB" : p.kind === "ftp" ? "FTP" : "WebDAV"
    return name + "  ·  " + p.auth + (p.rest ? "/" + p.rest : "")
}

/** the saved share a path is in (the one whose folder holds it, else any of that server) and the rest */
function at(path: string): { share: Share; rest: string } {
    const p = split(path)
    if (!p) throw new ShareError("", tr("That isn't a network share"))
    const same = list().filter(function (s) { return s.kind === p.kind && authority(s).toLowerCase() === p.auth.toLowerCase() })
    let best: Share | null = null
    same.forEach(function (s) {
        const b = s.base.replace(/^\/+|\/+$/g, "")
        if ((!b || p.rest === b || p.rest.indexOf(b + "/") === 0) && (!best || s.base.length > best.base.length)) best = s
    })
    const share = best || same[0]
    if (!share) throw new ShareError("", tr("That network share isn't saved anymore"))
    return { share: share, rest: p.rest }
}

/** what was typed: "nas.local/Media", "192.168.1.5:2121", "smb://nas/Media", \\nas\Media, a webdav url */
export function parse(kind: Kind, address: string, user: string): Share {
    const a = address.trim()
    let k: string = kind
    let rest = a
    const sep = a.indexOf("://")
    if (sep >= 0) {
        const named = a.slice(0, sep).toLowerCase()
        k = named === "http" || named === "webdav" ? "dav" : named === "https" || named === "webdavs" ? "davs" : named === "cifs" ? "smb" : named
        rest = a.slice(sep + 3)
    }
    rest = rest.replace(/^[\\/]+/, "").replace(/\\/g, "/")
    if (KINDS.indexOf(k as Kind) < 0) throw new Error(tr("Pick SMB, WebDAV or FTP"))
    const slash = rest.indexOf("/")
    let auth = slash < 0 ? rest : rest.slice(0, slash)
    const base = slash < 0 ? "" : rest.slice(slash + 1).replace(/^\/+|\/+$/g, "")
    let userIn = ""
    const atSign = auth.lastIndexOf("@")
    if (atSign >= 0) { userIn = auth.slice(0, atSign).split(":")[0]; auth = auth.slice(atSign + 1) }
    let host = auth
    let port: number | null = null
    const colon = auth.lastIndexOf(":")
    if (colon > 0 && (auth.indexOf(":") === colon || auth.charAt(0) === "[")) {
        host = auth.slice(0, colon)
        port = parseInt(auth.slice(colon + 1), 10)
        if (isNaN(port) || port <= 0 || port > 65535) throw new Error(tr("That port isn't a number"))
    }
    if (!host) throw new Error(tr("Type the server's name or address"))
    if (k === "dav" && port === 443) k = "davs"
    let decoded = base
    try { decoded = decodeURIComponent(base) } catch (e) { /* as typed */ }
    let id = ""
    for (let i = 0; i < 6; i++) id += ("0" + Math.floor(Math.random() * 256).toString(16)).slice(-2)
    return { id: id, kind: k as Kind, host: host, port: port, user: user.trim() || userIn, base: decoded, password: "" }
}

// ---- the engine's calls

function call<T>(what: string, body: object, timeout?: number): Promise<T> {
    if (!engine.onTv()) return Promise.reject(new ShareError("noengine", ""))
    return engine.ensure(engine.LOCAL + "/").then(function () {
        // a text body: no cors preflight on old browsers
        return json({ url: engine.LOCAL + "/shares/" + what, method: "POST", body: body, timeout: timeout || 30, retries: 0 })
    }).then(function (v: any) {
        if (v && v.error) throw new ShareError(v.error, v.detail || v.error)
        return v as T
    })
}

function wire(s: Share): object {
    return { id: s.id, kind: s.kind, host: s.host, port: s.port || 0, user: s.user, password: s.password }
}

function entries(share: Share, rest: string): Promise<Entry[]> {
    return call<{ entries: Entry[] }>("list", { share: wire(share), path: rest }).then(function (v) { return v.entries || [] })
}

/** saves a share once it answers: its first folder's path */
export function add(kind: Kind, address: string, user: string, password: string): Promise<string> {
    let share: Share
    try { share = parse(kind, address, user) } catch (e) { return Promise.reject(e) }
    share.password = password
    return entries(share, share.base).then(function () {
        // the same server and folder again: the new login replaces the old
        const l = list().filter(function (s) {
            return !(s.kind === share.kind && authority(s).toLowerCase() === authority(share).toLowerCase() && s.base === share.base)
        })
        l.push(share)
        save(l)
        return root(share)
    })
}

/** forgets the share a path is in; the library takes its folders out (library.forgetShare) */
export function remove(path: string): Share | null {
    let s: Share
    try { s = at(path).share } catch (e) { return null }
    save(list().filter(function (x) { return x.id !== s.id }))
    call("forget", { share: wire(s) }).catch(function () { /* the engine may be off */ })
    return s
}

export interface Folder {
    path: string
    name: string
    label: string
    /** "" at the share's top */
    parent: string
    videos: number
    folders: { name: string; path: string }[]
}

export const VIDEO = /\.(mkv|mp4|m4v|avi|mov|wmv|webm|ts|m2ts|mpg|mpeg|ogv|flv)$/i

/** a share's folder for the picker */
export function browse(path: string): Promise<Folder> {
    path = path.replace(/\/+$/, "")
    let a: { share: Share; rest: string }
    try { a = at(path) } catch (e) { return Promise.reject(e) }
    return entries(a.share, a.rest).then(function (l) {
        const folders = l.filter(function (e) { return e.dir && e.name.charAt(0) !== "." && e.name.slice(-1) !== "$" })
            .sort(function (x, y) { return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1 })
        const top = path.toLowerCase() === root(a.share).toLowerCase()
        return {
            path: path,
            name: top ? a.share.host : path.split("/").pop() || path,
            label: label(path),
            parent: top ? "" : path.slice(0, path.lastIndexOf("/")),
            videos: l.filter(function (e) { return !e.dir && VIDEO.test(e.name) }).length,
            folders: folders.map(function (e) { return { name: e.name, path: path + "/" + e.name } }),
        }
    })
}

/** the video files under a library folder: (path, size, mtime) */
export function walk(path: string): Promise<{ path: string; size: number; mtime: number }[]> {
    path = path.replace(/\/+$/, "")
    let a: { share: Share; rest: string }
    try { a = at(path) } catch (e) { return Promise.reject(e) }
    const head = path.slice(0, path.length - a.rest.length).replace(/\/+$/, "")
    return call<{ files: { path: string; size: number; mtime: number }[] }>("walk", { share: wire(a.share), path: a.rest }, 300).then(function (v) {
        return (v.files || []).map(function (f) { return { path: head + "/" + f.path, size: f.size, mtime: f.mtime } })
    })
}

/** a file's url on the engine, for the player */
export function playUrl(path: string): Promise<string> {
    let a: { share: Share; rest: string }
    try { a = at(path) } catch (e) { return Promise.reject(e) }
    return call<{ token: string }>("open", { share: wire(a.share), path: a.rest }).then(function (v) {
        return engine.LOCAL + "/shares/file/" + v.token + "/" + encodeURIComponent(path.split("/").pop() || "video")
    })
}
