#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// the library and the user's own sources (qml SourcesFlow), for setup's "your videos" step and
/// settings › sources and accounts: the lines, what ok on them does, and the sheets and pickers
/// they open. debrid keys and torrents only show up once something the user added asks for them
@MainActor @Observable
final class SourcesFlow {
    typealias Line = SettingsModel.Line
    var lib: [String: Any] = [:]
    var addons: [[String: Any]] = []
    var exts: [[String: Any]] = []
    var acc: [String: Any] = [:]
    /// the row of what was just added: the page focuses it
    var focusAct = ""
    /// the folder whose remove waits for the second press
    var removing = ""
    @ObservationIgnored private var removeReset: Task<Void, Never>?
    /// after an install: the key to ask for once torrents are answered
    @ObservationIgnored private var keyAfter: String?
    /// the page reloads its own data (setup / settings)
    @ObservationIgnored var changed: () -> Void = {}

    private func json(_ m: String, _ a: [String: Any] = [:]) async -> Any? {
        guard let d = try? await Core.shared.raw(m, a) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// a call that says what went wrong, in the core's words
    private func answer(_ m: String, _ a: [String: Any]) async -> (Any?, String?) {
        do {
            let d = try await Core.shared.raw(m, a)
            return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]), nil)
        } catch let e as CoreError {
            return (nil, Lc(e.message))
        } catch {
            return (nil, nil)
        }
    }

    func load() async {
        async let l = json("library.status")
        async let a = json("addons.list")
        async let e = json("extensions.list")
        async let s = json("setup.accounts")
        lib = await l as? [String: Any] ?? lib
        addons = await a as? [[String: Any]] ?? addons
        exts = await e as? [[String: Any]] ?? exts
        acc = await s as? [String: Any] ?? acc
    }

    /// the library's own push (a scan finished)
    func pushed(_ d: Data) {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { lib = o }
    }

    var hasSources: Bool { !(lib["folders"] as? [[String: Any]] ?? []).isEmpty || !addons.isEmpty }

    // ---- on this mac, then the addons and extensions
    var lines: [Line] {
        var out: [Line] = []
        let on = lib["on"] as? Bool != false, folders = lib["folders"] as? [[String: Any]] ?? []
        let files = (lib["files"] as? NSNumber)?.intValue ?? 0, unmatched = (lib["unmatched"] as? NSNumber)?.intValue ?? 0
        let scanning = lib["scanning"] as? Bool == true
        out.append(Line(label: L("On this Mac"), header: true))
        out.append(Line(label: L("Use the library"),
                        detail: !on ? L("Off: only the sources below play")
                            : scanning ? L("Looking through your folders…")
                            : folders.isEmpty ? (Platform.ios ? L("Copy them into the Files app › Noonix TV") : L("Pick the folders your movies and shows are in"))
                            : Ln("%n video(s) found", files) + (unmatched > 0 ? "  ·  " + Ln("%n not recognized", unmatched) : ""),
                        checkable: true, checked: on, act: "lib:on"))
        if on {
            for f in folders {
                let path = f["path"] as? String ?? "", asked = removing == path
                out.append(Line(label: f["label"] as? String ?? path,
                                detail: asked ? L("Takes it out of the library, the files stay")
                                    : (Theme.touch ? Ln("%n video(s)  ·  tap to take it out of the library, the files stay", (f["files"] as? NSNumber)?.intValue ?? 0)
                                       : Ln("%n video(s)  ·  OK takes it out of the library, the files stay", (f["files"] as? NSNumber)?.intValue ?? 0)),
                                value: asked ? L("Press Again to Remove") : L("Remove"), act: "lib:remove:" + path))
            }
            out.append(Line(label: L("Add a folder"), detail: L("Movies and shows, named the usual way: Show/Season 1/Show S01E02.mkv, Movie (2010).mkv"), value: "+", act: "lib:add"))
            if !folders.isEmpty {
                let names = lib["unmatchedNames"] as? [String] ?? []
                out.append(Line(label: L("Look for new videos"),
                                detail: names.isEmpty ? L("Runs by itself every time Noonix TV opens") : L("Not recognized: %1", names.joined(separator: ", ")),
                                value: scanning ? "…" : L("Scan"), act: "lib:scan"))
            }
        }
        out.append(Line(label: L("Addons and extensions"), header: true))
        for e in exts {
            let missing = (e["missingKeys"] as? [[String: Any]])?.first
            let n = (e["addons"] as? NSNumber)?.intValue ?? 0
            out.append(Line(label: e["name"] as? String ?? "",
                            detail: missing.map { L("Needs your %1 key", $0["name"] as? String ?? "") }
                                ?? L("Extension") + "  ·  " + Ln("%n source(s)", n) + (e["torrents"] as? Bool == true ? "  ·  " + L("torrents") : ""),
                            value: e["enabled"] as? Bool == true ? "›" : L("Off"), act: "ext:" + (e["id"] as? String ?? "")))
        }
        for a in addons where (a["extension"] as? String ?? "").isEmpty {
            let id = (a["id"] as? NSNumber)?.intValue ?? 0
            out.append(Line(label: UILang.addonName(a["name"] as? String ?? ""),
                            detail: (a["address"] as? String ?? "") + (a["formatting"] as? String == "unsupported" ? "  ·  " + L("Unsupported formatting") : "")
                                + (a["lastError"] as? String != nil ? "  ·  " + L("Didn't answer last time") : ""),
                            value: a["enabled"] as? Bool == true ? "›" : L("Off"), act: "addon:\(id)"))
        }
        out.append(Line(label: L("Add an addon or extension"), detail: L("Its address: a Stremio addon (…/manifest.json) or a Noonix TV extension. Optional"), value: "+", act: "src:url"))
        out.append(Line(label: L("Open an extension file"), detail: L("A .noonix file on this Mac"), value: "+", act: "src:file"))
        return out
    }

    /// the debrid services an extension asked for (or with a key from before)
    var debridLines: [Line] {
        let ds = (acc["debrids"] as? [[String: Any]] ?? []).filter { $0["wanted"] as? Bool == true || $0["set"] as? Bool == true }
        guard !ds.isEmpty else { return [] }
        let site = ["torbox": "torbox.app › Settings", "realdebrid": "real-debrid.com/apitoken", "alldebrid": "alldebrid.com › Account › API keys"]
        var out = [Line(label: L("Debrid services"), header: true)]
        for d in ds {
            let set = d["set"] as? Bool == true, id = d["id"] as? String ?? "", name = d["name"] as? String ?? id
            out.append(Line(label: name,
                            detail: set ? (d["preview"] as? String ?? "") + (d["wanted"] as? Bool == true ? "" : "  ·  " + L("Nothing you added uses it now"))
                                : L("An extension of yours needs your key from %1", site[id] ?? name),
                            value: set ? L("Change") : L("Add"), act: "cred:" + (d["key"] as? String ?? "")))
        }
        out.append(Line(label: L("What's this?"), detail: L("Debrid services in a few lines"), value: "?", act: "help:debrid"))
        return out
    }

    /// torrents: once a source of the user's can answer with them, or they were decided before
    var torrentLines: [Line] {
        let t = acc["torrents"] as? [String: Any] ?? [:]
        let allowed = t["allowed"] as? Bool
        guard t["wanted"] as? Bool == true || allowed != nil else { return [] }
        return [
            Line(label: L("Torrents"), header: true),
            Line(label: L("Allow torrents"), detail: L("Download only, at your own risk. While it's off, torrent sources stay hidden"),
                 checkable: true, checked: allowed == true, act: "torrents"),
            Line(label: L("What's this?"), detail: L("Torrents in a few lines"), value: "?", act: "help:torrent"),
        ]
    }

    private func reload() {
        Task { await load(); changed() }
    }

    // ---- ok on one of the lines above; false = not ours
    func run(_ a: String, app: AppModel) -> Bool {
        if a == "lib:on" {
            Task { if let d = await json("library.setOn", ["on": lib["on"] as? Bool == false]) as? [String: Any] { lib = d }; changed() }
        } else if a == "lib:add" {
            pickFolder(app: app)
        } else if a.hasPrefix("lib:remove:") {
            // one press asks, the second takes it out
            let path = String(a.dropFirst(11))
            removeReset?.cancel()
            guard removing == path else {
                removing = path
                removeReset = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { removing = "" } }
                return true
            }
            removing = ""
            Task { if let d = await json("library.removeFolder", ["path": path]) as? [String: Any] { lib = d }; changed() }
        } else if a == "lib:scan" {
            lib["scanning"] = true
            Task { if let d = await json("library.scan") as? [String: Any] { lib = d }; changed() }
        } else if a.hasPrefix("ext:") {
            if let e = exts.first(where: { $0["id"] as? String == String(a.dropFirst(4)) }) { sheet(e, "extension", app: app) }
        } else if a.hasPrefix("addon:") {
            if let ad = addons.first(where: { "\((($0["id"] as? NSNumber)?.intValue ?? 0))" == String(a.dropFirst(6)) }) { sheet(ad, "addon", app: app) }
        } else if a == "src:url" {
            var pending: [String: Any]?
            app.entry.open(title: L("Addon or extension address"), hint: L("A Stremio addon's address (…/manifest.json) or a Noonix TV extension's"), placeholder: "https://…",
                           check: { [weak self] v in
                               guard let self else { return (false, "") }
                               let (d, err) = await answer("extensions.preview", ["url": v])
                               guard let d = d as? [String: Any] else { return (false, err ?? L("That address didn't answer")) }
                               pending = d
                               return (true, d["name"] as? String ?? "")
                           },
                           after: { [weak self] _ in if let p = pending { self?.sheet(p, "preview", app: app) } })
        } else if a == "src:file" {
            pickFile(app: app)
        } else if a == "help:debrid" {
            app.help = SourcesHelpModel(topic: "debrid")
        } else if a == "help:torrent" {
            app.help = SourcesHelpModel(topic: "torrent")
        } else if a == "torrents" {
            // yes goes through the sheet that says what it means; no right away
            if (acc["torrents"] as? [String: Any])?["allowed"] as? Bool == true { setTorrents(false) } else { ask(app: app) }
        } else {
            return false
        }
        return true
    }

    func setTorrents(_ on: Bool) {
        Task { if let d = await json("setup.torrents", ["on": on]) as? [String: Any] { acc = d }; changed() }
    }

    private func ask(app: AppModel) {
        let h = SourcesHelpModel(topic: "torrent", asking: true)
        h.answered = { [weak self, weak app] yes in
            guard let self else { return }
            setTorrents(yes)
            if let k = keyAfter, let app {
                keyAfter = nil
                app.enterCredential(k) { [weak self] in self?.reload() }
            }
        }
        app.help = h
    }

    private func sheet(_ d: [String: Any], _ mode: String, app: AppModel) {
        let s = ExtensionSheetModel(info: d, mode: mode)
        s.installed = { [weak self, weak app] r in if let app { self?.installed(r, app: app) } }
        s.changed = { [weak self] in self?.reload() }
        s.wantKey = { [weak self, weak app] k in app?.enterCredential(k) { [weak self] in self?.reload() } }
        app.extSheet = s
    }

    /// what to ask after an install: torrents first, then a missing key
    private func installed(_ r: [String: Any], app: AppModel) {
        app.toast(L("Added %1", r["name"] as? String ?? ""))
        focusAct = r["kind"] as? String == "addon" ? "addon:\(r["id"] ?? "")" : "ext:\(r["id"] ?? "")"
        reload()
        let key = (r["needKeys"] as? [[String: Any]])?.first?["key"] as? String
        if r["torrents"] as? Bool == true, (acc["torrents"] as? [String: Any])?["allowed"] as? Bool != true {
            keyAfter = key
            ask(app: app)
        } else if let key {
            app.enterCredential(key) { [weak self] in self?.reload() }
        }
    }

    // ---- library folders: our own picker (the remote can't drive the system's panel)
    private func pickFolder(app: AppModel) {
        let p = FolderPickerModel()
        p.picked = { [weak self, weak app] path in
            guard let self, let app else { return }
            Task {
                let (d, err) = await self.answer("library.addFolder", ["path": path])
                if let d = d as? [String: Any] { self.lib = d } else { app.toast(err ?? L("Couldn't add that folder")) }
                self.changed()
            }
        }
        app.folderPicker = p
        p.go("", app: app)
    }

    // ---- an extension file: the same picker, listing the files (the system's panel wants a mouse)
    private func pickFile(app: AppModel) {
        let p = FolderPickerModel()
        p.files = ["noonix", "json"]
        p.caption = L("Open an extension file")
        p.picked = { [weak self, weak app] path in
            guard let self, let app else { return }
            Task {
                let (d, err) = await self.answer("extensions.preview", ["path": path])
                if let d = d as? [String: Any] { self.sheet(d, "preview", app: app) } else { app.toast(err ?? L("Couldn't read that file")) }
            }
        }
        app.folderPicker = p
        p.go("", app: app)
    }
}

/// an addon or extension (qml ExtensionSheet): before it's added, exactly what it brings (addresses,
/// keys it sends where, torrents, release patterns) with add / cancel; once it's in, the same lines
/// with on / off, update and remove
@MainActor @Observable
final class ExtensionSheetModel {
    var info: [String: Any]
    /// preview | extension | addon
    var mode: String
    var busy = false
    var confirmRemove = false
    var button = 0
    @ObservationIgnored private var removeTask: Task<Void, Never>?
    @ObservationIgnored var installed: ([String: Any]) -> Void = { _ in }
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var wantKey: (String) -> Void = { _ in }

    init(info: [String: Any], mode: String) {
        self.info = info
        self.mode = mode
        button = mode == "preview" ? 0 : 1
    }

    var isAddon: Bool { mode == "addon" || (mode == "preview" && info["kind"] as? String == "addon") }

    var lines: [String] {
        let d = info
        var out: [String] = []
        if let desc = d["description"] as? String, !desc.isEmpty { out.append(desc) }
        if isAddon {
            let host = mode == "addon" ? d["address"] as? String : (d["hosts"] as? [String])?.first
            out.append(L("A Stremio addon at %1", host ?? "?"))
            let names = ["stream": L("videos"), "catalog": L("catalogs"), "meta": L("details"), "subtitles": L("subtitles")]
            let res = (d["resources"] as? [String] ?? []).map { names[$0] ?? $0 }
            if !res.isEmpty { out.append(L("Offers %1", res.joined(separator: ", "))) }
            if mode == "addon", d["lastError"] as? String != nil { out.append(L("Didn't answer last time")) }
            if mode == "addon", d["formatting"] as? String == "unsupported" { out.append(L("Its source names are hard to read: badges and the auto pick may be off")) }
            return out
        }
        let n = ((mode == "preview" ? d["addons"] : d["listed"]) as? NSNumber)?.intValue ?? 0
        let hosts = (d["hosts"] as? [String] ?? []).joined(separator: ", ")
        if n > 0 { out.append(Ln("Adds %n source(s) from %1", n).replacingOccurrences(of: "%1", with: hosts.isEmpty ? d["source"] as? String ?? "" : hosts)) }
        for k in d["keys"] as? [[String: Any]] ?? [] {
            let name = k["name"] as? String ?? "", to = (k["hosts"] as? [String] ?? []).joined(separator: ", ")
            let set = k["set"] as? Bool == true
            if !set && k["bundled"] as? Bool == true && mode == "preview" {
                out.append(L("Brings a %1 key, sent only to %2", name, to))
            } else {
                out.append(L("Sends your %1 key to %2", name, to) + (set || mode != "preview" ? "" : "  ·  " + L("you'll add the key next")))
            }
        }
        if d["torrents"] as? Bool == true { out.append(L("Its sources are torrents: they play only once you allow torrents")) }
        let p = d["patterns"] as? [String: Any] ?? [:]
        if let pr = p["preferred"] as? [String], !pr.isEmpty { out.append(L("Prefers releases with %1", pr.joined(separator: ", "))) }
        if let ex = p["excluded"] as? [String], !ex.isEmpty { out.append(L("Hides releases with %1", ex.joined(separator: ", "))) }
        let v = d["version"] as? String ?? "", a = d["author"] as? String ?? ""
        let by = (v.isEmpty ? "" : L("Version %1", v)) + (a.isEmpty ? "" : (v.isEmpty ? "" : "  ·  ") + L("by %1", a))
        if !by.isEmpty { out.append(by) }
        if mode == "preview", d["installed"] as? Bool == true { out.append(L("Replaces the version you have (%1)", d["installedVersion"] as? String ?? "?")) }
        if mode == "extension", let m = (d["missingKeys"] as? [[String: Any]])?.first { out.append(L("Not working yet: it needs your %1 key", m["name"] as? String ?? "")) }
        if mode == "extension", let s = d["source"] as? String, !s.isEmpty { out.append(s == "file" ? L("Added from a file") : L("From %1", s)) }
        return out
    }

    var buttons: [(text: String, act: String, primary: Bool)] {
        if mode == "preview" {
            return [(info["installed"] as? Bool == true ? L("Update") : L("Add"), "install", true), (L("Cancel"), "close", false)]
        }
        var out: [(text: String, act: String, primary: Bool)] = [(L("Back"), "close", false)]
        if mode == "extension", !(info["missingKeys"] as? [[String: Any]] ?? []).isEmpty { out.append((L("Add Key"), "key", true)) }
        out.append((info["enabled"] as? Bool == true ? L("Turn Off") : L("Turn On"), "toggle", out.count == 1))
        if mode == "extension", info["updatable"] as? Bool == true { out.append((L("Update"), "update", false)) }
        out.append((confirmRemove ? L("Press Again to Remove") : L("Remove"), "remove", false))
        return out
    }

    private func call(_ m: String, _ a: [String: Any]) async -> (Any?, String?) {
        do {
            let d = try await Core.shared.raw(m, a)
            return (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]), nil)
        } catch let e as CoreError {
            return (nil, Lc(e.message))
        } catch {
            return (nil, nil)
        }
    }

    func act(_ a: String, app: AppModel) {
        guard !busy else { return }
        let d = info
        func close() { app.extSheet = nil }
        switch a {
        case "close":
            close()
        case "key":
            close()
            if let k = (d["missingKeys"] as? [[String: Any]])?.first?["key"] as? String { wantKey(k) }
        case "install":
            busy = true
            Task {
                let (r, err) = await call("extensions.install", ["token": d["token"] as? String ?? ""])
                busy = false
                guard let r = r as? [String: Any] else { app.toast(err ?? L("Couldn't add it")); return }
                close()
                installed(r)
            }
        case "toggle":
            busy = true
            let on = d["enabled"] as? Bool != true
            Task {
                if mode == "addon" { _ = await call("addons.enable", ["id": d["id"] ?? 0, "on": on]) } else { _ = await call("extensions.enable", ["id": d["id"] ?? "", "on": on]) }
                busy = false
                close()
                changed()
            }
        case "update":
            busy = true
            Task {
                let (r, err) = await call("extensions.update", ["id": d["id"] ?? ""])
                busy = false
                guard let r = r as? [String: Any] else { app.toast(err ?? L("Couldn't reach it")); return }
                info = r
                mode = "preview"
                button = 0
            }
        case "remove":
            if !confirmRemove {
                confirmRemove = true
                removeTask?.cancel()
                removeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { self?.confirmRemove = false }
                }
                return
            }
            busy = true
            Task {
                if mode == "addon" { _ = await call("addons.remove", ["id": d["id"] ?? 0]) } else { _ = await call("extensions.remove", ["id": d["id"] ?? ""]) }
                busy = false
                close()
                changed()
            }
        default:
            break
        }
    }

    func key(_ k: Key, app: AppModel) {
        let b = buttons
        switch k {
        case .left: button = max(0, button - 1)
        case .right: button = min(b.count - 1, button + 1)
        case .ok: if let x = b[safe: button] { act(x.act, app: app) }
        case .back: app.extSheet = nil
        default: break
        }
    }
}

struct ExtensionSheetView: View {
    @Environment(AppModel.self) private var app
    let model: ExtensionSheetModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        let lines = model.lines
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.6) }
                .ignoresSafeArea()
                .onTapGesture { app.extSheet = nil }
            VStack(alignment: .leading, spacing: 30 * u) {
                if model.mode == "preview" {
                    Text(model.isAddon ? L("Add this addon?") : L("Add this extension?")).font(Theme.text(26 * u, .medium)).foregroundStyle(Theme.fg3)
                }
                Text(UILang.addonName(model.info["name"] as? String ?? "")).font(Theme.display(60 * u, .bold)).foregroundStyle(Theme.fg).lineLimit(1)
                VStack(alignment: .leading, spacing: 14 * u) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(Theme.text(29 * u))
                            .foregroundStyle(i == 0 && !(model.info["description"] as? String ?? "").isEmpty ? Theme.fg : Theme.fg2)
                            .lineSpacing(3 * u).lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.mode == "preview" {
                    Text(L("Noonix TV doesn't check what an addon or extension offers. Only add ones you trust, for videos you have the right to watch."))
                        .font(Theme.text(24 * u)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 24 * u) {
                    ForEach(Array(model.buttons.enumerated()), id: \.offset) { i, b in
                        GlassButton(text: b.text, icon: b.act == "close" && model.mode != "preview" ? "arrow.left" : nil, primary: b.primary,
                                    focused: model.button == i, u: u, flat: true)
                            .opacity(model.busy ? 0.5 : 1)
                            .contentShape(.capsule)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.button = i } }
                            .onTapGesture { model.act(b.act, app: app) }
                    }
                }
                .padding(.top, 4 * u)
            }
            .frame(width: 1240 * u, alignment: .leading)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}
