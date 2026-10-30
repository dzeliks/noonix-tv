import AppKit
import ServiceManagement
import SwiftUI

/// settings like the tv (qml Settings): sections on the left, the section's lines on the right
@MainActor @Observable
final class SettingsModel {
    struct Line: Identifiable {
        var id: String { act + "|" + label }
        var label: String
        var detail = ""
        var value = ""
        var checkable = false
        var checked = false
        var badge = ""
        var header = false
        var act = ""
        /// "brand": the app's own card at the top of about
        var kind = ""
    }

    static var sections: [(id: String, name: String)] { [("sources", L("Sources")), ("accounts", L("Accounts")), ("profiles", L("Profiles")),
        ("audio", L("Audio")), ("subtitles", L("Subtitles")), ("playback", L("Playback")), ("controls", L("Controls")), ("about", L("About"))] }

    /// the section the menu is on, and the one the page shows: the page follows once the menu
    /// rests, out and in (running down the menu doesn't rebuild it per step)
    var section = 0 { didSet { if section != oldValue, !Input.pointing { swapLater() } } }   // under the mouse: on the click
    /// the languages' order as the section opened (the chosen ones first): a line doesn't jump away
    /// from the focus while it's ticked
    @ObservationIgnored private var langSnap: [String: [String]]?
    private func snap(_ p: [String: Any]) -> [String: [String]] {
        if langSnap == nil { langSnap = ["languages": p["languages"] as? [String] ?? [], "subtitles": p["subtitles"] as? [String] ?? []] }
        return langSnap!
    }
    var shown = 0
    @ObservationIgnored private var swapTask: Task<Void, Never>?
    var inPage = false
    var index = 0
    var prefs: [String: Any]?
    var langOptions: [String: Any]?
    var quality: [String: Any]?
    var appSettings: [String: Any] = [:]
    /// what the screen was found to show (display.state)
    var screen: [String: Any] = [:]
    var accounts: [String: Any] = [:]
    var template: [String: Any]?
    var update: [String: Any]?
    var version = ""
    var benchBusy = false
    /// the user's own release patterns (preferred, excluded)
    var patterns: [String: Any]?
    var updateState = ""
    /// the page fades out and in when the section changes (qml swap)
    var pageOpacity: Double = 1
    /// bumped when the login item changes (its state lives in the system, not here)
    var loginTick = 0

    private func json(_ m: String, _ a: [String: Any] = [:]) async -> Any? {
        guard let d = try? await Core.shared.raw(m, a) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    func load(app: AppModel? = nil) async {
        if let flow = (app ?? AppModel.current)?.flow {
            flow.changed = { [weak self] in Task { await self?.load() } }
            await flow.load()
        }
        async let pt = json("patterns.get")
        async let p = json("sources.prefs")
        async let l = json("languages.options")
        async let q = json("quality.options")
        async let st = json("settings.app")
        async let acc = json("setup.accounts")
        async let t = json("addons.formatter")
        async let v = json("ping")
        async let ds = json("display.state")
        patterns = await pt as? [String: Any] ?? patterns
        prefs = await p as? [String: Any] ?? prefs
        langOptions = await l as? [String: Any] ?? langOptions
        quality = await q as? [String: Any] ?? quality
        appSettings = await st as? [String: Any] ?? appSettings
        accounts = await acc as? [String: Any] ?? accounts
        template = await t as? [String: Any] ?? template
        version = (await v as? [String: Any])?["version"] as? String ?? version
        screen = await ds as? [String: Any] ?? screen
        if update == nil { update = await json("update.check", ["auto": true]) as? [String: Any] }
    }

    private func on(_ k: String) -> Bool { appSettings[k] as? Bool != false }

    private func swapLater() {
        swapTask?.cancel()
        swapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled, shown != section else { return }
            withAnimation(.easeIn(duration: 0.09)) { self.pageOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            showNow()
            withAnimation(.easeOut(duration: 0.18)) { self.pageOpacity = 1 }
        }
    }

    /// the page on the menu's section at once (going into it, a fresh visit)
    func showNow() {
        if shown != section { shown = section; index = 0; langSnap = nil }
        pageOpacity = 1
    }

    /// picture quality levels as lines (qml Theme.qualityLines): the recommended one says so, the
    /// ones above it say why they may not play well here; setup shows the recommended one checked
    /// until something is picked
    static func qualityLines(_ q: [String: Any]?, setup: Bool) -> [Line] {
        guard let q, let levels = q["levels"] as? [[String: Any]] else { return [] }
        let names = ["light": L("Light"), "hd": L("Full HD"), "4k": L("4K"), "max": L("Maximum")]
        let about = ["light": L("Up to 1080p in smaller files. Smooth even on slow internet"), "hd": L("1080p at full quality"),
                     "4k": L("4K and HDR, without the biggest untouched copies"), "max": L("Everything, up to untouched copies of 60 GB and more")]
        let rec = q["recommended"] as? String
        let cur = setup && q["chosen"] as? Bool != true ? rec : q["current"] as? String
        let recIndex = levels.firstIndex { $0["id"] as? String == rec } ?? 0
        return levels.enumerated().map { i, l in
            let id = l["id"] as? String ?? ""
            let warn = i <= recIndex ? ""
                : l["netOk"] as? Bool == false ? L("May stutter: wants about %1 Mbit/s, this connection has %2", "\(l["needMbps"] ?? "?")", "\(q["mbps"] ?? "?")")
                : l["deviceOk"] as? Bool == false ? L("May be too much for this Mac") : L("Not measured yet: may stutter here")
            return Line(label: id == rec ? L("%1 (Recommended)", names[id] ?? id) : names[id] ?? id,
                        detail: (about[id] ?? "") + (warn.isEmpty ? "" : "  ·  " + warn), checkable: true, checked: id == cur, act: "quality:" + id)
        }
    }

    func lines(app: AppModel) -> [Line] {
        var out: [Line] = []
        switch Self.sections[shown].id {
        case "sources":
            out = app.flow.lines + app.flow.torrentLines
            out.append(Line(label: L("Release patterns"), header: true))
            let pr = patterns?["preferred"] as? [String] ?? [], ex = patterns?["excluded"] as? [String] ?? []
            out.append(Line(label: L("Prefer"), detail: pr.isEmpty ? L("None. Words in a release name you like, best first, like REMUX or a language tag") : pr.joined(separator: ", "),
                            value: "›", act: "patterns:preferred"))
            out.append(Line(label: L("Hide"), detail: ex.isEmpty ? L("None. Releases with these words never show") : ex.joined(separator: ", "),
                            value: "›", act: "patterns:excluded"))
            out.append(Line(label: L("Advanced"), header: true))
            out.append(Line(label: L("Noonix formatter for AIOStreams"), detail: L("If you run your own AIOStreams: paste it into its Formatter › Custom when a source says Unsupported formatting"),
                            value: L("Copy"), act: "copy-template"))
            if let p = prefs {
                out.append(Line(label: L("Show sources that need downloading"), checkable: true, checked: p["showUncached"] as? Bool == true, act: "pref:showUncached"))
            }
            if let q = quality, q["levels"] is [[String: Any]] {
                out.append(Line(label: L("Picture quality"), header: true))
                out += Self.qualityLines(q, setup: false)
                let mbps = q["mbps"].flatMap { $0 is NSNull ? nil : $0 }
                out.append(Line(label: L("Speed check"),
                                detail: benchBusy ? L("Measuring…") : mbps != nil ? L("Last time: %1 Mbit/s down, this Mac scored %2", "\(mbps!)", "\(q["device"].flatMap { $0 is NSNull ? nil : $0 } ?? "–")")
                                    : L("Not measured yet: the recommendation is a guess"),
                                value: benchBusy ? "…" : L("Run"), act: "bench"))
            }
        case "accounts":
            let os = accounts["opensubtitles"] as? [String: Any] ?? [:]
            let osOn = os["set"] as? Bool == true && on("opensubtitles")
            out += app.flow.debridLines
            if !out.isEmpty { out.append(Line(label: L("Other accounts"), header: true)) }
            if let me = app.currentProfile {
                let t = me.trakt == "own"
                out.append(Line(label: L("Trakt"), detail: t ? L("%1 is signed in: Up Next and watch history stay in sync", me.name) : L("Up Next and watch history for %1", me.name),
                                value: t ? L("Sign out") : L("Sign in"), act: "trakt"))
            }
            let tm = accounts["tmdb"] as? [String: Any] ?? [:]
            let own = tm["own"] as? String
            out.append(Line(label: tm["builtin"] as? Bool == true ? L("Your own TMDB key") : L("Movie and show info (TMDB)"),
                            detail: tm["refused"] as? Bool == true ? L("TMDB refused the key in use: add your own (themoviedb.org › Settings › API)")
                                : own ?? (tm["builtin"] as? Bool == true ? L("Optional: Noonix TV's own key is built in") : L("Not set: home stays empty")),
                            value: own != nil ? L("Change") : L("Add"), act: "cred:TMDB_API_KEY"))
            out.append(Line(label: L("Use my OpenSubtitles.com account"), detail: L("Searches there first; otherwise Stremio's free OpenSubtitles addon"),
                            checkable: true, checked: osOn, act: "os"))
            if osOn {
                out.append(Line(label: L("OpenSubtitles API key"), detail: os["preview"] as? String ?? "", value: L("Change"), act: "cred:OPENSUBTITLES_API_KEY"))
                let user = os["user"] as? String
                out.append(Line(label: L("OpenSubtitles sign-in"), detail: user.map { L("Signed in as %1", $0) } ?? L("Optional: raises the daily limit"),
                                value: user != nil ? L("Change") : "›", act: "oslogin"))
            }
        case "profiles":
            for p in app.profiles?.profiles ?? [] {
                out.append(Line(label: p.name, detail: L("Name, colour and picture"), value: "›", act: "profile:\(p.id)"))
            }
            out.append(Line(label: L("Add profile"), value: "+", act: "profile-add"))
            out.append(Line(label: L("Sign in automatically"), detail: L("Open on the last profile without asking who's watching"),
                            checkable: true, checked: app.autoLogin, act: "auto-login"))
            out.append(Line(label: L("Another computer"), header: true))
            out.append(Line(label: L("Export this profile"), detail: L("%1's languages, sources and history as a file, for Noonix TV on another computer", app.currentProfile?.name ?? ""),
                            value: "›", act: "profile-export"))
            out.append(Line(label: L("Import a profile"), detail: L("A .noonix file from another computer, as a new profile"), value: "+", act: "profile-import"))
        case "audio":
            guard let p = prefs, let opts = langOptions?["audio"] as? [[String: Any]] else { break }
            out.append(Line(label: L("In order of preference: the first one a source has plays"), header: true))
            let chosen = p["languages"] as? [String] ?? []
            for o in Theme.preferredFirst(opts, snap(p)["languages"] ?? []) {
                let code = o["code"] as? String ?? "", r = chosen.firstIndex(of: code)
                out.append(Line(label: o["name"] as? String ?? code, checkable: true, checked: r != nil, badge: r.map { String($0 + 1) } ?? "", act: "lang:languages:" + code))
            }
        case "subtitles":
            guard let p = prefs, let opts = langOptions?["subtitles"] as? [[String: Any]] else { break }
            out.append(Line(label: L("Balkan mode"), detail: L("Treats Serbian, Croatian and Bosnian subtitles as one choice and always picks the best of them; sources that have them come first"),
                            checkable: true, checked: appSettings["balkan_subs"] as? Bool == true, act: "balkan"))
            out.append(Line(label: L("In order of preference"), header: true))
            let chosen = p["subtitles"] as? [String] ?? []
            for o in Theme.preferredFirst(opts, snap(p)["subtitles"] ?? []) {
                let code = o["code"] as? String ?? "", r = chosen.firstIndex(of: code)
                out.append(Line(label: o["name"] as? String ?? code, detail: code == "balkan" ? L("Whichever fits the release best, Serbian first on a tie") : "",
                                checkable: true, checked: r != nil, badge: r.map { String($0 + 1) } ?? "", act: "lang:subtitles:" + code))
            }
        case "playback":
            // the language's own name, whichever one is on
            out.append(Line(label: L("Language"), value: UILang.shared.code == "sr" ? "Srpski" : "English", act: "uilang"))
            out.append(Line(label: L("Open at login"), detail: L("Starts Noonix TV when you sign in to this Mac"),
                            checkable: true, checked: loginTick >= 0 && SMAppService.mainApp.status == .enabled, act: "login"))
            out.append(Line(label: L("Match the screen's refresh rate"), detail: L("Switches the screen to 24 / 25 / 50 / 60 Hz for each video (never the resolution or HDR)"),
                            checkable: true, checked: appSettings["refresh_match"] as? Bool == true, act: "refresh"))
            out.append(Line(label: L("Find extra subtitles"), detail: L("From OpenSubtitles, for your subtitle languages the file doesn't have"),
                            checkable: true, checked: on("extra_subs"), act: "app:extra_subs"))
            let hs = appSettings["hdr_screen"] as? String ?? "auto"
            let found = (screen["hdr"] as? Bool).map { $0 ? L("HDR") : L("no HDR") }
            out.append(Line(label: L("HDR on this screen"), detail: L("Picks the sources that suit it best. Set it yourself if the screen is guessed wrong"),
                            value: hs == "on" ? L("On") : hs == "off" ? L("Off") : found.map { L("Automatic (%1)", $0) } ?? L("Automatic"), act: "hdrscreen"))
        case "controls":
            // (qml Settings controls) each action's buttons and keys; ok on one waits for the new one
            let bd = Bindings.shared, all = bd.all
            let labels = ["OK": L("Select"), "BACK": L("Back"), "MENU": L("Options"), "PLAYPAUSE": L("Play / Pause"), "RW": L("Rewind"),
                          "FF": L("Fast-forward"), "CH_DOWN": L("Back 30 seconds"), "CH_UP": L("Forward 30 seconds"), "HOME": L("Home")]
            out.append(Line(label: L("Controller"), header: true))
            for a in Bindings.actions {
                let cap = bd.capturing == "pad:" + a
                let v = (all["pad"]?[a] ?? []).map(bd.padText).joined(separator: "  ·  ")
                out.append(Line(label: labels[a] ?? a, value: cap ? L("Press a button…") : v.isEmpty ? "–" : v, act: "bind:pad:" + a))
            }
            out.append(Line(label: L("Keyboard"), header: true))
            for a in Bindings.actions {
                let cap = bd.capturing == "keys:" + a
                let v = (all["keys"]?[a] ?? []).map(Bindings.keyText).joined(separator: "  ·  ")
                out.append(Line(label: labels[a] ?? a, value: cap ? L("Press a key…") : v.isEmpty ? "–" : v, act: "bind:keys:" + a))
            }
            out.append(Line(label: L("Always"), header: true))
            out.append(Line(label: L("Moving around"), detail: L("The d-pad, the left stick and the arrow keys")))
            out.append(Line(label: L("Mouse"), detail: L("Point to move, click to select, right click goes back, the wheel scrolls")))
            out.append(Line(label: L("Reset controls"), detail: L("The controller and keyboard as they came"), value: L("Reset"), act: "bind-reset"))
        default:
            // who made it, with the website a press away (qr for the phone)
            out.append(Line(label: "Noonix TV", value: version, act: "site", kind: "brand"))
            let u = update ?? [:]
            let det: String
            if updateState == "checking" { det = L("Checking…") }
            else if !updateState.isEmpty { det = updateState }
            else if u["available"] as? Bool == true { det = "\(u["latest"] ?? "") is out: download it from the releases page" }
            else { det = u["latest"] != nil ? L("Up to date") : L("Looks for a new version once a day") }
            out.append(Line(label: L("Updates"), detail: det, value: u["available"] as? Bool == true ? L("Open") : L("Check"), act: "update"))
            out.append(Line(label: L("Run setup again"), detail: L("Language, profiles, Trakt, sources, picture quality, subtitles"), value: "›", act: "setup-again"))
            out.append(Line(label: L("License"), detail: L("Free software under the GNU GPL 3.0 or later. Source: github.com/dzeliks/noonix-tv")))
            out.append(Line(label: L("Terms"), detail: L("A player for your own videos and the sources you add; you answer for what you watch. github.com/dzeliks/noonix-tv › TERMS.md")))
            out.append(Line(label: L("Credits"), header: true))
            out.append(Line(label: "", detail: L("This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB."), act: "", kind: "tmdb"))
            out.append(Line(label: L("Trakt"), detail: L("Up Next, watch history and scrobbling through the Trakt API. Not affiliated with Trakt.")))
            out.append(Line(label: "OpenSubtitles.com", detail: L("Extra subtitles")))
            out.append(Line(label: "IntroDB", detail: L("Intro, recap and credits times")))
            out.append(Line(label: L("Stremio addons"), detail: L("Noonix TV ships no sources: videos come from your library and the addons and extensions you add")))
            out.append(Line(label: "mpv · FFmpeg", detail: L("Video playback through MPVKit (LGPL)")))
            out.append(Line(label: L("Licenses"), detail: L("Every bundled library with its license and source: THIRD-PARTY.txt in the app's Resources")))
        }
        return out
    }

    func run(_ l: Line, app: AppModel) {
        let a = l.act
        if app.flow.run(a, app: app) { return }
        if a.hasPrefix("patterns:") {
            let which = String(a.dropFirst(9))
            let pt = patterns ?? [:]
            app.entry.open(title: which == "preferred" ? L("Preferred release patterns") : L("Hidden release patterns"),
                           hint: L("Commas between them. Words match whole words in any case; /…/ is a regular expression. Empty clears it"),
                           placeholder: "REMUX, HDR10+, /\\bITA\\b/", text: (pt[which] as? [String] ?? []).joined(separator: ", "), allowEmpty: true,
                           check: { [weak self] v in
                               var p: [String: Any] = ["preferred": pt["preferred"] as? [String] ?? [], "excluded": pt["excluded"] as? [String] ?? []]
                               p[which] = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                               do {
                                   let d = try await Core.shared.raw("patterns.set", p)
                                   let got = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                                   await MainActor.run { self?.patterns = got }
                                   return (true, L("Saved"))
                               } catch let e as CoreError {
                                   return (false, e.message)
                               } catch {
                                   return (false, L("Couldn't save it"))
                               }
                           })
            return
        }
        Task {
            if a == "site" {
                app.site = SiteCardModel(url: "https://aleksa.sh", title: "aleksa.sh")
                return
            } else if a.hasPrefix("quality:") {
                quality = await json("quality.set", ["id": String(a.dropFirst(8))]) as? [String: Any] ?? quality
                return
            } else if a == "bench" {
                guard !benchBusy else { return }
                benchBusy = true
                // one after the other: the cpu test would slow the download down
                _ = await json("bench.internet")
                _ = await json("bench.device")
                benchBusy = false
            } else if a == "trakt" {
                guard let p = app.currentProfile else { return }
                if p.trakt == "own" {
                    _ = await json("profiles.setTrakt", ["id": p.id, "mode": "none"])
                    await app.loadProfiles()
                } else {
                    app.openTrakt(p)
                }
                return
            } else if a == "setup-again" {
                inPage = false
                await app.openSetup(again: true)
                return
            } else if a == "copy-template", let t = template {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(t["name"] ?? "")\n\n\(t["description"] ?? "")", forType: .string)
                app.toast(L("Copied"))
                return
            } else if a.hasPrefix("pref:"), var p = prefs {
                let k = String(a.dropFirst(5))
                p[k] = !(p[k] as? Bool ?? false)
                prefs = p
                _ = await json("sources.setPrefs", p)
                return
            } else if a.hasPrefix("lang:") {
                let parts = a.split(separator: ":").map(String.init)
                // serbian, croatian or bosnian subtitles: balkan mode picks the best of the three
                if parts[1] == "subtitles", ["sr", "hr", "bs"].contains(parts[2]), appSettings["balkan_subs"] as? Bool != true, !l.checked {
                    _ = await json("setup.setBalkan", ["on": true])
                } else if var p = prefs {
                    var list = p[parts[1]] as? [String] ?? []
                    if let i = list.firstIndex(of: parts[2]) { if list.count > 1 { list.remove(at: i) } } else { list.append(parts[2]) }
                    p[parts[1]] = list
                    prefs = p
                    _ = await json("sources.setPrefs", p)
                    return
                }
            } else if a == "hdrscreen" {
                let order = ["auto", "on", "off"]
                let now = order.firstIndex(of: appSettings["hdr_screen"] as? String ?? "auto") ?? 0
                let v = order[(now + 1) % order.count]
                appSettings["hdr_screen"] = v
                _ = await json("settings.setApp", ["key": "hdr_screen", "value": v])
                return
            } else if a.hasPrefix("bind:") {
                let p = a.split(separator: ":").map(String.init)
                if Bindings.shared.capturing.isEmpty { Bindings.shared.capture(p[1], p[2]) } else { Bindings.shared.stopCapture() }
                return
            } else if a == "bind-reset" {
                Bindings.shared.reset()
                return
            } else if a == "uilang" {
                let nl = UILang.shared.code == "sr" ? "en" : "sr"
                UILang.shared.set(nl)
                appSettings["ui_lang"] = nl
                _ = await json("settings.setApp", ["key": "ui_lang", "value": nl])
                // serbian: balkan mode for the subtitles too
                if nl == "sr", appSettings["balkan_subs"] as? Bool != true { _ = await json("setup.setBalkan", ["on": true]) }
            } else if a == "refresh" {
                let v = appSettings["refresh_match"] as? Bool != true
                appSettings["refresh_match"] = v
                _ = await json("settings.setApp", ["key": "refresh_match", "value": v])
                return
            } else if a.hasPrefix("app:") {
                let k = String(a.dropFirst(4))
                let v = !(k == "auto_login" ? appSettings[k] as? Bool != false : on(k))
                appSettings[k] = v
                _ = await json("settings.setApp", ["key": k, "value": v])
                return
            } else if a == "balkan" {
                _ = await json("setup.setBalkan", ["on": appSettings["balkan_subs"] as? Bool != true])
            } else if a == "update" {
                if update?["available"] as? Bool == true, let url = URL(string: "https://github.com/dzeliks/noonix-tv/releases/latest") {
                    NSWorkspace.shared.open(url)
                    return
                }
                updateState = "checking"
                if let u = await json("update.check", ["auto": false]) as? [String: Any] { update = u; updateState = "" } else { updateState = L("Couldn't check") }
                return
            } else if a.hasPrefix("cred:") {
                app.enterCredential(String(a.dropFirst(5))) { [weak self] in Task { await self?.load() } }
                return
            } else if a == "os" {
                let was = (accounts["opensubtitles"] as? [String: Any])?["set"] as? Bool == true && on("opensubtitles")
                appSettings["opensubtitles"] = !was
                _ = await json("settings.setApp", ["key": "opensubtitles", "value": !was])
                if !was, (accounts["opensubtitles"] as? [String: Any])?["set"] as? Bool != true {
                    app.enterCredential("OPENSUBTITLES_API_KEY") { [weak self] in Task { await self?.load() } }
                }
                return
            } else if a == "oslogin" {
                app.enterOpenSubtitlesLogin { [weak self] in Task { await self?.load() } }
                return
            } else if a.hasPrefix("profile:"), let id = Int(a.dropFirst(8)), let p = app.profiles?.profiles.first(where: { $0.id == id }) {
                app.editProfile(p)
                return
            } else if a == "profile-add" {
                app.addProfile()
                return
            } else if a == "profile-export" {
                if let id = app.currentProfile?.id { app.exportProfile(id) }
                return
            } else if a == "profile-import" {
                app.importProfile()
                return
            } else if a == "login" {
                do {
                    if SMAppService.mainApp.status == .enabled { try await SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
                } catch {
                    app.toast(L("Couldn't change it: move Noonix TV to Applications first"))
                }
                loginTick += 1
                return
            } else if a == "auto-login" {
                app.setAutoLogin(!app.autoLogin)
                return
            } else {
                return
            }
            await load()
        }
    }

    // ---- keys: the section list, then its lines (headers are only titles)
    func key(_ k: Key, app: AppModel) -> Bool {
        let ls = lines(app: app)
        if !inPage {
            switch k {
            case .up: if section == 0 { return false } else { section -= 1 }
            case .down: section = min(Self.sections.count - 1, section + 1)
            case .right, .ok:
                swapTask?.cancel()
                showNow()
                if let i = lines(app: app).firstIndex(where: { !$0.header }) { index = i; inPage = true }
            case .back: return false
            default: break
            }
            return true
        }
        switch k {
        // above the first line: up to the tabs (qml upFromTop)
        case .up: if !step(-1, ls) { return false }
        case .down: step(1, ls)
        case .left, .back: inPage = false
        case .ok: if let l = ls[safe: index], !l.header { run(l, app: app) }
        default: break
        }
        return true
    }

    @discardableResult private func step(_ d: Int, _ ls: [Line]) -> Bool {
        var i = index + d
        while i >= 0, i < ls.count, ls[i].header { i += d }
        guard i >= 0, i < ls.count else { return false }
        index = i
        return true
    }
}

struct SettingsPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let u = app.u, W = app.size.width, H = app.size.height
        let m = app.settings
        let active = !app.navFocused && app.detailStack.isEmpty
        let margin = Theme.margin(u)
        let lines = m.lines(app: app)
        let pageX = margin + 420 * u + 80 * u
        ZStack(alignment: .topLeading) {
            Wallpaper()
            VStack(spacing: 8 * u) {
                ForEach(Array(SettingsModel.sections.enumerated()), id: \.offset) { i, s in
                    SettingsRow(line: .init(label: s.name, value: "›"), focused: active && !m.inPage && m.section == i, u: u)
                        .opacity(m.section == i || (active && !m.inPage) ? 1 : 0.6)
                        .onContinuousHover { phase in
                            if case .active = phase, Input.pointerLive { app.navFocused = false; m.inPage = false; m.section = i }
                        }
                        .onTapGesture { m.section = i; m.showNow() }
                }
            }
            .frame(width: 420 * u)
            .offset(x: margin, y: 200 * u)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 6 * u) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Group {
                                if l.header {
                                    // a section that opens with a header starts where the others' first row does
                                    SettingsHeader(text: l.label, height: (i == 0 ? 52 : 90) * u, u: u)
                                } else if l.kind == "brand" {
                                    BrandRow(version: l.value, focused: active && m.inPage && m.index == i, u: u)
                                        .onContinuousHover { phase in
                                            if case .active = phase, Input.pointerLive { app.navFocused = false; m.inPage = true; m.index = i }
                                        }
                                        .onTapGesture { m.inPage = true; m.index = i; m.run(l, app: app) }
                                } else {
                                    SettingsRow(line: l, focused: active && m.inPage && m.index == i, u: u)
                                        .onContinuousHover { phase in
                                            if case .active = phase, Input.pointerLive { app.navFocused = false; m.inPage = true; m.index = i }
                                        }
                                        .onTapGesture { m.inPage = true; m.index = i; m.run(l, app: app) }
                                }
                            }
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 24 * u)
                    .padding(.top, 12 * u)
                    .padding(.bottom, 40 * u)
                }
                .scrollIndicators(.never)
                .onChange(of: m.index) { if !Input.pointerHolds { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(m.index, anchor: .center) } } }
                .onChange(of: m.shown) { proxy.scrollTo(0, anchor: .top) }
            }
            .frame(width: W - pageX - margin + 48 * u, height: H - 200 * u)
            .offset(x: pageX - 24 * u, y: 200 * u)
            .opacity(m.pageOpacity)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
        .task { await m.load(app: app) }
        // something just added: the focus goes to its row
        .onChange(of: lines.count) {
            if !app.flow.focusAct.isEmpty, let i = lines.firstIndex(where: { $0.act == app.flow.focusAct }) {
                m.inPage = true
                m.index = i
                app.flow.focusAct = ""
            }
        }
        // the next visit starts at the top, like a fresh page
        .onDisappear { m.section = 0; m.showNow(); m.inPage = false }
    }
}

/// a title between settings lines (qml Settings headerLine)
struct SettingsHeader: View {
    let text: String
    let height: CGFloat
    let u: CGFloat

    var body: some View {
        Text(text).font(Theme.display(26 * u, .semibold)).foregroundStyle(Theme.fg2)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
            .padding(.bottom, 14 * u)
    }
}

/// the app's own card at the top of about (qml brandLine): icon, name, version, who made it
struct BrandRow: View {
    let version: String
    let focused: Bool
    let u: CGFloat

    /// "Created by **aleksa.sh**", the name bold wherever the language puts it
    private var createdBy: Text {
        let p = L("Created by %1").components(separatedBy: "%1")
        return Text(p.first ?? "") + Text("aleksa.sh").bold() + Text(p.count > 1 ? p[1] : "")
    }

    var body: some View {
        HStack(spacing: 36 * u) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 140 * u, height: 140 * u)
            VStack(alignment: .leading, spacing: 6 * u) {
                Text("Noonix TV").font(Theme.display(44 * u, .bold)).foregroundStyle(focused ? Theme.focusFg : Theme.fg)
                if !version.isEmpty {
                    Text(L("Version %1", version)).font(Theme.text(22 * u))
                        .foregroundStyle(focused ? Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.6) : Theme.fg3)
                }
                createdBy.font(Theme.text(26 * u))
                    .foregroundStyle(focused ? Theme.focusFg : Theme.fg2)
                    .padding(.top, 8 * u)
            }
            Spacer(minLength: 0)
            Text("›").font(Theme.text(34 * u)).foregroundStyle(focused ? Theme.focusFg : Theme.fg2)
        }
        .padding(.leading, 34 * u)
        .padding(.trailing, 40 * u)
        .frame(height: 220 * u)
        .background { RoundedRectangle(cornerRadius: 34 * u).fill(focused ? Color.white : Color.white.opacity(0.06)) }
        .scaleEffect(focused ? 1.02 : 1)
        .animation(Theme.lift, value: focused)
        .contentShape(.rect)
    }
}

/// one settings line (qml Toggle): label + detail, a value, a rank badge or a switch; white when focused
struct SettingsRow: View {
    let line: SettingsModel.Line
    let focused: Bool
    let u: CGFloat
    /// the focus lift; 1 inside tight panels (the setup list)
    var grow: CGFloat = 1.02

    var body: some View {
        HStack(spacing: 18 * u) {
            // a wide logo before the text (the tmdb credit)
            if line.kind == "tmdb", let url = Bundle.main.url(forResource: "tmdb", withExtension: "pdf"), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 30 * u)
                    .padding(.trailing, 8 * u)
            }
            VStack(alignment: .leading, spacing: 4 * u) {
                if !line.label.isEmpty {
                    Text(line.label).font(Theme.text(26 * u, .medium)).foregroundStyle(focused ? Theme.focusFg : Theme.fg)
                        .lineLimit(1)
                }
                if !line.detail.isEmpty {
                    Text(line.detail).font(Theme.text(20 * u))
                        .foregroundStyle(focused ? Theme.focusFg.opacity(0.6) : Theme.fg3)
                        .lineLimit(focused ? 8 : 2)
                }
            }
            // the text sets the height (qml Toggle), the switch sits inside it
            .padding(.vertical, 20 * u)
            Spacer(minLength: 12 * u)
            if !line.badge.isEmpty {
                Circle().fill(Theme.accent).frame(width: 40 * u, height: 40 * u)
                    .overlay { Text(line.badge).font(Theme.rounded(22 * u, .bold)).foregroundStyle(.white) }
            }
            if line.checkable {
                Capsule()
                    .fill(line.checked ? Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255) : focused ? Color.black.opacity(0.18) : Color.white.opacity(0.2))
                    .frame(width: 84 * u, height: 48 * u)
                    .overlay(alignment: line.checked ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 40 * u, height: 40 * u).padding(4 * u)
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: line.checked)
            } else if !line.value.isEmpty {
                Text(line.value).font(Theme.text(24 * u)).foregroundStyle(focused ? Theme.focusFg : Theme.fg2)
            }
        }
        .padding(.horizontal, 30 * u)
        .frame(maxWidth: .infinity, minHeight: (line.detail.isEmpty ? 84 : 108) * u, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 24 * u).fill(focused ? Color.white : .clear) }
        .scaleEffect(focused ? grow : 1)
        .animation(Theme.lift, value: focused)
        .contentShape(.rect)
    }
}
