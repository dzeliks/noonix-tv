import AppKit
import SwiftUI

struct AddonState: Decodable, Hashable {
    var id: Int
    var name: String
    var state: String
    var count: Int
    var formatting: String?
}

/// every source for one title, ranked, filling in while the addons answer (qml Sources)
@MainActor @Observable
final class SourcesModel {
    enum Zone { case chips, torrents, advanced, copy, list }

    let target: PlayTarget
    var streams: [Source] = []
    var raw: [String: [String: Any]] = [:]
    var addons: [AddonState] = []
    var total = 0
    var hidden = 0
    /// torrents left out: not allowed (yet)
    var torrents = 0
    var torrentsAllowed: Bool?
    var done = false
    var only = ""
    var chip = 0
    var zone: Zone = .list
    var index = 0
    /// aiostreams' custom formatter for a manifest noonix tv can't read
    var showTemplate = false
    var template: (name: String, description: String)?
    var copied = false

    var shown: [Source] { only.isEmpty ? streams : streams.filter { $0.addon == only } }
    var unsupported: [AddonState] { addons.filter { $0.formatting == "unsupported" } }
    /// a source of the user's answered with torrents and they were never asked: ask once
    var askTorrents: Bool { torrents > 0 && torrentsAllowed == nil }
    @ObservationIgnored private var req = ""

    init(target: PlayTarget) {
        self.target = target
        Core.shared.on("streams", key: "sources") { [weak self] data in self?.apply(data) }
        start()
    }

    /// (again, once torrents were answered)
    func start() {
        req = "src-\(Int(Date().timeIntervalSince1970 * 1000))"
        streams = []; raw = [:]; addons = []; total = 0; hidden = 0; torrents = 0; done = false; only = ""; zone = .list; index = 0
        let r = req
        Task {
            if let data = try? await Core.shared.raw("streams.list", target.args(req: r)) { apply(data) } else { done = true }
        }
    }

    func askTorrentsNow(app: AppModel) {
        let h = SourcesHelpModel(topic: "torrent", asking: true)
        h.answered = { [weak self] yes in
            Task {
                _ = try? await Core.shared.raw("setup.torrents", ["on": yes])
                self?.start()
            }
        }
        app.help = h
    }

    private func apply(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (o["req"] as? String) == req else { return }
        var got: [Source] = []
        var raws: [String: [String: Any]] = [:]
        for d in o["streams"] as? [[String: Any]] ?? [] {
            guard let json = try? JSONSerialization.data(withJSONObject: d),
                  let s = try? JSONDecoder().decode(Source.self, from: json) else { continue }
            got.append(s)
            raws[s.id] = d
        }
        streams = got
        raw = raws
        if let a = o["addons"], let json = try? JSONSerialization.data(withJSONObject: a) {
            addons = (try? JSONDecoder().decode([AddonState].self, from: json)) ?? addons
        }
        total = (o["total"] as? Int) ?? got.count
        hidden = (o["hidden"] as? Int) ?? 0
        torrents = (o["torrents"] as? Int) ?? 0
        torrentsAllowed = o["torrentsAllowed"] as? Bool
        done = (o["done"] as? Bool) ?? false
        index = min(index, max(0, shown.count - 1))
    }

    /// a pick returns the stream as the core sent it
    func key(_ k: Key, app: AppModel) -> [String: Any]? {
        switch zone {
        case .chips:
            switch k {
            case .left: chip = max(0, chip - 1)
            case .right: chip = min(addons.count - 1, chip + 1)
            case .down: zone = askTorrents ? .torrents : unsupported.isEmpty ? .list : .advanced
            case .ok: toggleChip(chip)
            default: break
            }
        case .torrents:
            switch k {
            case .ok: askTorrentsNow(app: app)
            case .down: zone = unsupported.isEmpty ? .list : .advanced
            case .up: if addons.count > 1 { zone = .chips }
            default: break
            }
        case .advanced:
            switch k {
            case .ok: toggleTemplate()
            case .down: zone = showTemplate ? .copy : .list
            case .up: zone = askTorrents ? .torrents : addons.count > 1 ? .chips : .advanced
            default: break
            }
        case .copy:
            switch k {
            case .ok: copyTemplate()
            case .up: zone = .advanced
            case .down: zone = .list
            default: break
            }
        case .list:
            switch k {
            case .up:
                if index > 0 { index -= 1 }
                else if !unsupported.isEmpty { zone = showTemplate ? .copy : .advanced }
                else if askTorrents { zone = .torrents }
                else if addons.count > 1 { zone = .chips }
            case .down: index = min(max(0, shown.count - 1), index + 1)
            case .ok: return pick(index)
            default: break
            }
        }
        return nil
    }

    func toggleTemplate() {
        showTemplate.toggle()
        guard showTemplate, template == nil else { return }
        Task {
            if let d = try? await Core.shared.call("addons.formatter", [:], as: [String: String].self) {
                template = (d["name"] ?? "", d["description"] ?? "")
            }
        }
    }

    /// as the tv copies it: JSON.stringify(template, null, 2)
    func copyTemplate() {
        guard let t = template else { return }
        func q(_ v: String) -> String {
            (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("{\n  \"name\": \(q(t.name)),\n  \"description\": \(q(t.description))\n}", forType: .string)
        copied = true
    }

    func toggleChip(_ i: Int) {
        guard let a = addons[safe: i] else { return }
        only = only == a.name ? "" : a.name
        index = 0
        zone = .list
    }

    func pick(_ i: Int) -> [String: Any]? {
        // a torrent plays too once they're allowed (the core resolves it)
        guard let s = shown[safe: i], s.url != nil || s.infoHash != nil else { return nil }
        return raw[s.id]
    }
}

struct SourcesView: View {
    @Environment(AppModel.self) private var app
    let model: SourcesModel

    var body: some View {
        let u = app.u, W = app.size.width, H = app.size.height
        ZStack(alignment: .trailing) {
            // a click beside the panel closes it
            Color.black.opacity(0.001)
                .onTapGesture { app.sources = nil }
            VStack(alignment: .leading, spacing: 24 * u) {
                head(u: u)
                    .padding([.horizontal, .top], 56 * u)
                list(u: u)
            }
            .frame(width: W * 0.5, height: H - 80 * u, alignment: .top)
            .panelGlass(56 * u, u: u)
            .padding(40 * u)
        }
        .frame(width: W, height: H)
    }

    private func head(u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14 * u) {
            Text(L("Sources")).font(Theme.display(46 * u, .bold)).foregroundStyle(Theme.fg)
            Text(title).font(Theme.text(25 * u)).foregroundStyle(Theme.fg2).lineLimit(1)
            FlowLayout(spacing: 12 * u) {
                ForEach(Array(model.addons.enumerated()), id: \.offset) { i, a in
                    AddonChip(addon: a, on: model.only == a.name, focused: model.zone == .chips && model.chip == i, u: u)
                        .onContinuousHover { phase in
                            if case .active = phase, Input.pointerLive { model.zone = .chips; model.chip = i }
                        }
                        .onTapGesture { model.toggleChip(i) }
                }
            }
            if model.askTorrents { torrentAsk(u: u) }
            if !model.unsupported.isEmpty { unsupported(u: u) }
            if model.showTemplate { templateBox(u: u) }
        }
    }

    // torrents found, never decided: what they are, then yes or no
    private func torrentAsk(u: CGFloat) -> some View {
        HStack {
            Text(Ln("%n torrent source(s) hidden", model.torrents))
                .font(Theme.text(23 * u, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
            Spacer()
            GlassButton(text: L("Torrents?"), focused: model.zone == .torrents, u: u, height: 60 * u, flat: true)
                .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.zone = .torrents } }
                .onTapGesture { model.zone = .torrents; model.askTorrentsNow(app: app) }
        }
        .frame(height: 64 * u)
    }

    // a custom manifest whose stream text noonix tv can't read
    private func unsupported(u: CGFloat) -> some View {
        HStack {
            Text(L("Unsupported formatting") + "  ·  " + model.unsupported.map(\.name).joined(separator: ", "))
                .font(Theme.text(23 * u, .semibold)).foregroundStyle(Theme.cached).lineLimit(1)
            Spacer()
            GlassButton(text: L("Advanced"), focused: model.zone == .advanced, u: u, height: 60 * u, flat: true)
                .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.zone = .advanced } }
                .onTapGesture { model.zone = .advanced; model.toggleTemplate() }
        }
        .frame(height: 64 * u)
    }

    // the template to paste into aiostreams > formatter > custom
    private func templateBox(u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * u) {
            Text(L("In AIOStreams open Formatter, choose Custom and paste these as Name and Description. Noonix TV then reads every detail exactly."))
                .font(Theme.text(20 * u)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.template.map { $0.name + "\n" + $0.description } ?? "…")
                .font(.system(size: 17 * u, design: .monospaced)).foregroundStyle(Theme.fg)
                .lineLimit(6)
        }
        .padding(24 * u)
        .padding(.bottom, 96 * u - 24 * u)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 24 * u).fill(Color.black.opacity(0.35)) }
        .overlay(alignment: .bottomTrailing) {
            GlassButton(text: model.copied ? L("Copied") : L("Copy"), icon: "doc.on.doc", focused: model.zone == .copy, u: u, height: 56 * u, flat: true)
                .padding(18 * u)
                .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.zone = .copy } }
                .onTapGesture { model.zone = .copy; model.copyTemplate() }
        }
    }

    private var title: String {
        let t = model.target
        guard let s = t.season, let e = t.episode else { return t.title }
        return "\(t.title)  ·  S\(s) · E\(e)"
    }

    private func list(u: CGFloat) -> some View {
        let shown = model.shown
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10 * u) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                        SourceRow(s: s, focused: model.zone == .list && model.index == i, u: u)
                            .id(i)
                            .contentShape(.rect)
                            .onContinuousHover { phase in
                                if case .active = phase, Input.pointerLive { model.zone = .list; model.index = i }
                            }
                            .onTapGesture {
                                if let pick = model.pick(i) { app.sources = nil; app.play(model.target, stream: pick) }
                            }
                            .contextMenu {
                                Button(L("Open in Another Player")) {
                                    if let raw = s.url, let url = URL(string: raw) { HandOff.open(url) }
                                }
                            }
                    }
                    footer(u: u)
                }
                .padding(.bottom, 30 * u)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.index) { _, i in
                withAnimation(.easeOut(duration: 0.26)) { proxy.scrollTo(i, anchor: UnitPoint(x: 0, y: 0.4)) }
            }
        }
    }

    private func footer(u: CGFloat) -> some View {
        let text: String = {
            if !model.done { return L("Looking for more sources") }
            if model.streams.isEmpty && model.addons.isEmpty { return L("Nothing here yet: add a video folder or a source in Settings › Sources") }
            if model.streams.isEmpty && model.torrents == 0 { return L("No sources found") }
            var t = model.total > model.streams.count ? L("Best %1 of %2", model.streams.count, model.total) : ""
            func add(_ s: String) { t += (t.isEmpty ? "" : "  ·  ") + s }
            if model.hidden > model.torrents { add(L("%1 hidden (cam, 3D, too big, your hidden patterns)", model.hidden - model.torrents)) }
            if model.torrents > 0, model.torrentsAllowed == false { add(L("%1 torrents (off in Settings › Sources)", model.torrents)) }
            return t
        }()
        return HStack(spacing: 14 * u) {
            if !model.done { Spinner(size: 24 * u, color: Theme.fg3) }
            Text(text).font(Theme.text(20 * u)).foregroundStyle(Theme.fg3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80 * u)
    }
}

/// one addon: answering / count / error
private struct AddonChip: View {
    let addon: AddonState
    let on: Bool
    let focused: Bool
    let u: CGFloat

    var body: some View {
        HStack(spacing: 10 * u) {
            Text(addon.name + (addon.state == "loading" ? "" : "  " + (addon.state == "error" ? L("no answer") : String(addon.count))))
                .font(Theme.text(20 * u, .medium))
                .foregroundStyle(focused ? Theme.focusFg : on ? Theme.fg : Theme.fg2)
            if addon.state == "loading" { Spinner(size: 20 * u, color: focused ? Theme.focusFg : Theme.fg2) }
        }
        .padding(.horizontal, 16 * u)
        .frame(height: 44 * u)
        .background {
            Capsule().fill(focused ? Color.white : on ? Color.white.opacity(0.32)
                           : addon.state == "error" ? Color(red: 1, green: 0.3, blue: 0.35).opacity(0.22) : Color.white.opacity(0.1))
        }
        .overlay { if on && !focused { Capsule().stroke(.white, lineWidth: 2 * u) } }
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
        .contentShape(.capsule)
    }
}

/// rows of chips that wrap
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > 0 && x + d.width > w { x = 0; y += line + spacing; line = 0 }
            x += d.width + spacing
            line = max(line, d.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(w, widest), height: subviews.isEmpty ? 0 : y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let d = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + d.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += d.width + spacing
            line = max(line, d.height)
        }
    }
}

/// one source: resolution + hdr badges, the release name, its details, service and cache state
struct SourceRow: View {
    let s: Source
    let focused: Bool
    let u: CGFloat

    var body: some View {
        HStack(spacing: 16 * u) {
            HStack(spacing: 8 * u) {
                Badge(text: s.label, strong: true, onLight: focused, tint: focused ? Theme.accent : .white, u: u)
                ForEach(s.hdr.filter { $0 != "SDR" }, id: \.self) { Badge(text: $0, strong: false, onLight: focused, tint: .white, u: u) }
            }
            .frame(width: 210 * u, alignment: .leading)
            VStack(alignment: .leading, spacing: 6 * u) {
                Text(s.filename ?? s.title)
                    .font(Theme.text(23 * u, .medium))
                    .foregroundStyle(focused ? Theme.focusFg : Theme.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(s.detailLine)
                    .font(Theme.text(20 * u))
                    .foregroundStyle(focused ? Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.7) : Theme.fg3)
                    .lineLimit(1)
            }
            Spacer(minLength: 16 * u)
            HStack(spacing: 8 * u) {
                // may stutter here (above the picture quality level, few people sharing)
                if let w = s.warn {
                    Text(w == "level" ? L("May not play smoothly here") : w == "seeders" ? L("Few people sharing") : "")
                        .font(Theme.text(19 * u, .semibold))
                        .foregroundStyle(focused ? Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255) : Color(red: 1, green: 0xB3 / 255, blue: 0x40 / 255))
                }
                if let n = s.seeders, s.url == nil {
                    Text(L("%1 sharing", "\(n)")).font(Theme.text(20 * u, .semibold)).foregroundStyle(focused ? Theme.focusFg : Theme.fg2)
                }
                if let svc = s.service {
                    Text(svc).font(Theme.text(20 * u, .bold)).foregroundStyle(focused ? Theme.focusFg : Theme.fg2)
                }
                if let c = s.cached {
                    Image(systemName: c ? "bolt.fill" : "hourglass")
                        .font(.system(size: 22 * u, weight: .semibold))
                        .foregroundStyle(c ? (focused ? Color(red: 0xC7 / 255, green: 0x9A / 255, blue: 0) : Theme.cached)
                                         : (focused ? Theme.focusFg : Theme.fg3))
                        .frame(width: 30 * u, height: 30 * u)
                }
            }
        }
        .padding(.horizontal, 26 * u)
        .frame(height: 116 * u)
        .background { RoundedRectangle(cornerRadius: 26 * u).fill(focused ? Color.white : .clear) }
        .scaleEffect(focused ? 1.02 : 1)
        .animation(Theme.lift, value: focused)
        .padding(.horizontal, 28 * u)
    }
}

/// small spec tag: 4K, HDR10, DV, Atmos
struct Badge: View {
    let text: String
    let strong: Bool
    let onLight: Bool
    let tint: Color
    let u: CGFloat

    var body: some View {
        Text(text)
            .font(Theme.text(19 * u, .bold))
            .tracking(0.4 * u)
            .foregroundStyle(strong ? (onLight ? .white : Theme.focusFg) : (onLight ? Theme.focusFg : Theme.fg))
            .padding(.horizontal, 9 * u)
            .frame(height: 34 * u)
            .background {
                RoundedRectangle(cornerRadius: 8 * u)
                    .fill(strong ? tint : .clear)
                    .stroke(strong ? .clear : (onLight ? Color.black.opacity(0.45) : Color.white.opacity(0.5)), lineWidth: 1.6 * u)
            }
    }
}

/// "finding the best source": a glass card in the middle over the frosted page, up from the search
/// until the first video frame; back cancels (qml Finder)
@MainActor @Observable
final class FinderModel {
    let target: PlayTarget
    var details: Details?
    var status = L("Finding the best source…")
    var detail = ""

    init(target: PlayTarget) {
        self.target = target
        Task {
            details = try? await Core.shared.call("tmdb.details", ["kind": target.kind == "movie" ? "movie" : "show", "id": target.tmdb],
                                                  as: Details.self)
        }
    }

    /// what was picked, while it opens
    func starting(_ s: [String: Any]) {
        status = L("Starting")
        var bits: [String] = []
        let res = (s["resolution"] as? Int) ?? 0
        if res >= 2160 { bits.append(L("4K")) } else if res > 0 { bits.append("\(res)p") }
        let hdr = (s["hdr"] as? [String]) ?? []
        if hdr.contains("DV") { bits.append("Dolby Vision") } else if let h = hdr.first { bits.append(h) }
        if let src = s["source"] as? String { bits.append(src) }
        if let g = s["group"] as? String { bits.append(g) }
        detail = bits.joined(separator: "  ·  ")
    }
}

struct FinderView: View {
    @Environment(AppModel.self) private var app
    let model: FinderModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        let t = model.target
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.5) }
            VStack(spacing: 18 * u) {
                LogoBox(url: model.details?.item.logo, title: model.details?.item.title ?? t.title,
                        loading: model.details == nil, titleSize: 52 * u)
                    .frame(width: 440 * u, height: 120 * u)
                if t.kind != "movie", let s = t.season, let e = t.episode {
                    Text("S\(s) · E\(e)" + (t.episodeTitle.map { "  " + $0 } ?? ""))
                        .font(Theme.display(26 * u, .semibold)).foregroundStyle(Theme.fg2).lineLimit(1)
                }
                // qml: 14 and 6 spacer items around it, each with the column's 18 on both sides
                Spinner(size: 60 * u).padding(.top, 32 * u).padding(.bottom, 24 * u)
                Text(model.status).font(Theme.display(29 * u, .semibold)).foregroundStyle(Theme.fg)
                if !model.detail.isEmpty {
                    Text(model.detail).font(Theme.text(23 * u, .medium)).foregroundStyle(Theme.fg2).lineLimit(1)
                }
            }
            .padding(.horizontal, 64 * u)
            .padding(.vertical, 56 * u)
            .frame(width: 760 * u)
            .panelGlass(56 * u, u: u)
            .scaleEffect(shown ? 1 : 0.94)
        }
        .onAppear { withAnimation(Theme.lift) { shown = true } }
        // up until the first frame, or until it fails
        .onChange(of: app.player.state) {
            switch app.player.state {
            case .playing, .failed: app.finder = nil
            default: break
            }
        }
    }
}

/// a hand-off to another player app (a source's context menu)
enum HandOff {
    static func open(_ url: URL) {
        let ws = NSWorkspace.shared
        if ws.urlForApplication(withBundleIdentifier: "com.colliderli.iina") != nil,
           let iina = URL(string: "iina://weblink?url=" + (url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) {
            ws.open(iina)
            return
        }
        for id in ["io.mpv", "org.videolan.vlc"] {
            if let app = ws.urlForApplication(withBundleIdentifier: id) {
                ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        ws.open(url)
    }
}
