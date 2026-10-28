import AppKit
import SwiftUI

/// launch splash (qml Splash): the pink blooms out of the black window while the lockup rises
/// into place (NOONIX_SPLASH_FAST=1: starts there at once), then the kitty glides to the middle while the name slides in behind
/// it, its antennas sway from the move, it smiles, leans in and shrinks away to the middle as
/// the pink fades off the ui. any key: the quick way out
@MainActor @Observable
final class SplashModel {
    /// the intro since (pink in, lockup up); nil before the window shows it
    var introStart: Date?
    var introRunning = false
    /// playing since; nil while what's underneath is still loading
    var start: Date?
    /// skipped at (the main run's values freeze there)
    var skipAt: Date?
    /// the ui under it, easing into place as the pink goes
    var uiScale: CGFloat = 1.05
    @ObservationIgnored var onDone: () -> Void = {}
    @ObservationIgnored private var playAsked = false
    @ObservationIgnored private var skipAsked = false

    static var enabled: Bool { ProcessInfo.processInfo.environment["NOONIX_SPLASH"] != "0" }
    static let intro = ProcessInfo.processInfo.environment["NOONIX_SPLASH_FAST"] != "1"
    /// pink in + the rise, then a breath
    static let introMs = 1100.0
    /// dev: NOONIX_SPLASH_SLOW=4 for recordings (the main run)
    static let slow = max(0.1, Double(ProcessInfo.processInfo.environment["NOONIX_SPLASH_SLOW"] ?? "") ?? 1)

    /// the window is up: the intro runs while what's underneath loads
    func beginIntro() {
        guard Self.intro, introStart == nil else { return }
        introStart = Date()
        introRunning = true
        Task {
            try? await Task.sleep(for: .milliseconds(Int(Self.introMs * Self.slow)))
            introRunning = false
            if playAsked { playAsked = false; play() }
        }
    }

    func play() {
        guard start == nil else { return }
        // after the intro (or once it has run)
        if Self.intro, introStart == nil || introRunning { playAsked = true; return }
        start = Date()
        if skipAsked { skipAsked = false; skip(); return }
        Task {
            try? await Task.sleep(for: .milliseconds(Int(2440 * Self.slow)))
            guard skipAt == nil else { return }
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.72 * Self.slow)) { uiScale = 1 }
            try? await Task.sleep(for: .milliseconds(Int(720 * Self.slow)))
            if skipAt == nil { onDone() }
        }
    }

    func skip() {
        if start == nil, introRunning { skipAsked = true; return }
        guard start != nil, skipAt == nil else { return }
        skipAt = Date()
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.3)) { uiScale = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            onDone()
        }
    }
}

struct SplashView: View {
    let model: SplashModel
    let size: CGSize
    @State private var nameWidth: CGFloat = 0

    /// the overlay's brand ("noonix-tv")
    private static let c1 = Color(red: 0xD9 / 255, green: 0x3D / 255, blue: 0x8A / 255)
    private static let c2 = Color(red: 0x4A / 255, green: 0x0E / 255, blue: 0x2F / 255)
    private static let glow = (r: 1.0, g: 0.761, b: 0.882, a: 0.14)

    private static let parts: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        for n in ["plate", "antenna-left", "antenna-right", "head", "eye-left", "eye-right", "eye-happy-left",
                  "eye-happy-right", "features", "mouth", "smile", "blush"] {
            if let u = Bundle.main.url(forResource: n, withExtension: "svg", subdirectory: "kitty"), let i = NSImage(contentsOf: u) {
                out[n] = i
            }
        }
        return out
    }()

    var body: some View {
        TimelineView(.animation(paused: model.start == nil && !model.introRunning)) { ctx in
            frame(Self.values(model, now: ctx.date))
        }
        .onAppear { model.beginIntro() }
    }

    /// everything that moves, at one moment
    struct V {
        var glide: CGFloat = 0, antenna: Double = 0, eyes: CGFloat = 1, mouth: CGFloat = 1
        var smileO: CGFloat = 0, smileS: CGFloat = 0.45, happyO: CGFloat = 0, happyS: CGFloat = 0.4, blush: CGFloat = 0.5625
        var zoom: CGFloat = 1, bg: CGFloat = 1, name: CGFloat = 1
        /// the intro: the pink over the black, the lockup's rise (1 = all the way below) and fade
        var pink: CGFloat = 1, rise: CGFloat = 0, lockup: CGFloat = 1
    }

    static func values(_ m: SplashModel, now: Date) -> V {
        var intro = V()
        if SplashModel.intro {
            let i = m.introStart.map { now.timeIntervalSince($0) * 1000 / SplashModel.slow } ?? 0
            intro.pink = inOutSine(clamp(i / 700))
            intro.rise = 1 - bezier(0.16, 1, 0.3, 1, i / 900)
            intro.lockup = outSine(clamp(i / 550))
        }
        guard let start = m.start else { return intro }
        let t = (m.skipAt ?? now).timeIntervalSince(start) * 1000 / SplashModel.slow
        var v = V()
        v.glide = bezier(0.5, 0, 0.1, 1, t / 1000)
        // the antennas, dragged by the glide and springing back
        let swing: [(Double, Double, (Double) -> Double)] = [(310, -7, outSine), (430, 9, inOutSine), (320, -5, inOutSine),
                                                               (280, 2.5, inOutSine), (260, -1, inOutSine), (240, 0, outSine)]
        var at = 0.0, from = 0.0
        for (d, to, ease) in swing {
            if t < at + d { v.antenna = from + (to - from) * ease(max(0, (t - at) / d)); break }
            at += d; from = to; v.antenna = to
        }
        // the smile: eyes close into themselves and open as happy arcs, the mouth grows open
        let e = t - 1160
        v.eyes = 1 - inQuad(clamp(e / 150))
        v.mouth = 1 - inQuad(clamp(e / 120))
        v.smileO = clamp((e - 70) / 140)
        v.smileS = 0.45 + 0.55 * outCubic(clamp((e - 70) / 420))
        v.happyO = clamp((e - 130) / 120)
        v.happyS = 0.4 + 0.6 * outCubic(clamp((e - 130) / 360))
        v.blush = 0.5625 + 0.4375 * inOutSine(clamp(e / 520))
        // lean in, then all the way out to the middle as the pink lifts
        if t < 1920 { v.zoom = 1 } else if t < 2300 { v.zoom = 1 + 0.08 * inOutSine((t - 1920) / 380) } else {
            v.zoom = 1.08 * (1 - bezier(0.6, 0, 0.4, 1, (t - 2300) / 640))
        }
        v.bg = 1 - inOutSine(clamp((t - 2440) / 520))
        if let skip = m.skipAt, m.start != nil {
            let s = now.timeIntervalSince(skip) * 1000
            v.zoom *= 1 - inCubic(clamp(s / 300))
            v.bg *= 1 - inOutSine(clamp(s / 300))
            v.name = 1 - clamp(s / 150)
        }
        return v
    }

    @ViewBuilder private func frame(_ v: V) -> some View {
        let W = size.width, H = size.height
        // the launch card's lockup: an 800x480 box at 62.5 % of the width, centred; icon 168 at
        // x 91, the name 88 bold at x 289 on a baseline of 270.8
        let k = W * 0.625 / 800
        let bx = (W - 800 * k) / 2, by = (H - 480 * k) / 2
        let icon = 168 * k
        let shift = W / 2 - (bx + 175 * k)
        let clipX = bx + 175 * k + shift * v.glide
        let nameX = 114 * k + (-nameWidth - 4 * k - 114 * k) * v.glide
        let lift = 70 * k * v.rise
        ZStack(alignment: .topLeading) {
            // what the pink blooms out of
            if SplashModel.intro { Color.black.opacity(v.bg) }
            Canvas { ctx, sz in
                ctx.fill(Path(CGRect(origin: .zero, size: sz)),
                         with: .linearGradient(Gradient(colors: [Self.c1, Self.c2]), startPoint: .zero, endPoint: CGPoint(x: sz.width, y: sz.height)))
            }
            .opacity(v.bg * v.pink)

            // the name, clipped at the icon's centre: it slides in behind the icon and never
            // comes out the other side
            Color.clear
                .frame(width: max(0, W - (bx + 175 * k)), height: H)
                .overlay(alignment: .topLeading) {
                    Text("Noonix TV")
                        .font(.system(size: 88 * k, weight: .bold)).tracking(-2 * k)
                        .foregroundStyle(.white)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
                        .alignmentGuide(.top) { d in d[.firstTextBaseline] }
                        .offset(x: nameX, y: by + 270.8 * k)
                        .opacity(v.name)
                }
                .clipped()
                .offset(x: clipX, y: lift)
                .opacity(v.lockup)

            kitty(v)
                .frame(width: 1024, height: 1024, alignment: .topLeading)
                .scaleEffect(v.zoom)
                .scaleEffect(icon / 1024, anchor: .topLeading)
                .frame(width: icon, height: icon, alignment: .topLeading)
                .offset(x: bx + 91 * k + shift * v.glide, y: by + 156 * k + lift)
                .opacity(v.lockup)

            // the top-left light, over everything (the card lights its art too)
            Canvas { ctx, sz in
                ctx.scaleBy(x: sz.width, y: sz.height)
                var stops: [Gradient.Stop] = []
                for i in 0...10 {
                    let d = Double(i) / 10, g = 1 - d
                    let a = Self.glow.a * g * g * (3 - 2 * g)
                    stops.append(.init(color: Color(red: Self.glow.r, green: Self.glow.g, blue: Self.glow.b).opacity(a), location: d))
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 1, height: 1)),
                         with: .radialGradient(Gradient(stops: stops), center: CGPoint(x: 0.22, y: 0), startRadius: 0, endRadius: 0.95))
            }
            .opacity(v.bg * v.pink)
            .allowsHitTesting(false)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    /// the icon's parts in its 1024 units (the svgs' viewboxes)
    @ViewBuilder private func kitty(_ v: V) -> some View {
        ZStack(alignment: .topLeading) {
            part("plate", 0, 0, 1024, 1024)
            // mirrored, same beat: they spread apart, swing back together and settle
            part("antenna-left", 312, 100, 400, 312, rotate: v.antenna)
            part("antenna-right", 312, 100, 400, 312, rotate: -v.antenna)
            part("head", 232, 300, 560, 544)
            part("eye-left", 376, 544, 88, 112, scale: 0.25 + 0.75 * v.eyes, opacity: v.eyes)
            part("eye-right", 560, 544, 88, 112, scale: 0.25 + 0.75 * v.eyes, opacity: v.eyes)
            part("eye-happy-left", 376, 544, 88, 112, scale: v.happyS, opacity: v.happyO)
            part("eye-happy-right", 560, 544, 88, 112, scale: v.happyS, opacity: v.happyO)
            part("features", 280, 640, 464, 96)
            part("mouth", 456, 688, 112, 48, opacity: v.mouth)
            part("smile", 432, 680, 160, 112, scale: v.smileS, anchor: .top, opacity: v.smileO)
            part("blush", 334, 662, 356, 56, opacity: v.blush)
        }
    }

    private func part(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rotate: Double = 0,
                      scale: CGFloat = 1, anchor: UnitPoint = .center, opacity: CGFloat = 1) -> some View {
        Group {
            if let img = Self.parts[name] { Image(nsImage: img).resizable() } else { Color.clear }
        }
        .frame(width: w, height: h)
        .scaleEffect(scale, anchor: anchor)
        .rotationEffect(.degrees(rotate), anchor: .bottom)
        .opacity(opacity)
        .offset(x: x, y: y)
    }

    // ---- easing
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func inQuad(_ x: Double) -> Double { x * x }
    static func inCubic(_ x: Double) -> Double { x * x * x }
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func outSine(_ x: Double) -> Double { sin(x * .pi / 2) }
    static func inOutSine(_ x: Double) -> Double { -(cos(.pi * x) - 1) / 2 }
    /// css cubic-bezier(x1, y1, x2, y2) at progress x
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        let x = clamp(x)
        func b(_ t: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<30 {
            t = (lo + hi) / 2
            if b(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return b(t, y1, y2)
    }
}
