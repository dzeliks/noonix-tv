import AppKit
import Foundation
import Observation
import SwiftUI

/// the top bar's tabs, in its order
enum Page: String, CaseIterable, Identifiable {
    case search, home, movies, shows, library, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .movies: "Movies"
        case .shows: "Shows"
        case .library: "Library"
        case .search, .settings: ""
        }
    }
    var icon: String? {
        switch self {
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        default: nil
        }
    }
}

/// one titled row: its items load once and stay; index = the focused card
@MainActor @Observable
final class RowModel: Identifiable {
    let row: Row
    var items: [Item] = []
    var loaded = false
    var index = 0
    nonisolated var id: String { row.id }

    init(_ row: Row) { self.row = row }
    init(_ row: Row, items: [Item]) {
        self.row = row
        self.items = items
        loaded = true
    }

    var current: Item? { items.isEmpty ? nil : items[min(index, items.count - 1)] }

    func load(force: Bool = false) async {
        guard !loaded || force else { return }
        let got = (try? await Core.shared.call("home.row", ["id": row.id], as: [Item].self)) ?? []
        let key = current?.id
        items = got
        loaded = true
        if let key, let i = got.firstIndex(where: { $0.id == key }) { index = i } else { index = min(index, max(0, got.count - 1)) }
    }

    /// cards: the focus rests on the 2nd slot (3rd for posters) and the row slides under it
    var restSlot: Int { row.style == "poster" ? 2 : 1 }
}

/// home / movies / shows: the rows and the focused one
@MainActor @Observable
final class Rails {
    let page: Page
    var rows: [RowModel] = []
    /// home.rows answered (placeholder rows until then)
    var known = false
    var current = 0
    @ObservationIgnored private var focusedId: String?
    private static let personal: Set = ["upnext", "continue", "continue-movie", "recent", "library", "library-movie", "library-show"]

    init(_ page: Page) { self.page = page }
    static let placeholders = [RowModel(Row(id: "placeholder-0", title: "", style: "landscape")),
                               RowModel(Row(id: "placeholder-1", title: "", style: "poster"))]

    /// personal rows step aside while they're empty
    var shown: [RowModel] { rows.filter { !Rails.personal.contains($0.id) || !$0.loaded || !$0.items.isEmpty } }
    var focusedRow: RowModel? { let s = shown; return s.isEmpty ? nil : s[min(current, s.count - 1)] }

    func load() async {
        guard rows.isEmpty else { return }
        let specs = (try? await Core.shared.call("home.rows", ["page": page.rawValue], as: [Row].self)) ?? []
        rows = specs.map(RowModel.init)
        known = true
        focusedId = rows.first?.id
        for r in rows { Task { await r.load(); self.keepFocus() } }
    }

    func refreshPersonal() {
        for r in rows where Rails.personal.contains(r.id) { Task { await r.load(force: true); self.keepFocus() } }
    }

    func keepFocus() {
        let s = shown
        if let id = focusedId, let i = s.firstIndex(where: { $0.id == id }) { current = i }
        current = min(current, max(0, s.count - 1))
        focusedId = focusedRow?.id
    }

    func move(_ d: Int) {
        current = max(0, min(shown.count - 1, current + d))
        focusedId = focusedRow?.id
    }

    func point(_ row: RowModel, _ index: Int) {
        if let i = shown.firstIndex(where: { $0 === row }) { current = i }
        focusedId = row.id
        row.index = index
    }
}

@MainActor @Observable
final class AppModel {
    static weak var current: AppModel?

    var size = CGSize(width: 1920, height: 1080)
    /// the 1920x1080 grid: by height, but a taller window (16:10, a mac's own screen) scales by
    /// width and just gets more room below
    var u: CGFloat { max(0.4, min(size.height / 1080, size.width / 1920)) }

    var page: Page = .home
    var navFocused = false {
        // leaving the bar from the avatar puts the capsule back on the page's tab
        didSet { if !navFocused && navIndex < 0 { navIndex = Page.allCases.firstIndex(of: page) ?? 1 } }
    }
    var navIndex = 1
    /// the exit prompt is up: 0 = exit, 1 = stay (focused first)
    var exitChoice: Int?
    /// torrents / a debrid service explained (or the torrents question), over setup or settings
    var help: SourcesHelpModel?
    /// an addon or extension: what it brings, before it's added or once it's in
    var extSheet: ExtensionSheetModel?
    /// picking a library folder with the remote (FolderPicker)
    var folderPicker: FolderPickerModel?
    /// a profile going to or coming from a .noonix file
    var profileSheet: ProfileSheetModel?
    /// the library and the user's own sources, shared by setup and settings
    let flow = SourcesFlow()
    /// the launch splash until it has played (off with NOONIX_SPLASH=0)
    var splash: SplashModel? = SplashModel.enabled ? SplashModel() : nil
    /// the match tip's focused button while it's up (0 ok, 1 don't show again)
    var tipChoice: Int?
    var matchTipOff = true
    var matchTipShown = false
    @ObservationIgnored var tipPaused = false
    var rails: [Page: Rails] = [.home: Rails(.home), .movies: Rails(.movies), .shows: Rails(.shows)]
    var profiles: Profiles?
    var detailStack: [DetailsModel] = []
    var sources: SourcesModel?
    var finder: FinderModel?
    var picker: PickerModel?
    var menu: CardMenu?
    /// the focused card's art in the window (Card reports it)
    @ObservationIgnored var focusedArt: CGRect?
    var toastText: String?
    /// what menu does while the toast is up (undo), and what runs once it's gone without it
    var toastAction = ""
    @ObservationIgnored private var toastRun: (() -> Void)?
    @ObservationIgnored private var toastCommit: (() -> Void)?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// news nobody asked for (an update, a trakt login, a word from the core) waits until someone is
    /// watching: setup done, a profile chosen, no splash or picker. the newest one, a moment after
    @ObservationIgnored private var waitingNews: String?
    @ObservationIgnored private var reloginTask: Task<Void, Never>?
    private(set) var watching = false
    var watchingNow: Bool { setup == nil && currentProfile != nil && splash == nil && picker == nil }
    var trakt: TraktCodeModel?
    /// a website as a qr code (settings › about)
    var site: SiteCardModel?
    let player = MPVPlayer()
    var playing = false { didSet { MediaKeys.playing(playing); if !playing { tipChoice = nil } } }
    let library = GridModel()
    let search = SearchModel()
    let settings = SettingsModel()
    var setup: SetupModel?
    /// the one key / address / login card (qml KeyEntry on the sheet layer)
    let entry = KeyEntryModel()
    /// a profile being added or edited (qml ProfileAdd)
    var profileEdit: ProfileEditModel?
    /// opens on the last profile without asking who's watching
    var autoLogin = false
    /// what was used last, for the key hints: keyboard or pad (and which pad)
    var inputKind = "keyboard"
    var padKind = "other"
    var heroCache: [String: Details] = [:]

    var currentProfile: Profile? {
        profiles.flatMap { p in p.profiles.first { $0.id == p.current } }
    }

    func start() async {
        AppModel.current = self
        Core.shared.start()
        splash?.onDone = { [weak self] in self?.splash = nil }
        // what's underneath gets its content first; anyway after 3 s
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.splash?.play()
        }
        // the private build's own sources (nothing in this one), and new files in the library folders
        Task {
            _ = try? await Core.shared.raw("local.start")
            _ = try? await Core.shared.raw("library.scan")
        }
        // a library scan finished: its rows and the sources lines
        Core.shared.on("library", key: "app") { [weak self] d in
            guard let self else { return }
            flow.pushed(d)
            for r in rails.values { r.refreshPersonal() }
            if page == .library { Task { await self.library.load() } }
        }
        // a word from the core (tmdb refused the key, ...)
        Core.shared.on("notice", key: "app") { [weak self] d in
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let m = o["message"] as? String, !m.isEmpty else { return }
            self?.notify(UILang.shared.core(m))
        }
        // a new release: one quiet line after launch, never over a video
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let d = try? await Core.shared.raw("update.check", ["auto": true]),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["available"] as? Bool == true, let latest = o["latest"] as? String, self?.playing == false else { return }
            self?.notify(L("Noonix TV %1 is out  ·  Settings › About", latest))
        }
        Input.install({ [weak self] k in
            if self?.inputKind != "keyboard" { self?.inputKind = "keyboard" }
            return self?.key(k) ?? false
        }, typed: { [weak self] t in self?.typed(t) ?? false })
        MediaKeys.install { [weak self] k in self?.key(k) ?? false }
        DevKeys.install({ [weak self] k in self?.key(k) ?? false }, typed: { [weak self] t in self?.typed(t) ?? false })
        Pads.install { [weak self] k in
            if self?.inputKind != "pad" { self?.inputKind = "pad"; self?.padKind = Pads.kind }
            return self?.key(k) ?? false
        }
        // now, on another screen and back in focus (hdr may have been switched meanwhile)
        reportDisplay()
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportDisplay() }
            }
        }
        let st = (try? await Core.shared.raw("settings.app")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        UILang.shared.set(st?["ui_lang"] as? String ?? UILang.system)
        Bindings.shared.load(st?["controls"])
        if let a = st {
            autoLogin = a["auto_login"] as? Bool == true
            matchTipOff = a["match_tip_off"] as? Bool == true
        }
        await loadProfiles()
        // set up before, and not signing in on its own: who's watching first (qml prepareLaunch)
        if setup == nil, !autoLogin || profiles?.profiles.isEmpty != false { openPicker() }
        if setup != nil || picker != nil { splash?.play() }
        await rails[.home]?.load()
        splash?.play()
        warm()
    }

    /// what the screen shows, for the source ranking: edr headroom means hdr, and gpu-next
    /// reshapes dolby vision
    func reportDisplay() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let hdr = (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        Task { _ = try? await Core.shared.raw("display.caps", ["hdr": hdr, "dv": true]) }
    }

    func loadProfiles() async {
        profiles = try? await Core.shared.call("profiles.list", as: Profiles.self)
        await openSetup()
    }

    /// the first run's steps until setup.finish (its profiles step makes the first profile)
    func openSetup(again: Bool = false) async {
        guard setup == nil else { return }
        // NOONIX_SETUP=1: the steps on every start (dev)
        var termsOnly = false
        if !again, ProcessInfo.processInfo.environment["NOONIX_SETUP"] != "1" {
            guard let d = try? await Core.shared.raw("setup.state"),
                  let st = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            // set up before but the terms are new: just those
            if st["done"] as? Bool == true {
                guard st["termsAgreed"] as? Bool != true else { return }
                termsOnly = true
            }
        }
        let s = SetupModel()
        s.termsOnly = termsOnly
        setup = s
        await s.open(app: self)
    }

    /// the new profile card; `then` after it's added (the first one is switched to right away)
    func addProfile(then: (() -> Void)? = nil) {
        let m = ProfileEditModel()
        m.open(taken: profiles?.profiles.map(\.color) ?? [])
        m.cancel = { [weak self] in self?.profileEdit = nil }
        m.done = { [weak self] p, _ in
            guard let self else { return }
            profileEdit = nil
            let first = profiles?.profiles.isEmpty != false
            Task {
                if first {
                    _ = try? await Core.shared.raw("profiles.select", ["id": p.id])
                    await self.loadProfiles()
                    self.rails = [.home: Rails(.home), .movies: Rails(.movies), .shows: Rails(.shows)]
                    self.choose(self.page)
                    self.warm()
                } else {
                    await self.loadProfiles()
                    self.toast(L("Added %1", p.name))
                }
                then?()
            }
        }
        profileEdit = m
    }

    func editProfile(_ p: Profile) {
        let m = ProfileEditModel()
        m.openEdit(p)
        m.cancel = { [weak self] in self?.profileEdit = nil }
        m.done = { [weak self] _, _ in
            self?.profileEdit = nil
            Task { await self?.loadProfiles() }
        }
        profileEdit = m
    }

    func setAutoLogin(_ on: Bool) {
        autoLogin = on
        settings.appSettings["auto_login"] = on
        Task { _ = try? await Core.shared.raw("settings.setApp", ["key": "auto_login", "value": on]) }
    }

    func closePicker() {
        // nobody picked: the one watching stays (a launch picker with no profile chosen can't close)
        guard profiles?.profiles.isEmpty == false else { return }
        picker = nil
    }

    /// a real keyboard while an on-screen one is up
    func typed(_ t: Typed) -> Bool {
        if entry.isOpen { entry.typed(t); return true }
        if let p = profileEdit { p.typed(t); return true }
        // the search page's keyboard has the focus
        if page == .search, !navFocused, detailStack.isEmpty, sources == nil, !playing, picker == nil, setup == nil, search.zone == "keys" {
            search.typed(t)
            return true
        }
        return false
    }

    /// top right under the clock (qml Toast); with an action, menu runs it while it's up
    func toast(_ text: String, action: String = "", secs: Double? = nil, run: (() -> Void)? = nil, commit: (() -> Void)? = nil) {
        finishToast()
        toastText = text
        toastAction = action
        toastRun = run
        toastCommit = commit
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(secs ?? (action.isEmpty ? 3 : 6)))
            if !Task.isCancelled { toastText = nil; finishToast() }
        }
    }

    /// news: now, or once someone is watching
    func notify(_ text: String) {
        if watching { toast(text) } else { waitingNews = text }
    }

    /// RootView, when watchingNow turns true (and on a profile switch after that)
    func watchStarted() {
        if !watching {
            watching = true
            if let t = waitingNews {
                waitingNews = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    self?.toast(t)
                }
            }
        }
        reloginCheck()
    }

    /// the profile chosen has a trakt login to redo: that one hears about it
    func reloginCheck() {
        reloginTask?.cancel()
        guard currentProfile?.traktRelogin == true else { return }
        reloginTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !playing, currentProfile?.traktRelogin == true else { return }
            notify(L("Sign in to Trakt once more: Settings › Accounts"))
        }
    }

    private func finishToast() {
        let f = toastCommit
        toastCommit = nil
        toastRun = nil
        f?()
    }

    /// menu while a toast with an action is up: the action (undo) instead of the options
    func triggerToast() -> Bool {
        guard toastText != nil, let f = toastRun else { return false }
        toastCommit = nil
        toastRun = nil
        toastText = nil
        toastTask?.cancel()
        f()
        return true
    }

    func openPicker() {
        navFocused = true
        navIndex = -1
        picker = PickerModel(app: self)
    }

    func selectProfile(_ p: Profile) async {
        guard (try? await Core.shared.raw("profiles.select", ["id": p.id])) != nil else { return }
        await switched()
    }

    /// another profile: its own rows, library and history, from the top bar
    private func switched() async {
        picker = nil
        detailStack = []
        await loadProfiles()
        rails = [.home: Rails(.home), .movies: Rails(.movies), .shows: Rails(.shows)]
        library.items = []
        choose(page)
        navFocused = true
        warm()
    }

    func openTrakt(_ p: Profile) {
        let t = TraktCodeModel(profile: p.id, name: p.name)
        trakt = t
        t.start { [weak self] ok, say in
            self?.closeTrakt(ok)
            if let say { self?.toast(say) }
        }
    }

    func closeTrakt(_ ok: Bool) {
        trakt?.cancel()
        trakt = nil
        if ok { Task { await loadProfiles(); for r in rails.values { r.refreshPersonal() } } }
    }

    // ---- details of titles, ahead of the focus (the hero and the details page read them)
    @ObservationIgnored private var asked: Set<String> = []
    static func key(_ item: Item?) -> String? { item?.detailsTarget.map { "\($0.kind):\($0.id)" } }
    func prefetch(_ item: Item?) {
        guard let t = item?.detailsTarget, let key = AppModel.key(item) else { return }
        guard heroCache[key] == nil, !asked.contains(key) else { return }
        asked.insert(key)
        Task {
            if let d = try? await Core.shared.call("tmdb.details", ["kind": t.kind, "id": t.id], as: Details.self) {
                heroCache[key] = d
            } else {
                asked.remove(key)
            }
        }
    }

    // ---- pages
    // ---- profiles as files (another computer)
    func exportProfile(_ id: Int) {
        Task {
            guard let d = try? await Core.shared.raw("profiles.exportSummary", ["id": id]),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { toast(L("Couldn't read that profile")); return }
            profileSheet = ProfileSheetModel(mode: "export", info: o, profile: id)
        }
    }

    func importProfile() {
        let p = FolderPickerModel()
        p.files = ["noonix"]
        p.caption = L("Import a profile")
        p.picked = { [weak self] path in
            guard let self else { return }
            Task {
                do {
                    let d = try await Core.shared.raw("profiles.importPreview", ["path": path])
                    guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw CancellationError() }
                    let m = ProfileSheetModel(mode: "import", info: o)
                    m.imported = { [weak self] in
                        guard let self else { return }
                        Task { await self.loadProfiles(); await self.settings.load(app: self) }
                    }
                    self.profileSheet = m
                } catch let e as CoreError {
                    self.toast(Lc(e.message))
                } catch {
                    self.toast(L("Couldn't read that file"))
                }
            }
        }
        folderPicker = p
        p.go("", app: self)
    }

    /// pages built once (RootView keeps them): shown, or warmed while home sits idle
    var built: Set<Page> = [.home]

    /// the other pages load and build one by one after home, so a first visit has them (qml warmed)
    func warm() {
        warming?.cancel()
        warming = Task {
            for p in [Page.movies, .shows, .library, .search] {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                // not while a video plays or before a profile is picked
                while playing || picker != nil || setup != nil { try? await Task.sleep(for: .seconds(2)); if Task.isCancelled { return } }
                switch p {
                case .movies, .shows: await rails[p]?.load()
                case .library: await library.openLibrary()
                default: await search.popular()
                }
                built.insert(p)
            }
        }
    }
    @ObservationIgnored private var warming: Task<Void, Never>?

    func choose(_ p: Page) {
        built.insert(p)
        page = p
        navIndex = Page.allCases.firstIndex(of: p) ?? 1
        switch p {
        case .home, .movies, .shows: Task { await rails[p]?.load() }
        case .library: Task { await library.openLibrary() }
        case .search: Task { await search.popular() }
        case .settings: break
        }
    }

    func open(_ item: Item) {
        guard item.detailsTarget != nil else { return }
        detailStack.append(DetailsModel(item: item, app: self))
    }

    func back() {
        if !detailStack.isEmpty {
            detailStack.removeLast()
            detailStack.last?.reload()
        } else {
            navFocused = true
        }
    }

    // ---- playback: the finder looks for the best source unless one was picked
    var playTarget: PlayTarget?

    func play(_ t: PlayTarget, stream: [String: Any]? = nil) {
        playTarget = t
        let f = FinderModel(target: t)
        finder = f
        if let stream { begin(stream); return }
        Task {
            let req = "auto-\(Int(Date().timeIntervalSince1970 * 1000))"
            let data = try? await Core.shared.raw("streams.list", t.args(req: req))
            guard finder === f else { return }
            let list = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["streams"] as? [[String: Any]]) ?? []
            guard let first = list.first else {
                finder = nil
                openSources(t)
                return
            }
            begin(first)
        }
    }

    private func begin(_ stream: [String: Any]) {
        guard let t = playTarget else { return }
        finder?.starting(stream)
        playing = true
        Task { await player.play(t, stream: stream) }
    }

    /// the next episode the core found, straight on with its stream (no finder, no countdown)
    func playNext() {
        guard let n = player.next, let stream = n.raw["stream"] as? [String: Any], let cur = playTarget else { return }
        let t = PlayTarget(kind: "show", tmdb: (n.raw["tmdb"] as? NSNumber)?.intValue ?? cur.tmdb, season: n.season,
                           episode: n.episode, title: cur.title, episodeTitle: n.title, start: 0)
        playTarget = t
        Task { await player.play(t, stream: stream) }
    }

    func cancelFind() {
        finder = nil
        if playing { player.stop(); playing = false }
    }

    func openSources(_ t: PlayTarget) {
        sources = SourcesModel(target: t)
    }

    func stopPlayback() {
        player.stop()
        playing = false
        finder = nil
        for r in rails.values { r.refreshPersonal() }
        detailStack.last?.reload()
    }

    // ---- keys
    func key(_ k: Key) -> Bool {
        // the splash takes every key: straight to its way out
        if let s = splash { s.skip(); return true }
        // the cards over everything first: a key, a profile, the trakt code
        if entry.isOpen { return entry.key(k) }
        if let h = help { h.key(k, app: self); return true }
        if let f = folderPicker { f.key(k, app: self); return true }
        if let e = extSheet { e.key(k, app: self); return true }
        if let p = profileSheet { p.key(k, app: self); return true }
        if let p = profileEdit { return p.key(k) }
        if trakt != nil {
            if k == .back { closeTrakt(false) }
            return true
        }
        if let s = site {
            s.key(k, app: self)
            return true
        }
        if let s = setup {
            picker = nil
            return s.key(k, app: self)
        }
        if let p = picker {
            p.key(k, app: self)
            return true
        }
        if exitChoice != nil {
            exitKey(k)
            return true
        }
        // menu = the toast's undo first
        if k == .menu, !playing, triggerToast() { return true }
        if let m = menu {
            m.key(k, app: self)
            return true
        }
        if playing && tipChoice != nil { tipKey(k); return true }
        if playing && finder == nil { return Osd.shared?.key(k) ?? false }
        if k.media { return true }
        // home (the guide button, h): the home page from wherever the pages are
        if k == .home {
            if finder == nil, sources == nil { detailStack.removeAll(); choose(.home) }
            return true
        }
        if finder != nil {
            if k == .back { cancelFind() }
            return true
        }
        if let s = sources {
            if k == .back { sources = nil; return true }
            if let pick = s.key(k, app: self) { sources = nil; play(s.target, stream: pick) }
            return true
        }
        if let d = detailStack.last {
            if k == .back { back(); return true }
            d.key(k)
            return true
        }
        if navFocused { return navKey(k) }
        return pageKey(k)
    }

    private func navKey(_ k: Key) -> Bool {
        let tabs = Page.allCases
        if navIndex < 0 {
            switch k {
            case .right: navIndex = 0; choose(tabs[0])
            case .ok: openPicker()
            case .down: navIndex = Page.allCases.firstIndex(of: page) ?? 1; navFocused = false
            case .back: if page != .home { choose(.home) } else { exitChoice = 1 }
            default: break
            }
            return true
        }
        switch k {
        case .left where navIndex == 0 && currentProfile != nil:
            navIndex = -1
        case .left where navIndex > 0:
            navIndex -= 1
            choose(tabs[navIndex])
        case .right where navIndex < tabs.count - 1:
            navIndex += 1
            choose(tabs[navIndex])
        case .down, .ok:
            navFocused = false
        case .back:
            // back on the bar: home first, then leave?
            if page != .home { choose(.home) } else { exitChoice = 1 }
        default:
            return true
        }
        return true
    }

    private func pageKey(_ k: Key) -> Bool {
        switch page {
        case .home, .movies, .shows:
            guard let r = rails[page], let row = r.focusedRow else {
                if k == .up || k == .back { navFocused = true }
                return true
            }
            switch k {
            case .up: if r.current == 0 { navFocused = true } else { r.move(-1) }
            case .down: r.move(1)
            case .left: row.index = max(0, row.index - 1)
            case .right: row.index = min(max(0, row.items.count - 1), row.index + 1)
            case .ok: if let it = row.current { open(it) }
            case .menu: if let it = row.current { menu = CardMenu(item: it, row: row, at: focusedArt) }
            case .back: navFocused = true
            default: return false
            }
        case .library:
            if !library.libraryKey(k, app: self) { navFocused = true }
        case .search:
            if !search.key(k, app: self) { navFocused = true }
        case .settings:
            if !settings.key(k, app: self) { navFocused = true }
        }
        return true
    }
}

/// a grid of posters (library, search) with a focused cell
@MainActor @Observable
final class GridModel {
    var items: [Item] = []
    var index = 0
    var columns = 6
    var section = "watchlist"
    var loading = false
    // library: the tabs above the grid have the focus
    var head = true
    var headIndex = 0
    /// a library with videos opens on them, until a tab is picked
    var picked = false

    func load() async {
        loading = true
        items = (try? await Core.shared.call("library.list", ["section": section], as: LibraryList.self))?.items ?? []
        index = min(index, max(0, items.count - 1))
        loading = false
    }

    /// false: up from the first line or back (the owner takes the focus)
    func key(_ k: Key, app: AppModel) -> Bool {
        switch k {
        case .up:
            if index < columns { return false }
            index -= columns
        case .down: index = min(max(0, items.count - 1), index + columns)
        case .left: index = max(0, index - 1)
        case .right: index = min(max(0, items.count - 1), index + 1)
        case .ok: if items.indices.contains(index) { app.open(items[index]) }
        case .back: return false
        default: break
        }
        return true
    }
}

/// search (qml Search): results on the left, a right column with the query, suggestions and the
/// glass keyboard; the focus is in one of three zones
@MainActor @Observable
final class SearchModel {
    var query = ""
    var typing: Bool { query.trimmingCharacters(in: .whitespaces).count > 1 }
    var busy = false
    /// keys | suggestions | grid
    var zone = "keys"
    var suggestion = 0
    var trending: [Item] = []
    /// popular answered (placeholder posters until then)
    var popularKnown = false
    let grid = GridModel()
    let kb = KeyboardModel()
    @ObservationIgnored private var popularItems: [Item] = []
    /// up out of the page (into the top bar)
    @ObservationIgnored var upFromTop: () -> Void = {}

    init() {
        kb.enterLabel = L("search")
        kb.typed = { [weak self] t in self?.query += t }
        kb.special = { [weak self] n in
            guard let self else { return }
            switch n {
            case "backspace": if !query.isEmpty { query.removeLast() }
            case "clear": query = ""
            case "enter": if !grid.items.isEmpty { zone = "grid" }
            default: break
            }
        }
        kb.leave = { [weak self] d in
            guard let self else { return }
            if d == "up" {
                if !suggestions.isEmpty { zone = "suggestions"; suggestion = suggestions.count - 1 } else { upFromTop() }
            } else if d == "left", !grid.items.isEmpty {
                zone = "grid"
            }
        }
    }

    /// up to six titles: trending before typing, then the results' own
    var suggestions: [String] {
        var out: [String] = []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        for i in typing ? grid.items : trending {
            guard out.count < 6 else { break }
            if let t = i.title, !out.contains(t), t.lowercased() != q { out.append(t) }
        }
        return out
    }

    func popular() async {
        if popularItems.isEmpty {
            let movies = (try? await Core.shared.call("home.row", ["id": "popular-movie"], as: [Item].self)) ?? []
            let shows = (try? await Core.shared.call("home.row", ["id": "popular-tv"], as: [Item].self)) ?? []
            // shows and movies by turns, a show first
            var mix: [Item] = []
            for i in 0..<max(movies.count, shows.count) {
                if i < shows.count { mix.append(shows[i]) }
                if i < movies.count { mix.append(movies[i]) }
            }
            popularItems = mix
            popularKnown = true
        }
        if trending.isEmpty { trending = (try? await Core.shared.call("home.row", ["id": "trending-tv"], as: [Item].self)) ?? [] }
        if !typing { grid.items = popularItems }
    }

    func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count > 1 else { grid.items = popularItems; busy = false; return }
        busy = true
        let found = (try? await Core.shared.call("tmdb.search", ["query": q], as: [Item].self)) ?? []
        if q == query.trimmingCharacters(in: .whitespaces) {
            grid.items = found
            grid.index = 0
            busy = false
        }
    }

    func typed(_ t: Typed) {
        switch t {
        case .text(let s): query += s
        case .erase: if !query.isEmpty { query.removeLast() }
        case .submit: if !grid.items.isEmpty { zone = "grid" }
        }
    }
}

/// what a play button asks the sources for
struct PlayTarget: Identifiable, Hashable {
    var kind: String
    var tmdb: Int
    var season: Int?
    var episode: Int?
    var title: String
    var episodeTitle: String?
    /// seconds; nil = the saved point
    var start: Double?
    var id: String { "\(kind)\(tmdb)-\(season ?? 0)-\(episode ?? 0)" }

    func args(req: String) -> [String: Any] {
        var a: [String: Any] = ["req": req, "kind": kind, "tmdb": tmdb]
        if let season, let episode { a["season"] = season; a["episode"] = episode }
        return a
    }
}
