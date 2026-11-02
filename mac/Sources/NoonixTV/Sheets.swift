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
    enum State: Equatable { case none, next, running, value(Double), failed(String) }

    var levels: [[String: Any]] = []
    var net = State.none
    var dev = State.none
    var live = 0.0
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
    var devZones: [Zone] { zones("needDevice", top: 130) }
    static func zone(_ zs: [Zone], _ v: Double) -> Int { zs.lastIndex { v >= $0.from } ?? -1 }

    private func number(_ s: State) -> Double? { if case .value(let v) = s { return v } else { return nil } }
    var netValue: Double? { number(net) }
    var devValue: Double? { number(dev) }
    var running: Bool { net == .running || dev == .running || dev == .next }
    var netZone: Int { netValue.map { Self.zone(netZones, $0) } ?? -1 }
    var devZone: Int { devValue.map { Self.zone(devZones, $0) } ?? -1 }
    var bothDone: Bool { netValue != nil && devValue != nil }

    var headline: String {
        if running { return "" }
        if bothDone { return netZones[safe: min(netZone, devZone)]?.label ?? "" }
        if netValue != nil { return netZones[safe: netZone]?.label ?? "" }
        if devValue != nil { return devZones[safe: devZone]?.label ?? "" }
        return ""
    }
    var why: String {
        if running { return "" }
        if bothDone {
            return netZone < devZone ? L("Your internet is the weaker of the two")
                : devZone < netZone ? L("This Mac is the weaker of the two") : L("Both reach the same zone")
        }
        return netValue != nil || devValue != nil ? L("Only one of the two could be measured") : ""
    }

    private func json(_ m: String) async -> [String: Any]? {
        guard let d = try? await Core.shared.raw(m, [:]) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    func open(auto: Bool, app: AppModel) {
        choice = 1
        app.speed = self
        Task {
            guard let d = await json("quality.options") else { return }
            levels = d["levels"] as? [[String: Any]] ?? []
            if net == .none, let m = (d["mbps"] as? NSNumber)?.doubleValue { net = .value(m) }
            if dev == .none, let s = (d["device"] as? NSNumber)?.doubleValue { dev = .value(s) }
            if auto { run() }
        }
    }

    func run() {
        guard !running else { return }
        generation += 1
        let request = generation
        live = 0
        net = .running
        dev = .next
        // one after the other: the cpu test would slow the download down
        Task {
            let n = await json("bench.internet")
            guard request == generation else { return }
            net = (n?["mbps"] as? NSNumber).map { .value($0.doubleValue) } ?? .failed(L("Couldn't measure"))
            dev = .running
            let d = await json("bench.device")
            guard request == generation else { return }
            dev = (d?["score"] as? NSNumber).map { .value($0.doubleValue) } ?? .failed(L("Couldn't measure"))
            measured()
        }
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .left: choice = 0
        case .right: choice = 1
        case .ok: if choice == 0 { run() } else { app.speed = nil }
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

/// a speedometer: one arc section per zone, the needle runs over them
struct GaugeView: View {
    let title: String
    let zones: [SpeedCheckModel.Zone]
    let value: Double
    let measured: Bool
    var busy = false
    var waiting = false
    var weakest = false
    let number: String
    let unit: String
    var note = ""
    let u: CGFloat
    let width: CGFloat
    @State private var swing = 0.0

    private let start = -210.0, sweep = 240.0
    private var zone: Int { SpeedCheckModel.zone(zones, value) }
    private var seg: Double { zones.isEmpty ? sweep : sweep / Double(zones.count) }
    private func fraction(_ v: Double) -> Double {
        let n = Double(zones.count)
        guard n > 0, zone >= 0 else { return 0 }
        let z = zones[zone]
        return min(1, (Double(zone) + min(1, (v - z.from) / max(0.001, z.to - z.from))) / n)
    }

    var body: some View {
        let height = 560 * u, r = 170 * u
        let c = CGPoint(x: width / 2, y: 306 * u)
        let lit = zone >= 0 ? zones[zone].color : Color.white
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 44 * u)
                .fill(Color.white.opacity(weakest ? 0.085 : 0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 44 * u)
                        .strokeBorder(weakest ? lit : Color.white.opacity(0.1), lineWidth: (weakest ? 3 : 1) * u)
                }
            Text(title).font(Theme.display(29 * u, .semibold)).foregroundStyle(Theme.fg)
                .frame(width: width).offset(y: 28 * u)
            ForEach(Array(zones.enumerated()), id: \.offset) { i, z in
                let here = measured && zone == i
                let a = start + Double(i) * seg + 3.2, b = a + seg - 6.4
                let mid = (start + (Double(i) + 0.5) * seg) * .pi / 180
                GaugeArc(from: a, to: b, centre: c, radius: r)
                    .stroke(z.color, style: StrokeStyle(lineWidth: 44 * u, lineCap: .round))
                    .opacity(here ? (weakest ? 0.42 : 0.22) : 0)
                GaugeArc(from: a, to: b, centre: c, radius: r)
                    .stroke(z.color, style: StrokeStyle(lineWidth: 20 * u, lineCap: .round))
                    .opacity(!measured ? 0.55 : zone >= i ? 1 : 0.22)
                // the side labels grow away from the arc, so they end inside the card
                let side = abs(cos(mid)) > 0.9
                Text(z.label).font(Theme.text(20 * u, here ? .bold : .medium))
                    .foregroundStyle(here ? Theme.fg : Theme.fg3)
                    .fixedSize()
                    .frame(width: 200 * u, alignment: !side ? .center : cos(mid) > 0 ? .leading : .trailing)
                    .position(x: c.x + cos(mid) * (r + (side ? 128 : 42) * u), y: c.y + sin(mid) * (r + 42 * u))
            }
            let len = r - 30 * u
            Capsule()
                .fill(LinearGradient(colors: [.white, .white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                .frame(width: 6 * u, height: len)
                .opacity(waiting || !note.isEmpty ? 0.35 : 1)
                .position(x: c.x, y: c.y - len / 2)
                .rotationEffect(.degrees(start + sweep * fraction(value) + 90 + swing),
                                anchor: UnitPoint(x: c.x / width, y: c.y / height))
                .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.52), value: value)
            Circle().fill(.white).frame(width: 22 * u, height: 22 * u).position(c)
            let idle = waiting && number.isEmpty
            VStack(spacing: 2 * u) {
                Text(!note.isEmpty ? note : !number.isEmpty ? number : idle ? L("Waiting") : "…")
                    .font(Theme.display((!note.isEmpty || idle ? 30 : 66) * u, .bold))
                    .foregroundStyle(idle ? Theme.fg3 : Theme.fg)
                Text(idle || !note.isEmpty ? " " : unit).font(Theme.text(23 * u)).foregroundStyle(Theme.fg2)
                if measured, zone >= 0 {
                    Text(zones[zone].label + (weakest ? "  ·  " + L("Weakest") : ""))
                        .font(Theme.display(27 * u, .semibold)).foregroundStyle(lit)
                        .padding(.top, 8 * u)
                }
            }
            .frame(width: width)
            // an error is wide: below the needle at rest
            .offset(y: c.y + (note.isEmpty ? 44 : 90) * u)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.4), value: measured)
        .animation(.easeInOut(duration: 0.3), value: weakest)
        .onChange(of: busy, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { swing = sweep * 0.94 }
            } else {
                withAnimation(.easeOut(duration: 0.32)) { swing = 0 }
            }
        }
    }
}

struct SpeedCheckView: View {
    @Environment(AppModel.self) private var app
    let model: SpeedCheckModel
    @State private var shown = false

    var body: some View {
        let u = app.u
        let gaugeW = (1440 * u - 96 * u - 24 * u) / 2
        let live = model.net == .running
        ZStack {
            SheetFloor { app.speed = nil }
            VStack(alignment: .leading, spacing: 24 * u) {
                Text(L("Speed check")).font(Theme.display(42 * u, .bold)).foregroundStyle(Theme.fg)
                HStack(spacing: 24 * u) {
                    GaugeView(title: L("Internet"), zones: model.netZones, value: model.netValue ?? (live ? model.live : 0),
                              measured: model.netValue != nil, weakest: model.bothDone && model.netZone <= model.devZone,
                              number: model.netValue.map { String(Int($0.rounded())) } ?? (live && model.live > 0 ? String(Int(model.live)) : ""),
                              unit: L("Mbit/s"), note: { if case .failed(let e) = model.net { return e } else { return "" } }(), u: u, width: gaugeW)
                    GaugeView(title: L("This Mac"), zones: model.devZones, value: model.devValue ?? 0,
                              measured: model.devValue != nil, busy: model.dev == .running, waiting: model.dev == .next,
                              weakest: model.bothDone && model.devZone <= model.netZone,
                              number: model.devValue.map { String(Int($0.rounded())) } ?? "",
                              unit: L("points"), note: { if case .failed(let e) = model.dev { return e } else { return "" } }(), u: u, width: gaugeW)
                }
                HStack {
                    if model.running {
                        Text(L("Measuring…")).font(Theme.display(30 * u, .medium)).foregroundStyle(Theme.fg2)
                    } else if !model.headline.isEmpty {
                        VStack(alignment: .leading, spacing: 2 * u) {
                            Text(L("You can watch up to %1", model.headline)).font(Theme.display(34 * u, .bold)).foregroundStyle(Theme.fg)
                            Text(model.why).font(Theme.text(23 * u)).foregroundStyle(Theme.fg2)
                        }
                        .transition(.opacity)
                    }
                    Spacer()
                    GlassButton(text: L("Run Again"), focused: model.choice == 0, u: u, flat: true)
                        .contentShape(.capsule)
                        .opacity(model.running ? 0.45 : 1)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.choice = 0 } }
                        .onTapGesture { model.run() }
                    GlassButton(text: L("Done"), primary: true, focused: model.choice == 1, u: u, flat: true)
                        .contentShape(.capsule)
                        .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.choice = 1 } }
                        .onTapGesture { app.speed = nil }
                }
                .frame(height: 84 * u)
                .animation(.easeOut(duration: 0.32), value: model.running)
            }
            .padding(48 * u)
            .frame(width: 1440 * u, alignment: .leading)
            .panelGlass(60 * u, u: u)
            .scaleEffect(shown ? 1 : 0.96)
        }
        .onAppear { withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.24)) { shown = true } }
    }
}
