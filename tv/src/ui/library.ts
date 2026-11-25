// the library in settings (qml SourcesFlow's library lines and FolderPicker): folders on network shares,
// a scan, and adding a share
import { tr, trn } from "../i18n"
import { Action } from "../keys"
import { App, Screen } from "./app"
import { inputScreen } from "./input"
import { listScreen, Row } from "./settings"
import * as library from "../data/library"
import * as shares from "../data/shares"

const none = function () { /* nothing */ }

export function librarySummary(): string {
    if (!library.on()) return tr("Off")
    if (library.isScanning()) return "…"
    const n = library.status().files
    return library.folders().length ? trn("%n video(s)", n) : tr("None")
}

export function libraryScreen(app: App): Screen {
    let gone = false
    const screen = listScreen(tr("Library"), function (): Row[] {
        const on = library.on()
        const folders = library.folders()
        const st = library.status()
        const rows: Row[] = [{
            label: tr("Use the library"), value: function () { return on ? tr("On") : tr("Off") },
            hint: !on ? tr("Off: only your addons' sources play")
                : library.isScanning() ? tr("Looking through your folders…")
                    : !folders.length ? tr("Movies and shows on a NAS or another computer: add the folder they're in")
                        : trn("%n video(s) found", st.files) + (st.files - st.matched ? "  ·  " + trn("%n not recognized", st.files - st.matched) : ""),
            ok: function () { library.setOn(!on) },
        }]
        if (!on) return rows
        folders.forEach(function (f) {
            const n = library.folderFiles(f)
            rows.push({
                label: shares.label(f), value: function () { return tr("Remove") },
                hint: trn("%n video(s)  ·  OK takes it out of the library, the files stay", n),
                ok: function () {
                    app.menu(shares.label(f), [
                        { label: tr("Remove"), run: function () { library.removeFolder(f); app.toast(tr("Removed %1", f.split("/").pop() || f)) } },
                        { label: tr("Cancel"), run: none },
                    ])
                },
            })
        })
        rows.push({
            label: tr("Add a folder"), value: function () { return "+" },
            hint: tr("Movies and shows, named the usual way: Show/Season 1/Show S01E02.mkv, Movie (2010).mkv"),
            ok: function () { app.push(pickerScreen(app, ""), false) },
        })
        if (folders.length) rows.push({
            label: tr("Look for new videos"), value: function () { return library.isScanning() ? "…" : tr("Scan") },
            hint: st.unmatchedNames.length ? tr("Not recognized: %1", st.unmatchedNames.join(", ")) : tr("Runs by itself every time Noonix TV opens"),
            ok: function () {
                if (library.isScanning()) return
                library.scan().then(function () {
                    if (!gone) app.toast(trn("%n video(s) found", library.status().files))
                }, function (e) { if (!gone) app.toast(String(e && e.message || e)) })
            },
        })
        return rows
    })
    const off = library.onChange(function () { if (!gone) screen.redraw() })
    return {
        el: screen.el,
        action: function (a: Action) { return screen.action(a) },
        shown: function () { screen.redraw() },
        closed: function () { gone = true; off() },
    }
}

function kindName(k: string): string { return k === "smb" ? "SMB" : k === "ftp" ? "FTP" : "WebDAV" }

/** where the folders are: the saved shares, then a share's folders (ok opens one, back goes up) */
function pickerScreen(app: App, start: string): Screen {
    let path = start
    let view: shares.Folder | null = null
    let loading = false
    let failed = ""
    let gone = false
    let asked = 0

    const screen = listScreen(tr("Add a folder"), function (): Row[] {
        if (!path) {
            const rows: Row[] = shares.list().map(function (s): Row {
                const r = shares.root(s)
                return { label: s.host + (s.base ? "/" + s.base : ""), value: function () { return "›" },
                    hint: shares.label(r) + (s.user ? "  ·  " + s.user : ""), ok: function () { go(r) } }
            })
            rows.push({ label: tr("Add a network share"), value: function () { return "+" },
                hint: tr("SMB, WebDAV or FTP: a NAS or another computer"), ok: function () { addShare(app, go) } })
            return rows
        }
        if (loading) return [{ label: tr("Opening…"), value: function () { return "" }, ok: none }]
        const rows: Row[] = []
        if (failed || !view) {
            rows.push({ label: failed || tr("Couldn't open that folder"), value: function () { return "" }, ok: none })
        } else {
            const v = view
            rows.push({ label: tr("Use this folder"), value: function () { return tr("Add") },
                hint: v.videos ? trn("%n video(s) right here, and what's in the folders inside", v.videos) : tr("With what's in the folders inside"),
                ok: function () {
                    library.addFolder(v.path)
                    app.toast(tr("Added %1", v.name))
                    app.pop()
                    library.scan().catch(none)
                } })
            v.folders.forEach(function (f) {
                rows.push({ label: f.name, value: function () { return "›" }, ok: function () { go(f.path) } })
            })
        }
        rows.push({ label: tr("Up a folder"), value: function () { return "‹" },
            hint: view && view.parent ? shares.label(view.parent) : tr("Back to where your videos may be"), ok: up })
        if (view && !view.parent) rows.push({ label: tr("Forget this share"), value: function () { return "" },
            hint: tr("Its folders leave the library too"), ok: function () {
                const p = path
                app.menu(tr("Forget this share"), [
                    { label: tr("Forget this share"), run: function () { library.forgetShare(p); go("") } },
                    { label: tr("Cancel"), run: none },
                ])
            } })
        return rows
    })

    function go(p: string): void {
        path = p
        view = null
        failed = ""
        if (!p) { screen.top(tr("Add a folder")); return }
        loading = true
        const mine = ++asked
        screen.top(p.split("/").pop() || p)
        shares.browse(p).then(function (v) {
            if (gone || mine !== asked) return
            view = v
            loading = false
            screen.top(v.name)
        }, function (e) {
            if (gone || mine !== asked) return
            loading = false
            failed = String(e && e.message || e)
            screen.top()
        })
    }

    function up(): void {
        if (!path) { app.pop(); return }
        go(view && view.parent ? view.parent : "")
    }

    if (start) go(start)
    return {
        el: screen.el,
        action: function (a: Action) {
            if (a === "back") { up(); return true }
            return screen.action(a)
        },
        shown: function () { screen.redraw() },
        closed: function () { gone = true },
    }
}

/** the qml FolderPicker's flow: kind, address, user, password; checked before it's kept */
function addShare(app: App, then: (root: string) => void): void {
    const hintFor = function (k: string): string {
        if (k === "smb") return tr("The computer or NAS and its share, like 192.168.1.20/Media or nas.local/Videos")
        if (k === "dav") return tr("Like 192.168.1.20:8080/dav, or the whole address with https:// for a secure one")
        return tr("Like 192.168.1.20 or nas.local:2121")
    }
    const ask = function (kind: shares.Kind): void {
        app.push(inputScreen(tr("Server address"), hintFor(kind), "", function (address) {
            if (!address) return
            app.push(inputScreen(tr("User name"), tr("Leave it empty for a guest login"), "", function (user) {
                app.push(inputScreen(tr("Password"), user ? kindName(kind) + "  ·  " + user : tr("Leave it empty for a guest login"), "", function (password) {
                    app.toast(tr("Checking %1…", address))
                    shares.add(kind, address, user, password).then(function (root) {
                        app.toast(tr("Added %1", shares.label(root)))
                        then(root)
                    }, function (e) {
                        app.toast(String(e && e.message || e) || tr("That didn't work"))
                    })
                }, app.pop), false)
            }, app.pop), false)
        }, app.pop), false)
    }
    app.menu(tr("What kind of server is it?"), [
        { label: "SMB  ·  " + tr("Windows and macOS sharing, most NAS boxes"), run: function () { ask("smb") } },
        { label: "WebDAV  ·  " + tr("Nextcloud, many NAS boxes and file apps"), run: function () { ask("dav") } },
        { label: "FTP  ·  " + tr("An FTP server"), run: function () { ask("ftp") } },
    ])
}
