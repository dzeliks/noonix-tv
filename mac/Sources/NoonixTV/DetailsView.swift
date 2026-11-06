import SwiftUI

/// a details page (qml Details): its data and where the focus is
@MainActor @Observable
final class DetailsModel: Identifiable {
    enum Zone { case actions, seasons, episodes, more }

    let item: Item
    @ObservationIgnored weak var app: AppModel?
    var details: Details?
    var season: Season?
    var seasonNo = 1
    var inLibrary = false
    var libraryReady = false
    let scroll = PageScroll()
    /// where each part of the page starts
    @ObservationIgnored var zoneTops: [(Zone, CGFloat)] = []
    /// a key after the wheel: what has the focus if it's still in view, else the first thing in view
    func leaveMouse() -> Bool {
        guard let y = scroll.y else { return false }
        let seen = zoneTops.filter { $0.1 + 120 >= y && $0.1 + 120 <= y + scroll.height }
        let keep = seen.contains { $0.0 == zone }
        if !keep, let to = seen.first?.0 { zone = to }
        withAnimation(Theme.slide) { scroll.y = nil }
        return !keep
    }
    var zone: Zone = .actions
    /// the focus starts on play, back is left of it
    var action = 1
    var seasonIndex = 0
    var episodeIndex = 0
    let more = RowModel(Row(id: "more", title: L("More Like This"), style: "poster"))

    var isMovie: Bool { item.kind == "movie" }
    var tmdbId: Int { item.kind == "episode" ? item.show ?? 0 : item.tmdb ?? 0 }
    var kind: String { isMovie ? "movie" : "show" }

    init(item: Item, app: AppModel) {
        self.item = item
        self.app = app
        details = AppModel.key(item).flatMap { app.heroCache[$0] }
        reload()
    }

    func reload() {
        Task {
            if let d = try? await Core.shared.call("tmdb.details", ["kind": kind, "id": tmdbId], as: Details.self) {
                details = d
                more.items = d.more ?? []
                more.loaded = true
                if !isMovie {
                    let t = playTarget
                    await loadSeason(t.season ?? d.seasons?.first(where: { $0.number > 0 })?.number ?? 1)
                }
            }
            let st = try? await Core.shared.call("library.state", ["kind": kind, "tmdb": tmdbId], as: [String: Bool].self)
            inLibrary = st?["inLibrary"] ?? false
            libraryReady = st != nil
        }
    }

    func loadSeason(_ n: Int) async {
        seasonNo = n
        guard let s = try? await Core.shared.call("tmdb.season", ["show": tmdbId, "season": n], as: Season.self), n == seasonNo else { return }
        season = s
        let t = playTarget
        if let i = s.episodes.firstIndex(where: { $0.season == t.season && $0.episode == t.episode }) { episodeIndex = i } else { episodeIndex = 0 }
    }

    /// an episode row item plays itself, else the show's next one (or S1 E1)
    var playTarget: PlayTarget {
        let title = details?.item.title ?? item.showTitle ?? item.title ?? ""
        if isMovie { return PlayTarget(kind: "movie", tmdb: tmdbId, title: title) }
        let n = details?.next
        if item.kind == "episode", let s = item.season, let e = item.episode {
            // the episode we came for got watched meanwhile: go on from it
            let eps = season?.episodes ?? []
            if let i = eps.firstIndex(where: { $0.season == s && $0.episode == e && $0.watched == true }) {
                if let n, n.season > s || (n.season == s && n.episode > e) {
                    return PlayTarget(kind: "show", tmdb: tmdbId, season: n.season, episode: n.episode, title: title)
                }
                if let x = eps[safe: i + 1], let xe = x.episode {
                    return PlayTarget(kind: "show", tmdb: tmdbId, season: x.season ?? s, episode: xe, title: title, episodeTitle: x.episodeTitle)
                }
            }
            return PlayTarget(kind: "show", tmdb: tmdbId, season: s, episode: e, title: title, episodeTitle: item.episodeTitle)
        }
        return PlayTarget(kind: "show", tmdb: tmdbId, season: n?.season ?? 1, episode: n?.episode ?? 1, title: title)
    }

    /// the episode the story talks about: the one in focus in the row, else the one continue plays
    var episodeShown: Item? {
        let eps = season?.episodes ?? []
        if zone == .episodes, let e = eps[safe: episodeIndex] { return e }
        guard item.kind == "episode" else { return nil }
        let t = playTarget
        return eps.first { $0.season == t.season && $0.episode == t.episode }
    }

    var startOver: Bool { isMovie && (details?.item.position ?? 0) > 60 }

    enum Action { case back, play, over, sources, library }
    var actions: [Action] { startOver ? [.back, .play, .over, .sources, .library] : [.back, .play, .sources, .library] }

    var playLabel: String {
        guard details != nil else { return L("Play") }
        if isMovie { return startOver ? L("Resume") : L("Play") }
        let t = playTarget
        return (t.season == 1 && t.episode == 1 ? L("Play") : L("Continue")) + "  S\(t.season ?? 1) E\(t.episode ?? 1)"
    }

    var seasons: [SeasonInfo] { details?.seasons ?? [] }
    var hasSeasons: Bool { !isMovie && !seasons.isEmpty }

    func act(_ a: Action) {
        guard let app else { return }
        switch a {
        case .back: app.back()
        case .play: app.play(playTarget)
        case .over:
            var t = playTarget
            t.start = 0
            app.play(t)
        case .sources: app.openSources(playTarget)
        case .library: toggleLibrary()
        }
    }

    var libraryBusy = false

    func toggleLibrary() {
        if libraryBusy { return }
        guard libraryReady else { reloadLibrary(); return }
        let want = !inLibrary
        libraryBusy = true
        Task {
            let ok = (try? await Core.shared.raw("library.set", ["kind": kind, "tmdb": tmdbId, "on": want])) != nil
            libraryBusy = false
            if ok { inLibrary = want } else { app?.toast(L("Couldn't update Library. Try again.")) }
        }
    }

    func reloadLibrary() {
        Task {
            let st = try? await Core.shared.call("library.state", ["kind": kind, "tmdb": tmdbId], as: [String: Bool].self)
            inLibrary = st?["inLibrary"] ?? false
            libraryReady = st != nil
        }
    }

    func playEpisode(_ i: Int) {
        guard let eps = season?.episodes, eps.indices.contains(i), let e = eps[i].episode else { return }
        app?.play(PlayTarget(kind: "show", tmdb: tmdbId, season: eps[i].season ?? seasonNo, episode: e,
                             title: details?.item.title ?? "", episodeTitle: eps[i].episodeTitle))
    }

    func key(_ k: Key) {
        switch zone {
        case .actions:
            switch k {
            case .left: action = max(0, action - 1)
            case .right: action = min(actions.count - 1, action + 1)
            case .ok: act(actions[min(action, actions.count - 1)])
            case .down:
                if hasSeasons { focusSeasons(); zone = .seasons } else if !more.items.isEmpty { zone = .more }
            default: break
            }
        case .seasons:
            switch k {
            case .left: seasonIndex = max(0, seasonIndex - 1)
            case .right: seasonIndex = min(seasons.count - 1, seasonIndex + 1)
            case .ok: Task { await loadSeason(seasons[seasonIndex].number) }
            case .up: zone = .actions
            case .down: zone = .episodes
            default: break
            }
        case .episodes:
            let n = season?.episodes.count ?? 0
            switch k {
            case .left: episodeIndex = max(0, episodeIndex - 1)
            case .right: episodeIndex = min(max(0, n - 1), episodeIndex + 1)
            case .ok: playEpisode(episodeIndex)
            case .menu:
                if let e = season?.episodes[safe: episodeIndex], let ep = e.episode {
                    app?.openSources(PlayTarget(kind: "show", tmdb: tmdbId, season: e.season ?? seasonNo, episode: ep,
                                                title: details?.item.title ?? "", episodeTitle: e.episodeTitle))
                }
            case .up: focusSeasons(); zone = .seasons
            case .down: if !more.items.isEmpty { zone = .more }
            default: break
            }
        case .more:
            switch k {
            case .left: more.index = max(0, more.index - 1)
            case .right: more.index = min(max(0, more.items.count - 1), more.index + 1)
            case .ok: if let it = more.current { app?.open(it) }
            case .menu: if let it = more.current { app?.menu = CardMenu(item: it, row: nil, at: app?.focusedArt) }
            case .up: zone = hasSeasons ? .episodes : .actions
            default: break
            }
        }
    }

    func focusSeasons() {
        seasonIndex = seasons.firstIndex(where: { $0.number == seasonNo }) ?? 0
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct DetailsView: View {
    @Environment(AppModel.self) private var app
    let model: DetailsModel
    @State private var infoH: CGFloat = 0
    @State private var heldY: CGFloat?
    @State private var plotSpare: CGFloat = 0

    var body: some View {
        let u = app.u, W = app.size.width, H = app.size.height
        let margin = Theme.margin(u)
        let sp = 34 * u
        let shows = model.hasSeasons
        let episodesH = 400 * u * 9 / 16 + 150 * u
        let top = !shows ? H * 0.2 : max(60 * u, H - 44 * u - (infoH + 90 * u + 60 * u + (400 * 9 / 16 + 92) * u + 4 * sp))
        let yActions = top + sp + infoH + sp
        let ySeasons = yActions + 90 * u + sp
        let yEpisodes = ySeasons + 60 * u + sp
        let yMore = shows ? yEpisodes + episodesH + sp : yActions + 90 * u + sp
        let yFor = { (z: DetailsModel.Zone) -> CGFloat in
            switch z {
            // buttons, seasons and episodes keep the page as it opened: episodes the bottom row, the whole story above
            case .actions, .seasons, .episodes: 0
            case .more: max(0, yMore - H * 0.3)
            }
        }
        // the pointer moving the focus doesn't scroll the page (the wheel does)
        let contentY = model.scroll.y ?? heldY ?? yFor(model.zone)
        let d = model.details

        ZStack(alignment: .topLeading) {
            // the artwork and its shading
            ZStack(alignment: .bottom) {
                Backdrop(url: d?.item.backdrop ?? model.item.backdrop)
                LinearGradient(stops: [.init(color: .black.opacity(0.88), location: 0),
                                       .init(color: .black.opacity(0.5), location: 0.55),
                                       .init(color: .black.opacity(0.15), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                       .init(color: .black.opacity(0.9), location: 0.6),
                                       .init(color: .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: H * 0.55)
            }
            .frame(width: W, height: H)

            VStack(alignment: .leading, spacing: sp) {
                Color.clear.frame(width: 1, height: top)
                info(u: u, W: W, margin: margin)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { infoH = $0 }
                actions(u: u, margin: margin)
                if shows {
                    seasonPills(u: u, margin: margin)
                    episodes(u: u, W: W, height: episodesH)
                }
                if !model.more.items.isEmpty {
                    MediaRowView(model: model.more, active: app.sources == nil && model.zone == .more, u: u, width: W,
                                 point: { i in model.zone = .more; model.more.index = i },
                                 activate: { i in if let it = model.more.items[safe: i] { app.open(it) } })
                }
                Color.clear.frame(width: 1, height: 80 * u)
            }
            .geometryGroup()
            .offset(y: -contentY)
            .animation(model.scroll.y == nil ? Theme.slide : nil, value: contentY)
        }
        .onChange(of: model.zone) { old, _ in heldY = Input.pointerHolds ? heldY ?? yFor(old) : nil }
        .onChange(of: PointerMode.shared.on) { _, on in if !on { heldY = nil } }
        .onChange(of: yFor(.more) + (heldY ?? yFor(model.zone)), initial: true) {
            model.scroll.start = heldY ?? yFor(model.zone)
            model.zoneTops = (shows ? [(DetailsModel.Zone.actions, yActions), (.seasons, ySeasons), (.episodes, yEpisodes)] : [(.actions, yActions)])
                + (model.more.items.isEmpty ? [] : [(.more, yMore)])
            model.scroll.height = H
            model.scroll.end = model.more.items.isEmpty ? yFor(shows ? .episodes : .actions) : max(0, yMore + MediaRowView.height("poster", u: u) + 80 * u - H)
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
        .background(Color.black)
    }

    // identity on the left, the story on the right (room for the whole plot)
    private func info(u: CGFloat, W: CGFloat, margin: CGFloat) -> some View {
        let d = model.details
        let ep = model.episodeShown
        let meta: Item? = d.map { dd in
            var it = dd.item
            if model.isMovie, let p = dd.item.position { it.position = p; it.duration = dd.item.duration }
            return it
        }
        return HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 20 * u) {
                LogoBox(url: d?.item.logo, title: d?.item.title ?? model.item.showTitle ?? model.item.title ?? "",
                        loading: d == nil, titleSize: 72 * u)
                    .frame(width: 600 * u, height: 210 * u)
                    // room under the logo: a tall one doesn't sit on the line below
                    .padding(.bottom, 16 * u)
                MetaLine(item: meta, details: d, u: u)
            }
            .frame(width: W * 0.44, alignment: .leading)
            .padding(.leading, margin)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14 * u) {
                if let ep, let s = ep.season, let e = ep.episode {
                    Text(L("Season %1, Episode %2", s, e) + (ep.episodeTitle.map { "  ·  " + $0 } ?? ""))
                        .font(Theme.display(26 * u, .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                } else if let t = d?.tagline, !t.isEmpty {
                    Text(t).font(Theme.display(26 * u, .semibold)).foregroundStyle(Theme.fg)
                } else if !model.isMovie {
                    Text(" ").font(Theme.display(26 * u, .semibold))
                }
                PlotBox(text: (ep?.overview).flatMap { $0.isEmpty ? nil : $0 } ?? d?.item.overview ?? "", u: u, spare: $plotSpare)
                let cast = (d?.cast ?? []).prefix(4).compactMap(\.name)
                if !cast.isEmpty {
                    Text(L("Starring %1", cast.joined(separator: ", "))).font(Theme.text(21 * u)).foregroundStyle(Theme.fg2).lineLimit(1)
                }
                let facts = factsLine(d)
                if !facts.isEmpty {
                    Text(facts).font(Theme.text(21 * u, .medium)).foregroundStyle(Theme.fg2).lineLimit(1)
                }
            }
            .frame(width: W * 0.36, alignment: .leading)
            .background(alignment: .topLeading) { StoryScrim(u: u, margin: margin, extra: plotSpare) }
            .padding(.trailing, margin)
        }
        .frame(width: W)
    }

    private func factsLine(_ d: Details?) -> String {
        guard let d else { return "" }
        var f: [String] = []
        if let n = d.network { f.append(n) }
        if let s = d.seasons, !s.isEmpty { f.append(Ln("%n season(s)", s.count)) }
        if let a = d.nextAir?.airDate { f.append(L("New episode %1", Theme.day(a))) }
        else if let s = d.status, s != "Released", s != "Returning Series" { f.append(Lc(s)) }
        return f.joined(separator: "  ·  ")
    }

    private func actions(u: CGFloat, margin: CGFloat) -> some View {
        let acts = model.actions
        return GlassEffectContainer(spacing: 26 * u) {
            HStack(spacing: 26 * u) {
                ForEach(Array(acts.enumerated()), id: \.offset) { i, a in
                    // the sources sheet over the page has the focus (qml: nothing here is lit then)
                    let focused = app.sources == nil && model.zone == .actions && min(model.action, acts.count - 1) == i
                    GlassButton(text: label(a), icon: icon(a), focused: focused, u: u)
                        .opacity(a == .library && (!model.libraryReady || model.libraryBusy) ? 0.5 : 1)
                        .onContinuousHover { phase in
                            if case .active = phase, Input.pointerLive { model.zone = .actions; model.action = i }
                        }
                        .onTapGesture { model.zone = .actions; model.action = i; model.act(a) }
                }
            }
        }
        .frame(height: 90 * u)
        .padding(.leading, margin)
    }

    private func label(_ a: DetailsModel.Action) -> String {
        switch a {
        case .back: L("Back")
        case .play: model.playLabel
        case .over: L("Start Over")
        case .sources: L("Sources")
        case .library: L("Library")
        }
    }

    private func icon(_ a: DetailsModel.Action) -> String {
        switch a {
        case .back: "arrow.left"
        case .play: "play.fill"
        case .over: "gobackward.10"
        case .sources: "list.bullet"
        case .library: model.inLibrary ? "checkmark" : "plus"
        }
    }

    // seasons: text pills
    private func seasonPills(u: CGFloat, margin: CGFloat) -> some View {
        // a row that scrolls (qml ListView): a long show keeps its pills whole
        ScrollViewReader { proxy in
        ScrollView(.horizontal) {
        HStack(spacing: 16 * u) {
            ForEach(Array(model.seasons.enumerated()), id: \.offset) { i, s in
                let sel = s.number == model.seasonNo
                let foc = app.sources == nil && model.zone == .seasons && model.seasonIndex == i
                Text(s.name.map { $0.hasPrefix("Season ") && Int($0.dropFirst(7)) != nil } == false ? s.name! : L("Season %1", s.number))
                    .font(Theme.display(25 * u, .semibold))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(foc ? Theme.focusFg : sel ? Theme.fg : Theme.fg2)
                    .padding(.horizontal, 22 * u)
                    .frame(height: 56 * u)
                    .background { Capsule().fill(foc ? Color.white : sel ? Color.white.opacity(0.22) : .clear) }
                    .contentShape(.capsule)
                    .onContinuousHover { phase in
                        if case .active = phase, Input.pointerLive { model.zone = .seasons; model.seasonIndex = i }
                    }
                    .onTapGesture { model.seasonIndex = i; Task { await model.loadSeason(s.number) } }
                    .id(i)
            }
        }
        .frame(height: 60 * u)
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollIndicators(.never)
        .onChange(of: model.seasonIndex) { _, i in if !Input.pointerHolds { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(i) } } }
        }
        .animation(.easeOut(duration: 0.14), value: model.seasonIndex)
    }

    private func episodes(u: CGFloat, W: CGFloat, height: CGFloat) -> some View {
        let eps = model.season?.episodes ?? []
        return CardStrip(items: eps, style: "episode", index: model.episodeIndex, focused: app.sources == nil && model.zone == .episodes, u: u, width: W,
                         restSlot: 1, spacing: 44 * u,
                         labels: { e in
                             let n = e.episode ?? 0
                             let sub = [e.runtime.map { Theme.runtime($0) }, Theme.airDate(e.airDate)].compactMap { $0 }.filter { !$0.isEmpty }
                             return ("\(n).  " + (e.episodeTitle ?? L("Episode %1", n)), sub.joined(separator: "  ·  "))
                         },
                         badge: { $0.watched == true },
                         point: { i in model.zone = .episodes; model.episodeIndex = i },
                         activate: { i in model.playEpisode(i) })
            .frame(height: height, alignment: .top)
    }
}

/// a tvos button (qml GlassButton): liquid glass at rest, white and lifted when focused
/// a plot in a box of at most seven lines, sitting on the line below it and growing up. a longer
/// plot scrolls slowly inside it and comes back
struct PlotBox: View {
    let text: String
    let u: CGFloat
    /// the room left under seven lines (the scrim keeps its size with it)
    @Binding var spare: CGFloat
    @State private var tall: CGFloat = 0
    @State private var seven: CGFloat = 0
    @State private var y: CGFloat = 0

    private func line(_ t: String) -> some View {
        Text(t).font(Theme.text(24 * u)).lineSpacing(24 * u * 0.19).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        let pad = 14 * u
        let full = seven + 2 * pad, need = tall + 2 * pad
        let h = min(need, full)
        let over = max(0, need - h)
        line(text)
            .foregroundStyle(Theme.fg.opacity(0.86))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tall = $0 }
            .padding(.vertical, pad)
            .offset(y: y)
            .frame(height: h, alignment: .top)
            .clipped()
            .mask {
                let e = over > 1 ? min(0.5, pad / max(1, h)) : 0
                LinearGradient(stops: [.init(color: e > 0 ? .clear : .black, location: 0), .init(color: .black, location: e),
                                       .init(color: .black, location: 1 - e), .init(color: e > 0 ? .clear : .black, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .background(alignment: .topLeading) {
                line("x\nx\nx\nx\nx\nx\nx").hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { seven = $0 }
            }
            .padding(.vertical, -pad)
            .onChange(of: full - h, initial: true) { _, v in spare = max(0, v) }
            .task(id: "\(text)|\(Int(over))") {
                y = 0
                guard over > 1 else { return }
                let down = Double(over / u) * 0.055
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: .seconds(4.5))) != nil else { return }
                    withAnimation(.easeInOut(duration: down)) { y = -over }
                    guard (try? await Task.sleep(for: .seconds(down + 3))) != nil else { return }
                    withAnimation(.easeInOut(duration: 0.8)) { y = 0 }
                    guard (try? await Task.sleep(for: .seconds(0.8))) != nil else { return }
                }
            }
    }
}

struct GlassButton: View {
    let text: String
    var icon: String?
    var primary = false
    let focused: Bool
    let u: CGFloat
    var height: CGFloat?
    /// a flat fill at rest instead of the glass (qml glass: false, setup's buttons)
    var flat = false
    /// a set width (the prompts' button pairs) instead of hugging the label
    var width: CGFloat?

    var body: some View {
        let h = height ?? 76 * u
        HStack(spacing: 14 * u) {
            if icon == "tv.subtitles" {
                SubtitlesGlyph().stroke(style: StrokeStyle(lineWidth: 2.2 * 34 * u / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 34 * u, height: 34 * u)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 26 * u, weight: .semibold))
                    .frame(width: 34 * u, height: 34 * u)
                    .contentTransition(.symbolEffect(.replace))
            }
            if !text.isEmpty {
                Text(text).font(Theme.display(27 * u, .semibold)).lineLimit(1).fixedSize()
            }
        }
        .foregroundStyle(focused ? Theme.focusFg : Theme.fg)
        // qml: the label + 64, + 44 more with an icon (icon 34 + gap 14 leaves 30 a side)
        .padding(.horizontal, text.isEmpty ? 0 : icon == nil ? 32 * u : 30 * u)
        .frame(minWidth: h, minHeight: h, maxHeight: h)
        .frame(width: width)
        // the glass stays: the white fades in over it (swapping the glass out pops)
        .background {
            ZStack {
                if flat { Capsule().fill(Color.white.opacity(primary ? 0.24 : 0.14)) }
                Capsule().fill(Color.white).opacity(focused ? 1 : 0)
            }
        }
        .overlay { GlassRim(shape: Capsule(), u: u, glint: false).opacity(focused ? 0 : 1) }
        .animation(.easeOut(duration: 0.16), value: focused)
        // the lift inside the glass: the white grows over it and covers it whole
        .scaleEffect(focused ? 1.08 : 1)
        .animation(Theme.lift, value: focused)
        .glassEffect(flat ? .identity : .regular.tint(.white.opacity(primary ? 0.2 : 0.12)), in: .capsule)
        .contentShape(.capsule)
        .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 18 * u, y: 14 * u)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// the tv's subtitles symbol (qml Symbol "subtitles"): a box with two lines of captions; sf has
/// none without a speech bubble
struct SubtitlesGlyph: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var path = Path()
        path.addLines([p(3.5, 5.5), p(20.5, 5.5), p(20.5, 18.5), p(3.5, 18.5)])
        path.closeSubpath()
        for (a, b) in [((6.5, 14.5), (11, 14.5)), ((13, 14.5), (17.5, 14.5)), ((6.5, 11), (9, 11)), ((11, 11), (17.5, 11))] {
            path.move(to: p(a.0, a.1)); path.addLine(to: p(b.0, b.1))
        }
        return path
    }
}

/// a round glass back arrow (pointer only): white under the pointer, like a focused button
/// a round glass button for the pointer (qml RoundButton): a row's page arrows
struct RoundButton: View {
    var icon = "chevron.left"
    let u: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 26 * u, weight: .semibold))
            .foregroundStyle(hover ? Theme.focusFg : Theme.fg)
            .offset(x: (icon == "chevron.left" ? -2 : icon == "chevron.right" ? 2 : 0) * u)
            .frame(width: 64 * u, height: 64 * u)
            .background { Circle().fill(Color.white).opacity(hover ? 1 : 0) }
            .overlay { GlassRim(shape: Circle(), u: u, glint: false).opacity(hover ? 0 : 1) }
            .animation(.easeOut(duration: 0.16), value: hover)
            .scaleEffect(hover ? 1.08 : 1)
            .animation(Theme.lift, value: hover)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: .circle)
            .contentShape(.circle)
            .onContinuousHover { phase in
                if case .active = phase { hover = true } else { hover = false }
            }
            .onTapGesture(perform: action)
    }
}
