import SwiftUI

/// the dim behind a sheet: a click on it closes the sheet
private struct SheetFloor: View {
    let close: () -> Void
    var body: some View {
        Rectangle().fill(.ultraThinMaterial).overlay { Color.black.opacity(0.6) }
            .ignoresSafeArea()
            .onTapGesture(perform: close)
    }
}

/// one line of text (qml Marquee): elided at rest, scrolls through while active if it doesn't fit.
/// the second copy follows the first round, so the loop has no jump
struct Marquee: View {
    let text: String
    let font: Font
    let active: Bool
    let u: CGFloat
    @State private var box: CGFloat = 0
    @State private var natural: CGFloat = 0
    @State private var x: CGFloat = 0
    @State private var rolling = false

    var body: some View {
        let gap = 60 * u
        Text(text).font(font).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(rolling ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { box = $0 }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
            }
            .overlay(alignment: .leading) {
                if rolling {
                    HStack(spacing: gap) {
                        Text(text).font(font)
                        Text(text).font(font)
                    }
                    .fixedSize()
                    .offset(x: x)
                }
            }
            .clipped()
            .task(id: "\(text)|\(active)|\(Int(natural))|\(Int(box))") {
                x = 0
                rolling = active && natural > box + 1
                guard rolling else { return }
                let run = natural + gap
                // a steady reading pace, not a fixed time
                let secs = Double(run / (90 * u))
                while !Task.isCancelled {
                    guard (try? await Task.sleep(for: .seconds(1.2))) != nil else { return }
                    withAnimation(.linear(duration: secs)) { x = -run }
                    guard (try? await Task.sleep(for: .seconds(secs))) != nil else { return }
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { x = 0 }
                }
            }
    }
}

/// pick one of a few (qml Choices): a line that used to step through its values opens this
@MainActor @Observable
final class ChoicesModel {
    struct Option { let id: String; let label: String }
    let title: String
    let detail: String
    let options: [Option]
    let current: String
    let pick: (String) -> Void
    var index: Int

    init(title: String, detail: String, options: [Option], current: String, pick: @escaping (String) -> Void) {
        self.title = title
        self.detail = detail
        self.options = options
        self.current = current
        self.pick = pick
        index = max(0, options.firstIndex { $0.id == current } ?? 0)
    }

    func choose(_ i: Int, app: AppModel) {
        app.choices = nil
        pick(options[i].id)
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .up: index = max(0, index - 1)
        case .down: index = min(options.count - 1, index + 1)
        case .ok: choose(index, app: app)
        case .back: app.choices = nil
        default: break
        }
    }
}

struct ChoicesView: View {
    @Environment(AppModel.self) private var app
    let model: ChoicesModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        ZStack {
            SheetFloor { app.choices = nil }
            VStack(alignment: .leading, spacing: 8 * u) {
                Text(model.title).font(Theme.display(40 * u, .bold)).foregroundStyle(Theme.fg)
                if !model.detail.isEmpty {
                    Text(model.detail).font(Theme.text(24 * u)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 18 * u)
                }
                ForEach(Array(model.options.enumerated()), id: \.offset) { i, o in
                    let foc = model.index == i
                    HStack {
                        Text(o.label).font(Theme.display(29 * u, .semibold))
                        Spacer()
                        if o.id == model.current {
                            Image(systemName: "checkmark").font(.system(size: 24 * u, weight: .bold))
                        }
                    }
                    .foregroundStyle(foc ? Theme.focusFg : Theme.fg)
                    .padding(.horizontal, 30 * u)
                    .frame(height: 84 * u)
                    .background { RoundedRectangle(cornerRadius: 24 * u).fill(foc ? Color.white : .clear) }
                    .contentShape(.rect)
                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = i } }
                    .onTapGesture { model.choose(i, app: app) }
                }
            }
            .padding(48 * u)
            .frame(width: 860 * u, alignment: .leading)
            .panelGlass(60 * u, u: u)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }
}

/// one action's buttons (qml BindSheet): three slots, ok on one waits for the press that fills it
@MainActor @Observable
final class BindSheetModel {
    let side: String
    let action: String
    let title: String
    var slot = 0
    /// 0 the slots, 1 the buttons under them
    var zone = 0
    var choice = 0
    var waiting = -1

    init(side: String, action: String, title: String) {
        self.side = side
        self.action = action
        self.title = title
    }

    var bound: [String] { Bindings.shared.all[side]?[action] ?? [] }
    func name(_ x: String) -> String { side == "pad" ? Bindings.shared.padText(x) : Bindings.keyText(x) }

    func listen(_ i: Int) {
        slot = i
        waiting = i
        Bindings.shared.capture(side, action, slot: i) { [weak self] in self?.waiting = -1 }
    }

    func close(app: AppModel) {
        Bindings.shared.stopCapture()
        app.bindSheet = nil
    }

    func clearSlot(app: AppModel) {
        guard bound.indices.contains(slot) else { return }
        // the last one can't go: an action nobody can reach would lock you out
        if bound.count == 1, action == "OK" || action == "BACK" { app.toast(L("Select and Back always keep one")); return }
        Bindings.shared.clear(side, action, slot: slot)
    }

    func key(_ k: Key, app: AppModel) {
        if waiting >= 0 {
            if k == .back { Bindings.shared.stopCapture() }
            return
        }
        switch k {
        case .left: if zone == 0 { slot = max(0, slot - 1) } else { choice = max(0, choice - 1) }
        case .right: if zone == 0 { slot = min(2, slot + 1) } else { choice = min(1, choice + 1) }
        case .up: zone = 0
        case .down: zone = 1
        case .ok:
            if zone == 0 { listen(slot) } else if choice == 0 { close(app: app) } else { clearSlot(app: app) }
        case .back: close(app: app)
        default: break
        }
    }
}

struct BindSheetView: View {
    @Environment(AppModel.self) private var app
    let model: BindSheetModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        ZStack {
            SheetFloor { model.close(app: app) }
            VStack(alignment: .leading, spacing: 8 * u) {
                Text(model.title).font(Theme.display(40 * u, .bold)).foregroundStyle(Theme.fg)
                Text(model.waiting >= 0 ? (model.side == "pad" ? L("Press a button on the controller") : L("Press a key, Esc leaves it as it is"))
                                        : L("Up to three for this action"))
                    .font(Theme.text(24 * u)).foregroundStyle(Theme.fg2)
                    .padding(.bottom, 18 * u)
                HStack(spacing: 20 * u) {
                    ForEach(0..<3, id: \.self) { i in cell(i, u: u) }
                }
                HStack(spacing: 20 * u) {
                    GlassButton(text: L("Back"), icon: "arrow.left", focused: model.zone == 1 && model.choice == 0, u: u, flat: true)
                        .contentShape(.capsule)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.zone = 1; model.choice = 0 } }
                        .onTapGesture { model.close(app: app) }
                    GlassButton(text: L("Clear Slot %1", model.slot + 1), focused: model.zone == 1 && model.choice == 1, u: u, flat: true)
                        .contentShape(.capsule)
                        .opacity(model.bound.indices.contains(model.slot) ? 1 : 0.45)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.zone = 1; model.choice = 1 } }
                        .onTapGesture { model.clearSlot(app: app) }
                }
                .padding(.top, 30 * u)
            }
            .padding(48 * u)
            .frame(width: 1040 * u, alignment: .leading)
            .panelGlass(60 * u, u: u)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.22)) { shown = true } }
    }

    private func cell(_ i: Int, u: CGFloat) -> some View {
        let foc = model.zone == 0 && model.slot == i
        let wait = model.waiting == i
        let name = model.bound[safe: i].map(model.name)
        return VStack(spacing: 6 * u) {
            Text(wait ? L("Waiting…") : L("Slot %1", i + 1)).font(Theme.text(21 * u, .medium))
                .foregroundStyle(foc ? Theme.focusFg.opacity(0.7) : Theme.fg3)
            Text(name ?? "–").font(Theme.display(31 * u, .semibold)).lineLimit(1)
                .foregroundStyle(foc ? Theme.focusFg : name == nil ? Theme.fg3 : Theme.fg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150 * u)
        .background { RoundedRectangle(cornerRadius: 28 * u).fill(foc ? Color.white : Color.white.opacity(0.07)) }
        .overlay {
            if wait { RoundedRectangle(cornerRadius: 28 * u).stroke(Theme.cached, lineWidth: 4 * u) }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            if case .active = phase, Input.pointerLive, model.waiting < 0 { model.zone = 0; model.slot = i }
        }
        .onTapGesture { model.listen(i) }
    }
}

/// the speed check (qml SpeedCheck): internet, then this mac, each on a gauge cut into the picture
/// quality zones. what you can watch is the weaker of the two
@MainActor @Observable
final class SpeedCheckModel {
    struct Zone { let label: String; let from: Double; let to: Double; let color: Color }
    enum State: Equatable { case none, next, running, value(Double), failed(String), skipped }

    var levels: [[String: Any]] = []
    var net = State.none
    var dev = State.none
    var live = 0.0
    var liveDev = 0.0
    var choice = 1
    /// the first answer's in: the caller shows it
    @ObservationIgnored var measured: () -> Void = {}
    @ObservationIgnored private var generation = 0

    init() {
        Core.shared.on("bench", key: "speed") { [weak self] data in
            guard let self, self.net == .running,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let m = (d["mbps"] as? NSNumber)?.doubleValue else { return }
            self.live = m
        }
        Core.shared.on("benchDevice", key: "speed") { [weak self] data in
            guard let self, self.dev == .running,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = (d["score"] as? NSNumber)?.doubleValue else { return }
            self.liveDev = s
        }
    }

    private static let colors = [Color(red: 1, green: 0.48, blue: 0.42), Color(red: 1, green: 0.76, blue: 0.29),
                                 Color(red: 0.2, green: 0.84, blue: 0.51), Color(red: 0.39, green: 0.78, blue: 1)]
    private func zones(_ key: String, top: Double) -> [Zone] {
        let names = ["light": L("Light"), "hd": L("Full HD"), "4k": L("4K"), "max": L("Maximum")]
        return levels.enumerated().map { i, l in
            let id = l["id"] as? String ?? ""
            let next = levels[safe: i + 1].flatMap { ($0[key] as? NSNumber)?.doubleValue }
            return Zone(label: names[id] ?? id, from: (l[key] as? NSNumber)?.doubleValue ?? 0, to: next ?? top,
                        color: Self.colors[i % Self.colors.count])
        }
    }
    var netZones: [Zone] { zones("needMbps", top: 600) }
    var devZones: [Zone] { zones("needDevice", top: 120) }
    static func zone(_ zs: [Zone], _ v: Double) -> Int { zs.lastIndex { v >= $0.from } ?? -1 }

    private func number(_ s: State) -> Double? { if case .value(let v) = s { return v } else { return nil } }
    var netValue: Double? { number(net) }
    var devValue: Double? { number(dev) }
    var running: Bool { net == .running || dev == .running || dev == .next }
    var netZone: Int { netValue.map { Self.zone(netZones, $0) } ?? -1 }
    var devZone: Int { devValue.map { Self.zone(devZones, $0) } ?? -1 }
    var bothDone: Bool { netValue != nil && devValue != nil }
    var netFailed: Bool { if case .failed = net { return true }; return net == .skipped }

    var headline: String {
        if running { return "" }
        if bothDone { return netZones[safe: min(netZone, devZone)]?.label ?? "" }
        if netValue != nil { return netZones[safe: netZone]?.label ?? "" }
        if devValue != nil { return devZones[safe: devZone]?.label ?? "" }
        return ""
    }
    /// only said when it's worth knowing: without internet the device alone decides
    var why: String { !running && netFailed && devValue != nil ? L("No internet, so it follows the device") : "" }

    static func devText(_ fps: Double) -> String { L("%1 fps (4K HDR, 40 Mbit/s)", String(Int(fps.rounded()))) }

    private func json(_ m: String, _ args: [String: Any] = [:]) async -> [String: Any]? {
        guard let d = try? await Core.shared.raw(m, args) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    func open(auto: Bool, app: AppModel) {
        choice = 1
        app.speed = self
        Task {
            guard let d = await json("quality.options") else { return }
            levels = d["levels"] as? [[String: Any]] ?? []
            if net == .none, let m = (d["mbps"] as? NSNumber)?.doubleValue { net = .value(m) }
            if dev == .none, let s = (d["device"] as? NSNumber)?.doubleValue {
                dev = .value(s)
            }
            if auto { run() }
        }
    }

    func run() {
        guard !running else { return }
        generation += 1
        let request = generation
        live = 0
        liveDev = 0
        net = .running
        dev = .next
        // one after the other: the cpu test would slow the download down
        Task {
            let n = await json("bench.internet")
            guard request == generation else { return }
            if net != .skipped { net = (n?["mbps"] as? NSNumber).map { .value($0.doubleValue) } ?? .failed(L("No connection")) }
            dev = .running
            // the player decodes a 4k hdr clip the way it plays; no clip (no internet): the cpu test
            var args: [String: Any] = [:]
            if !netFailed, let path = await json("bench.sample")?["path"] as? String {
                let fps = await withCheckedContinuation { (done: CheckedContinuation<Double, Never>) in
                    DecodeBench.run(path) { [weak self] fps, finished in
                        if finished { done.resume(returning: fps) } else if self?.generation == request { self?.liveDev = fps }
                    }
                }
                if fps > 0 { args["fps"] = fps }
            }
            guard request == generation else { return }
            let d = await json("bench.device", args)
            guard request == generation else { return }
            dev = (d?["score"] as? NSNumber).map { .value($0.doubleValue) } ?? .failed(L("Couldn't measure"))
            measured()
        }
    }

    /// no internet worth waiting for: straight on to the device
    func skip() {
        guard net == .running else { return }
        net = .skipped
        Task { _ = await json("bench.skipInternet") }
    }

    /// skipping asks first: a guess at what plays here can pick a quality that doesn't
    func left(app: AppModel) {
        guard net == .running else { run(); return }
        app.confirm = ConfirmModel(
            title: L("Skip the internet check?"),
            detail: L("Without it the picture quality follows this device alone, so some videos may stutter or not play at all. You can set it yourself any time in Settings › Sources › Picture quality."),
            ok: L("Skip Anyway"), cancel: L("Keep Measuring"),
            yes: { [weak self] in self?.skip() })
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .left: choice = 0
        case .right: choice = 1
        case .ok: if choice == 0 { left(app: app) } else { app.speed = nil }
        case .back: app.speed = nil
        default: break
        }
    }
}

private struct GaugeArc: Shape {
    let from: Double
    let to: Double
    let centre: CGPoint
    let radius: CGFloat

    func path(in _: CGRect) -> Path {
        var p = Path()
        p.addArc(center: centre, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        return p
    }
}

/// a small white speedometer cut into the quality zones (qml Gauge). the needle glides after the
/// readings and the zone under it takes its colour; once both are in, only the weaker one keeps it
struct GaugeView: View {
    let title: String
    let zones: [SpeedCheckModel.Zone]
    let value: Double
    var measuring = false
    let measured: Bool
    var waiting = false
    var decided = false
    var chosen = false
    let number: String
    let unit: String
    var note = ""
    let u: CGFloat
    let width: CGFloat

    private let start = -210.0, sweep = 240.0, gap = 2.4
    private var zone: Int { measured ? SpeedCheckModel.zone(zones, value) : -1 }
    private var lit: Bool { decided ? chosen : true }
    private var pos: Double {
        guard measuring || measured, !zones.isEmpty else { return 0 }
        let n = Double(zones.count)
        guard let i = zones.lastIndex(where: { value >= $0.from }) else { return 0 }
        let z = zones[i]
        return min(1, (Double(i) + min(1, (value - z.from) / max(0.001, z.to - z.from))) / n)
    }
    private var under: Int { (measuring || measured) && pos > 0.002 ? min(zones.count - 1, Int(pos * Double(zones.count))) : -1 }

    var body: some View {
        let r = 104 * u, stroke = 9 * u
        let c = CGPoint(x: width / 2, y: 48 * u + r)
        let height = c.y + r * 0.5 + 72 * u
        let seg = zones.isEmpty ? sweep : sweep / Double(zones.count)
        ZStack(alignment: .topLeading) {
            Text(title).font(Theme.display(23 * u, .semibold)).foregroundStyle(Theme.fg2).frame(width: width)
            ForEach(Array(zones.enumerated()), id: \.offset) { i, z in
                let a = start + Double(i) * seg + gap * 2
                let on = under == i && lit, marked = under == i
                GaugeArc(from: a, to: a + seg - gap * 4, centre: c, radius: r)
                    .stroke(on ? z.color : .white.opacity(marked ? 0.85 : 0.16), style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .animation(.easeInOut(duration: 0.42), value: on)
                    .animation(.easeInOut(duration: 0.42), value: marked)
            }
            let len = r - 22 * u
            Capsule().fill(.white)
                .frame(width: 4 * u, height: len)
                .position(x: c.x, y: c.y - len / 2)
                .rotationEffect(.degrees(start + sweep * pos + 90), anchor: UnitPoint(x: c.x / width, y: c.y / height))
                .opacity(measuring || measured ? 1 : 0.4)
                .animation(.smooth(duration: 0.7), value: pos)
            Circle().fill(.white).frame(width: 14 * u, height: 14 * u).position(c)
            VStack(spacing: 0) {
                Text(number.isEmpty ? "–" : number)
                    .font(Theme.display(44 * u, .bold).monospacedDigit())
                    .foregroundStyle(number.isEmpty ? Theme.fg3 : Theme.fg)
                Text(unit).font(Theme.text(19 * u)).foregroundStyle(Theme.fg3)
                Text(!note.isEmpty ? note : zone >= 0 ? zones[zone].label : waiting ? L("Waiting") : measuring ? L("Measuring…") : " ")
                    .font(Theme.display(24 * u, zone >= 0 ? .bold : .medium))
                    .foregroundStyle(zone >= 0 && note.isEmpty ? (lit ? zones[zone].color : Theme.fg) : Theme.fg3)
                    // the chosen one reads a touch larger
                    .scaleEffect(decided && chosen ? 1.2 : 1)
                    .frame(height: 48 * u)
                    .animation(.easeOut(duration: 0.38), value: decided && chosen)
                    .animation(.easeInOut(duration: 0.42), value: lit)
            }
            .frame(width: width)
            .offset(y: c.y + 26 * u)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .opacity(waiting ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.3), value: waiting)
    }
}

struct SpeedCheckView: View {
    @Environment(AppModel.self) private var app
    let model: SpeedCheckModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        let gaugeW = (880 * u - 116 * u - 24 * u) / 2
        let live = model.net == .running, liveDev = model.dev == .running
        ZStack {
            SheetFloor { app.speed = nil }
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Speed check")).font(Theme.display(36 * u, .bold)).foregroundStyle(Theme.fg)
                HStack(spacing: 24 * u) {
                    GaugeView(title: L("Internet"), zones: model.netZones, value: model.netValue ?? model.live,
                              measuring: live, measured: model.netValue != nil,
                              decided: model.bothDone, chosen: model.netZone <= model.devZone,
                              number: model.netValue.map { String(Int($0.rounded())) } ?? (live && model.live > 0 ? String(Int(model.live)) : ""),
                              unit: L("Mbit/s"),
                              note: model.net == .skipped ? L("Skipped") : { if case .failed(let e) = model.net { return e } else { return "" } }(),
                              u: u, width: gaugeW)
                    GaugeView(title: L("Device"), zones: model.devZones, value: model.devValue ?? model.liveDev,
                              measuring: liveDev, measured: model.devValue != nil, waiting: model.dev == .next,
                              // without internet the device alone decides
                              decided: model.bothDone || (model.netFailed && model.devValue != nil),
                              chosen: model.netValue == nil || model.devZone <= model.netZone,
                              number: model.devValue.map { String(Int($0.rounded())) } ?? (liveDev && model.liveDev > 0 ? String(Int(model.liveDev)) : ""),
                              unit: L("fps · 4K HDR, 40 Mbit/s"), note: { if case .failed(let e) = model.dev { return e } else { return "" } }(), u: u, width: gaugeW)
                }
                .padding(.top, 26 * u)
                VStack(spacing: 6 * u) {
                    Text(model.headline.isEmpty ? " " : L("You can watch up to %1", model.headline))
                        .font(Theme.display(30 * u, .bold)).foregroundStyle(Theme.fg)
                    Text(model.why.isEmpty ? L("You can change the picture quality any time in Settings › Sources")
                         : model.net == .skipped ? L("Without the internet check it follows the device. Change it any time in Settings › Sources")
                         : L("No internet, so it follows the device. Change it any time in Settings › Sources"))
                        .font(Theme.text(19 * u)).foregroundStyle(Theme.fg3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 38 * u)
                .opacity(model.headline.isEmpty ? 0 : 1)
                .animation(.easeOut(duration: 0.32), value: model.headline.isEmpty)
                HStack(spacing: 20 * u) {
                    Spacer()
                    // while the internet is measured it can be skipped (no connection, or no patience)
                    GlassButton(text: live ? L("Skip") : L("Run Again"), focused: model.choice == 0, u: u, flat: true)
                        .contentShape(.capsule)
                        .opacity(model.running && !live ? 0.45 : 1)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.choice = 0 } }
                        .onTapGesture { model.left(app: app) }
                    GlassButton(text: L("Done"), primary: true, focused: model.choice == 1, u: u, flat: true)
                        .contentShape(.capsule)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.choice = 1 } }
                        .onTapGesture { app.speed = nil }
                }
                .padding(.top, 44 * u)
            }
            .padding(.horizontal, 58 * u)
            .padding(.vertical, 44 * u)
            .frame(width: 880 * u, alignment: .leading)
            .panelGlass(52 * u, u: u)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.24)) { shown = true } }
    }
}
