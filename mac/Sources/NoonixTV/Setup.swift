import ServiceManagement
import SwiftUI

/// first run (and settings › about), qml Setup: a few calm steps over the app itself, blurred in a
/// window in the middle; when it's done that window zooms in and comes into focus. every step works
/// with the arrows alone: up / down through the lines, ok on a line, down to continue
@MainActor @Observable
final class SetupModel {
    typealias Line = SettingsModel.Line
    static let allSteps = ["language", "welcome", "terms", "profiles", "videos", "trakt", "audio", "subtitles", "background", "playback", "benchmark", "quality", "done"]
    /// set up before, the terms are new (or changed): just them
    var termsOnly = false
    var steps: [String] { termsOnly ? ["terms"] : Self.allSteps }
    static var titles: [String: String] { [
        "language": L("Choose your language"),
        "welcome": L("Welcome to Noonix TV"), "terms": L("Before you start"), "profiles": L("Who watches here?"), "videos": L("Your videos"), "trakt": L("Trakt"),
        "audio": L("Audio languages"), "subtitles": L("Subtitles"), "background": L("Stay signed in"),
        "playback": L("This Mac"), "benchmark": L("Speed check"), "quality": L("Picture quality"), "done": L("You're all set"),
    ] }


    var step = 0 { didSet { if step != oldValue { langSnap = nil } } }
    /// the languages' order as the step opened (the chosen ones first): a line doesn't jump away
    /// from the focus while it's ticked
    @ObservationIgnored private var langSnap: (languages: [String], subtitles: [String])?
    private func snap() -> (languages: [String], subtitles: [String]) {
        if langSnap == nil { langSnap = (languages, subtitles) }
        return langSnap!
    }
    var info: [String: Any]?
    var appS: [String: Any] = [:]
    var languages: [String] = ["en", "original"]
    var subtitles: [String] = ["en"]
    var langOptions: [String: Any]?
    var quality: [String: Any]?
    let speed = SpeedCheckModel()
    @ObservationIgnored private var benchAsked = false
    var busy = false
    var code: TraktCodeModel?
    var codeProfile = 0
    var loginOn = SMAppService.mainApp.status == .enabled
    // the focus: a line of the list, or the buttons (0 continue, 1 back)
    var index = 0
    var onButtons = true
    var button = 0
    /// the line to land on when the lines are rebuilt (-1: the step's first)
    var keepIndex = -1
    // the step sliding out and in, the finish zoom
    var paneOpacity: Double = 1
    var shift: CGFloat = 0
    var reveal: CGFloat = 0
    @ObservationIgnored private var turning = false

    var name: String { steps[step] }
    var acc: [String: Any] { info?["accounts"] as? [String: Any] ?? [:] }
    private func account(_ k: String) -> [String: Any] { acc[k] as? [String: Any] ?? [:] }
    private func appOn(_ k: String) -> Bool { appS[k] as? Bool != false }
    private var profiles: [[String: Any]] { info?["profiles"] as? [[String: Any]] ?? [] }
    /// trakt with nobody signed in: continue reads "skip for now"
    var skippable: Bool { name == "trakt" && !profiles.contains { $0["trakt"] as? String == "own" } }

    private func json(_ m: String, _ a: [String: Any] = [:]) async -> Any? {
        guard let d = try? await Core.shared.raw(m, a) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// what still keeps the app from working (the done step says it instead of "all set")
    func gaps(_ flow: SourcesFlow) -> [String] {
        var g: [String] = []
        let tm = account("tmdb")
        if !tm.isEmpty, tm["set"] as? Bool != true { g.append(L("Home stays empty without a TMDB key (Your videos step)")) }
        if !flow.hasSources { g.append(L("Nothing to play yet: pick a video folder or add a source (Your videos step)")) }
        let ds = flow.acc["debrids"] as? [[String: Any]] ?? []
        if let m = ds.first(where: { $0["wanted"] as? Bool == true && $0["set"] as? Bool != true }) {
            g.append(L("An extension still needs your %1 key (Your videos step)", m["name"] as? String ?? ""))
        }
        return g
    }

    /// the terms, plain reading (qml Setup termsCol)
    static var terms: [String] { [
        L("Noonix TV is only a player. It comes with no videos and no sources: it plays the files on your Mac and whatever addons or extensions you add yourself."),
        L("You're responsible for what you watch and download with it. Only use videos you have the right to, and follow the laws where you live."),
        L("Noonix TV is free software (GNU GPL 3.0) and comes with no warranty. Full terms: github.com/dzeliks/noonix-tv › TERMS.md"),
    ] }

    func blurb(_ flow: SourcesFlow) -> String {
        switch name {
        case "language": L("You can change it any time in Settings.")
        case "welcome": L("Your own movies and shows, and the sources you add, on this Mac. A few steps and you're watching.")
        case "terms": L("Please read this, then agree to go on.")
        case "profiles": L("Everyone gets their own Up Next, progress and language choices.")
        case "videos": L("Noonix TV plays the videos on this Mac and the sources you add yourself. Pick the folders your movies and shows are in; an addon or extension is optional.")
        case "trakt": L("Optional: Trakt keeps what you watched in sync. OK on a profile signs it in or out, or skip it for now.")
        case "audio": L("The languages you like to hear, best first. Noonix TV picks the audio track in this order. Right jumps to Continue.")
        case "subtitles": L("Subtitle languages, best first. Noonix TV turns on the first one a video has and can find the ones it doesn't. Right jumps to Continue.")
        case "background": L("Logins expire when nothing uses them for a while. Noonix TV can check them once a day.")
        case "playback": L("These can be changed any time in Settings.")
        case "benchmark": L("How fast this internet connection and this Mac are. The next step picks a picture quality from it.")
        case "quality": L("Picked from the speed check. Higher ones may stutter here, lower ones always play smoothly. Sources above it still show, last and marked. You can change it in Settings.")
        default: gaps(flow).isEmpty ? L("That's everything. You can change any of it later in Settings.") : L("Almost there. You can start now and add the rest later in Settings.")
        }
    }

    private func traktName(_ mode: String?) -> String {
        mode == "own" ? L("Signed in") : info?["traktRelogin"] as? Bool == true ? L("Sign in once more: Trakt now connects through Noonix TV itself") : L("Not signed in")
    }

    // ---- the step's lines
    func lines(app: AppModel) -> [Line] {
        var out: [Line] = []
        guard let s = info else { return out }
        switch name {
        case "language":
            out.append(Line(label: "English", checkable: true, checked: UILang.shared.code == "en", act: "uilang:en"))
            out.append(Line(label: "Srpski", checkable: true, checked: UILang.shared.code == "sr", act: "uilang:sr"))
        case "profiles":
            for (i, p) in profiles.enumerated() {
                out.append(Line(label: p["name"] as? String ?? "", detail: traktName(p["trakt"] as? String), value: "›", act: "edit:\(i)"))
            }
            out.append(Line(label: L("Add Profile"), value: "+", act: "add"))
        case "videos":
            out = app.flow.lines + app.flow.debridLines + app.flow.torrentLines
            let tm = account("tmdb")
            if !tm.isEmpty, tm["builtin"] as? Bool != true {
                let set = tm["set"] as? Bool == true
                out.append(Line(label: L("Movie and show info"), header: true))
                out.append(Line(label: L("TMDB key"), detail: set ? L("Set up") : L("A free API key from themoviedb.org › Settings › API. Without it home stays empty"),
                                value: set ? L("Change") : L("Add"), act: "cred:TMDB_API_KEY"))
            }
        case "trakt":
            for p in profiles {
                let id = (p["id"] as? NSNumber)?.intValue ?? 0, mode = p["trakt"] as? String ?? "none"
                let waiting = code != nil && codeProfile == id
                out.append(Line(label: p["name"] as? String ?? "", detail: waiting ? L("Waiting for the code below") : traktName(mode), value: "›", act: "trakt:\(id):\(mode)"))
            }
        case "audio":
            for o in Theme.preferredFirst(langOptions?["audio"] as? [[String: Any]] ?? [], snap().languages) {
                let c = o["code"] as? String ?? "", r = languages.firstIndex(of: c)
                out.append(Line(label: Lc(o["name"] as? String ?? c), checkable: true, checked: r != nil, badge: r.map { String($0 + 1) } ?? "", act: "lang:languages:" + c))
            }
        case "subtitles":
            guard let opts = langOptions?["subtitles"] as? [[String: Any]] else { break }
            out.append(Line(label: L("Find extra subtitles"), detail: L("For languages the video doesn't have, free through Stremio's OpenSubtitles addon"),
                            checkable: true, checked: appOn("extra_subs"), act: "app:extra_subs"))
            let os = account("opensubtitles"), osOn = os["set"] as? Bool == true && appS["opensubtitles"] as? Bool != false
            out.append(Line(label: L("Use my OpenSubtitles.com account"), detail: L("Searches there first with your own API key (opensubtitles.com › Consumers). Signing in raises the daily limit"),
                            checkable: true, checked: osOn, act: "os"))
            if osOn {
                out.append(Line(label: L("OpenSubtitles API key"), detail: os["preview"] as? String ?? "", value: L("Change"), act: "cred:OPENSUBTITLES_API_KEY"))
                let user = os["user"] as? String
                out.append(Line(label: L("Sign in (optional)"), detail: user.map { L("Signed in as %1", $0) } ?? L("Without it the limit is a few subtitles a day per home"),
                                value: user != nil ? L("Change") : "›", act: "oslogin"))
            }
            out.append(Line(label: L("Balkan mode"), detail: L("Treats Serbian, Croatian and Bosnian as one choice and always picks the best of them"),
                            checkable: true, checked: s["balkanOn"] as? Bool == true, act: "balkan"))
            out.append(Line(label: L("Languages"), header: true))
            for o in Theme.preferredFirst(opts, snap().subtitles) {
                let c = o["code"] as? String ?? "", r = subtitles.firstIndex(of: c)
                out.append(Line(label: Lc(o["name"] as? String ?? c), checkable: true, checked: r != nil, badge: r.map { String($0 + 1) } ?? "", act: "lang:subtitles:" + c))
            }
        case "background":
            let k = s["keepalive"] as? [String: Any] ?? [:]
            // on by default: a fresh setup gets it when it finishes, unless turned off here
            let on = k["installed"] as? Bool == true || (k["chosen"] is NSNull && k["scheduler"] as? Bool != false)
            if k["scheduler"] as? Bool == false {
                out.append(Line(label: L("Checked while Noonix TV is open"), detail: L("Logins are checked whenever the app runs")))
            } else {
                out.append(Line(label: L("Check logins once a day (Recommended)"), detail: L("Trakt, OpenSubtitles and your debrid keys, even on days Noonix TV stays closed"),
                                checkable: true, checked: on, act: "keepalive"))
            }
        case "playback":
            out.append(Line(label: L("Open at login"), detail: L("Starts Noonix TV when you sign in, handy on a Mac made for the TV"),
                            checkable: true, checked: loginOn, act: "login"))
            out.append(Line(label: L("Show the title bar"), detail: L("A normal window with the title bar and its buttons"),
                            checkable: true, checked: appS["title_bar"] as? Bool == true, act: "titlebar"))
            out.append(Line(label: L("Match the screen's refresh rate"), detail: L("24 / 25 / 50 / 60 Hz for each video, never the resolution or HDR"),
                            checkable: true, checked: appS["refresh_match"] as? Bool == true, act: "refresh"))
        case "benchmark":
            let sp = speed
            out.append(Line(label: L("Speed check"),
                            detail: sp.running ? L("Measuring…") : !sp.headline.isEmpty ? L("You can watch up to %1", sp.headline) + "  ·  " + sp.why : L("Not measured yet"),
                            value: sp.running ? "…" : L("Run"), act: "bench"))
            if let m = sp.netValue {
                out.append(Line(label: L("Internet"), detail: L("%1 Mbit/s down", String(Int(m.rounded()))), value: sp.netZones[safe: sp.netZone]?.label ?? "", act: "bench"))
            }
            if let p = sp.devValue {
                out.append(Line(label: L("This Mac"), detail: L("%1 points", String(Int(p.rounded()))), value: sp.devZones[safe: sp.devZone]?.label ?? "", act: "bench"))
            }
        case "quality":
            out = SettingsModel.qualityLines(quality, setup: true)
        case "done":
            out = gaps(app.flow).map { Line(label: $0) }
        default:
            break
        }
        return out
    }

    // ---- data
    func open(app: AppModel) async {
        step = 0
        paneOpacity = 1; shift = 0; reveal = 0
        onButtons = true; button = 0
        app.flow.changed = { [weak self, weak app] in Task { await self?.refresh(app: app) } }
        await refresh(app: app)
        if let p = await json("sources.prefs") as? [String: Any] {
            languages = p["languages"] as? [String] ?? languages
            subtitles = p["subtitles"] as? [String] ?? subtitles
        }
        langOptions = await json("languages.options") as? [String: Any]
    }

    func refresh(app: AppModel? = nil) async {
        async let i = json("setup.state")
        async let st = json("settings.app")
        if let app { await app.flow.load() }
        info = await i as? [String: Any] ?? info
        appS = await st as? [String: Any] ?? appS
        loginOn = SMAppService.mainApp.status == .enabled
    }

    private func setApp(_ k: String, _ v: Any) {
        appS[k] = v
        Task { _ = await json("settings.setApp", ["key": k, "value": v]) }
    }

    private func balkan(_ on: Bool) async {
        _ = await json("setup.setBalkan", ["on": on])
        await refresh()
        langOptions = await json("languages.options") as? [String: Any] ?? langOptions
        if let p = await json("sources.prefs") as? [String: Any] {
            languages = p["languages"] as? [String] ?? languages
            subtitles = p["subtitles"] as? [String] ?? subtitles
        }
    }

    func run(_ l: Line, app: AppModel) {
        keepIndex = index
        let a = l.act
        if app.flow.run(a, app: app) { return }
        if a.hasPrefix("uilang:") {
            let c = String(a.dropFirst(7))
            UILang.shared.set(c)
            setApp("ui_lang", c)
            // serbian: balkan mode on, so the subtitles step already shows it picked
            if c == "sr", info?["balkanOn"] as? Bool != true { Task { await balkan(true) } }
        } else if a == "refresh" {
            setApp("refresh_match", appS["refresh_match"] as? Bool != true)
        } else if a == "add" {
            app.addProfile { [weak self] in Task { await self?.refresh() } }
        } else if a.hasPrefix("edit:"), let i = Int(a.dropFirst(5)), let p = profiles[safe: i], let id = (p["id"] as? NSNumber)?.intValue {
            let profile = Profile(id: id, name: p["name"] as? String ?? "", color: p["color"] as? String ?? "green",
                                  trakt: p["trakt"] as? String ?? "", avatar: p["avatar"] as? String)
            app.editProfile(profile) { [weak self] in Task { await self?.refresh() } }
        } else if a.hasPrefix("trakt:") {
            let parts = a.split(separator: ":").map(String.init)
            let id = Int(parts[1]) ?? 0
            // signed in -> out; out -> sign in with a code
            if parts[2] == "own" {
                Task { _ = await json("profiles.setTrakt", ["id": id, "mode": "none"]); await refresh() }
            } else {
                code?.cancel()
                codeProfile = id
                let c = TraktCodeModel(profile: id, name: "")
                code = c
                c.start { [weak self] ok, say in
                    self?.code = nil
                    if let say { app.toast(say) }
                    if ok { Task { await self?.refresh(); await app.loadProfiles() } }
                    if let local = c.local { app.traktChoice = TraktChoiceModel(profile: id, local: local) }
                }
            }
        } else if a == "bench" {
            speed.measured = { [weak self] in Task { self?.quality = await self?.json("quality.options") as? [String: Any] ?? self?.quality } }
            speed.open(auto: speed.netValue == nil || speed.devValue == nil, app: app)
        } else if a.hasPrefix("quality:") {
            Task { quality = await json("quality.set", ["id": String(a.dropFirst(8))]) as? [String: Any] ?? quality }
        } else if a.hasPrefix("lang:") {
            let p = a.split(separator: ":").map(String.init)
            // serbian, croatian or bosnian subtitles: balkan mode picks the best of the three
            if p[1] == "subtitles", ["sr", "hr", "bs"].contains(p[2]), info?["balkanOn"] as? Bool != true, !l.checked {
                Task { await balkan(true) }
            } else {
                var list = p[1] == "languages" ? languages : subtitles
                if let i = list.firstIndex(of: p[2]) { if list.count > 1 { list.remove(at: i) } } else { list.append(p[2]) }
                if p[1] == "languages" { languages = list } else { subtitles = list }
            }
        } else if a == "titlebar" {
            let v = appS["title_bar"] as? Bool != true
            appS["title_bar"] = v
            showTitleBar(v)
            Task { _ = try? await Core.shared.raw("settings.setApp", ["key": "title_bar", "value": v]) }
        } else if a == "login" {
            Task {
                do {
                    if loginOn { try await SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
                } catch {
                    app.toast(L("Couldn't change it: move Noonix TV to Applications first"))
                }
                loginOn = SMAppService.mainApp.status == .enabled
            }
        } else if a == "keepalive" {
            busy = true
            Task {
                if await json(l.checked ? "keepalive.remove" : "keepalive.install") == nil { app.toast(L("Couldn't change the daily check")) }
                busy = false
                await refresh()
            }
        } else if a.hasPrefix("cred:") {
            app.enterCredential(String(a.dropFirst(5))) { [weak self] in Task { await self?.refresh(app: app) } }
        } else if a == "os" {
            let set = account("opensubtitles")["set"] as? Bool == true
            let on = !(set && appS["opensubtitles"] as? Bool != false)
            setApp("opensubtitles", on)
            if on && !set { app.enterCredential("OPENSUBTITLES_API_KEY") { [weak self] in Task { await self?.refresh() } } }
        } else if a == "oslogin" {
            app.enterOpenSubtitlesLogin { [weak self] in Task { await self?.refresh() } }
        } else if a.hasPrefix("app:") {
            let k = String(a.dropFirst(4))
            setApp(k, !appOn(k))
        } else if a == "balkan" {
            Task { await balkan(!l.checked) }
        }
    }

    // ---- steps
    func next(app: AppModel) {
        if name == "profiles", profiles.isEmpty {
            app.addProfile { [weak self] in Task { await self?.refresh() } }
            return
        }
        // continuing without a pick keeps the recommended one
        if name == "quality", let q = quality, q["chosen"] as? Bool != true, let rec = q["recommended"] as? String {
            Task { quality = await json("quality.set", ["id": rec]) as? [String: Any] ?? quality }
        }
        if name == "audio" || name == "subtitles" {
            let l = languages, s = subtitles
            Task { _ = await json("setup.setLanguages", ["languages": l, "subtitles": s]) }
        }
        if name == "terms" {
            Task {
                _ = await json("setup.agree")
                if termsOnly { await finish(app: app) }
            }
            if termsOnly { return }
        }
        if name == "done" {
            Task {
                _ = await json("setup.finish")
                await finish(app: app)
            }
            return
        }
        go(step + 1, app: app)
    }

    func back(app: AppModel) {
        if code != nil { code?.cancel(); code = nil; return }
        if step > 0 { go(step - 1, app: app) }
    }

    /// steps slide: out to the side they came from, in from the other
    private func go(_ n: Int, app: AppModel) {
        guard !turning, n >= 0, n < steps.count else { return }
        turning = true
        let dir: CGFloat = n > step ? 1 : -1
        Task {
            withAnimation(.easeIn(duration: 0.15)) { paneOpacity = 0; shift = -70 * dir }
            try? await Task.sleep(for: .milliseconds(150))
            keepIndex = -1
            step = n
            onButtons = true
            button = 0
            index = firstLine(app: app)
            shift = 70 * dir
            entered()
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.28)) { paneOpacity = 1 }
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.34)) { shift = 0 }
            try? await Task.sleep(for: .milliseconds(340))
            turning = false
        }
    }

    private func entered() {
        if name == "benchmark", !benchAsked, let app = AppModel.current {
            benchAsked = true
            speed.measured = { [weak self] in Task { self?.quality = await self?.json("quality.options") as? [String: Any] ?? self?.quality } }
            speed.open(auto: true, app: app)
        }
        if name == "quality" { Task { quality = await json("quality.options") as? [String: Any] ?? quality } }
        if name == "trakt" || name == "profiles" { Task { await refresh() } }
    }

    /// done: the words go, the app's window zooms in to the whole screen and sharpens
    private func finish(app: AppModel) async {
        withAnimation(.easeIn(duration: 0.2)) { paneOpacity = 0 }
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.62)) { reveal = 1 }
        try? await Task.sleep(for: .milliseconds(620))
        app.setup = nil
        app.settings.section = 0
        await app.loadProfiles()
        for r in app.rails.values { r.refreshPersonal() }
        app.choose(app.page)
        // the terms only, at launch: who's watching comes after them
        if termsOnly, !app.autoLogin, app.profiles?.profiles.isEmpty == false { app.openPicker() }
    }

    private func firstLine(app: AppModel) -> Int { lines(app: app).firstIndex { !$0.header } ?? 0 }

    // ---- keys
    func key(_ k: Key, app: AppModel) -> Bool {
        let ls = lines(app: app)
        if k == .back { back(app: app); return true }
        if onButtons {
            switch k {
            case .up:
                // the line just above the buttons, or where the focus was in the list
                if !ls.isEmpty {
                    onButtons = false
                    if keepIndex < 0 {
                        var i = ls.count - 1
                        while i > 0, ls[i].header { i -= 1 }
                        index = i; keepIndex = i
                    } else if ls[safe: index]?.header != false {
                        index = firstLine(app: app)
                    }
                }
            case .left: button = 0
            case .right: if step > 0 { button = 1 }
            case .ok: if button == 0 { next(app: app) } else { back(app: app) }
            default: break
            }
            return true
        }
        switch k {
        case .up:
            var i = index - 1
            while i >= 0, ls[i].header { i -= 1 }
            if i >= 0 { index = i; keepIndex = i }
        case .down:
            var i = index + 1
            while i < ls.count, ls[i].header { i += 1 }
            if i >= ls.count { onButtons = true; button = 0 } else { index = i; keepIndex = i }
        case .right: onButtons = true; button = 0
        case .ok: if let l = ls[safe: index], !l.header { run(l, app: app) }
        default: break
        }
        return true
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var app
    let model: SetupModel
    @State private var listH: CGFloat = 0

    var body: some View {
        let u = app.u
        let lines = model.lines(app: app)
        VStack(alignment: .leading, spacing: 22 * u) {
            Text(L("Step %1 of %2", model.step + 1, model.steps.count)).font(Theme.text(23 * u, .medium)).foregroundStyle(Theme.fg3)
                .opacity(model.termsOnly ? 0 : 1)
            Text(SetupModel.titles[model.name] ?? "").font(Theme.display(56 * u, .bold)).foregroundStyle(Theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.blurb(app.flow)).font(Theme.text(28 * u)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Color.clear.frame(height: 8 * u)
            if !lines.isEmpty { list(lines, u) }
            if model.name == "terms" { termsPanel(u) }
            if let c = model.code { codePanel(c, u) }
            Color.clear.frame(height: 10 * u)
            HStack(spacing: 24 * u) {
                GlassButton(text: model.name == "done" ? L("Start Watching") : model.name == "welcome" ? L("Get Started") : model.name == "terms" ? L("I Agree") : model.skippable ? L("Skip for Now") : L("Continue"),
                            primary: true, focused: model.onButtons && model.button == 0, u: u, flat: true)
                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.onButtons = true; model.button = 0 } }
                    .onTapGesture { model.next(app: app) }
                if model.step > 0 {
                    GlassButton(text: L("Back"), focused: model.onButtons && model.button == 1, u: u, flat: true)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.onButtons = true; model.button = 1 } }
                        .onTapGesture { model.back(app: app) }
                }
            }
        }
        .frame(width: 1100 * u, alignment: .leading)
        .opacity(model.paneOpacity)
        .offset(x: model.shift * u)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: lines.count) {
            // rebuilt lines keep the focus where it was (or the step's first); something just added
            // gets it instead
            var i = model.keepIndex < 0 ? (lines.firstIndex { !$0.header } ?? 0) : min(model.keepIndex, max(0, lines.count - 1))
            if !app.flow.focusAct.isEmpty, let added = lines.firstIndex(where: { $0.act == app.flow.focusAct }) {
                i = added
                model.keepIndex = added
                app.flow.focusAct = ""
            }
            model.index = i
        }
    }

    private func list(_ lines: [SettingsModel.Line], _ u: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Group {
                            if l.header {
                                Text(l.label).font(Theme.display(26 * u, .semibold)).foregroundStyle(Theme.fg2)
                                    .padding(.leading, 30 * u).padding(.bottom, 12 * u)
                                    .frame(maxWidth: .infinity, minHeight: 76 * u, alignment: .bottomLeading)
                            } else {
                                SettingsRow(line: l, focused: !model.onButtons && model.index == i && app.profileEdit == nil, u: u, grow: 1)
                                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.onButtons = false; model.index = i } }
                                    .onTapGesture { model.onButtons = false; model.index = i; model.run(l, app: app) }
                            }
                        }
                        .id(i)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listH = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(530 * u, listH))
            .onChange(of: model.index) { if !Input.pointerHolds { withAnimation(.easeOut(duration: 0.14)) { proxy.scrollTo(model.index, anchor: .center) } } }
        }
        .padding(16 * u)
        .panelGlass(40 * u, u: u)
    }

    /// the terms: plain reading, nothing to pick
    private func termsPanel(_ u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24 * u) {
            ForEach(Array(SetupModel.terms.enumerated()), id: \.offset) { i, t in
                Text(t).font(Theme.text((i == 2 ? 24 : 28) * u)).foregroundStyle(i == 2 ? Theme.fg3 : Theme.fg2)
                    .lineSpacing(3 * u)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 46 * u)
        .padding(.vertical, 36 * u)
        .panelGlass(40 * u, u: u)
    }

    /// the trakt code, big enough to read from the couch
    private func codePanel(_ c: TraktCodeModel, _ u: CGFloat) -> some View {
        VStack(spacing: 12 * u) {
            Text(c.userCode == nil ? L("Asking Trakt for a code…") : L("On your phone, open %1 and enter", c.url))
                .font(Theme.text(27 * u)).foregroundStyle(Theme.fg2)
            Text(c.userCode ?? "· · · ·").font(Theme.rounded(84 * u, .bold)).tracking(8 * u).foregroundStyle(Theme.fg)
                .textSelection(.enabled)
            Spinner(size: 44 * u)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32 * u)
        .panelGlass(40 * u, u: u)
    }
}
