#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// the tv app's design tokens (qml/Theme.qml): a 1920x1080 grid scaled to the window, u = height / 1080 (width / 1920 when taller)
enum Theme {
    static let fg = Color.white
    static let fg2 = Color.white.opacity(0.66)
    static let fg3 = Color.white.opacity(0.42)
    static let accent = Color(red: 0xA5 / 255, green: 0x6B / 255, blue: 1)
    static let focusFg = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let cached = Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255)
    static let danger = Color(red: 1, green: 0x6F / 255, blue: 0x7D / 255)
    static let skeleton = Color.white.opacity(0.1)

    /// a notch or the island on a side, the home bar along the bottom (ios, landscape either way):
    /// content stays clear of them
    nonisolated(unsafe) static var safeSide: CGFloat = 0
    nonisolated(unsafe) static var safeBottom: CGFloat = 0
    /// a finger is what's in use (qml Theme.touch): the system keyboard types, no focus marks
    @MainActor static var touch: Bool { Platform.ios && PointerMode.shared.on }
    /// a mouse is in use (qml Theme.mouse): the pointer's own controls show (back top left, volume,
    /// full screen). a key ends it
    @MainActor static var mouse: Bool { !Platform.ios && PointerMode.shared.on }
    /// the words for the remote, or for a finger (qml Theme.say)
    @MainActor static func say(_ remote: String, _ tap: String) -> String { touch ? tap : remote }
    static func margin(_ u: CGFloat) -> CGFloat { max(96 * u, safeSide + 20 * u) }

    // sf pro is the system face: display/text by size, rounded for the clock
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }

    /// the focus lift every card and button shares (qml SpringAnimation spring 4.2, damping 0.62):
    /// a touch of give, no wobble
    static let lift = Animation.spring(response: 0.3, dampingFraction: 0.84)
    /// a row or page sliding to the focus: no overshoot, and a new target mid-way carries the speed
    /// on (a run of steps glides instead of starting from rest every time)
    static let slide = Animation.spring(response: 0.4, dampingFraction: 1)

    /// language options with the chosen ones first, in the order chosen; the rest as they come
    static func preferredFirst(_ opts: [[String: Any]], _ chosen: [String]) -> [[String: Any]] {
        let code = { (o: [String: Any]) in o["code"] as? String ?? "" }
        let top = opts.filter { chosen.contains(code($0)) }.sorted { (chosen.firstIndex(of: code($0)) ?? 0) < (chosen.firstIndex(of: code($1)) ?? 0) }
        return top + opts.filter { !chosen.contains(code($0)) }
    }

    static func time(_ secs: Double) -> String {
        let s = max(0, Int(secs.isFinite ? secs : 0))
        let (h, m, r) = (s / 3600, s / 60 % 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
    static func runtime(_ mins: Int) -> String {
        guard mins > 0 else { return "" }
        let (h, m) = (mins / 60, mins % 60)
        return h > 0 ? "\(h)h" + (m > 0 ? " \(m)m" : "") : "\(m)m"
    }
    /// the tv clock: 24 h, like Clock.hhmm
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static func endsAt(_ secs: Double) -> String {
        guard secs > 0 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(secs))
    }
    /// "today", "tomorrow", "Sat 25 Oct"
    static func day(_ iso: String) -> String {
        let p = DateFormatter()
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: String(iso.prefix(10))) else { return "" }
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 99
        if diff == 0 { return L("today") }
        if diff == 1 { return L("tomorrow") }
        let f = DateFormatter()
        f.locale = UILang.shared.locale
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }
    static func airDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let p = DateFormatter()
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: String(iso.prefix(10))) else { return nil }
        let f = DateFormatter()
        f.locale = UILang.shared.locale
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

/// decoded artwork at the size it is shown, kept in memory: a picture seen once is instant after
@MainActor
final class ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSString, NSImage>()
    private var running: [String: Task<NSImage?, Never>] = [:]

    init() { cache.totalCostLimit = 400 << 20 }

    private func key(_ url: URL, _ px: Int) -> String { "\(px)|\(url.absoluteString)" }

    func cached(_ url: URL, px: Int) -> NSImage? { cache.object(forKey: key(url, px) as NSString) }

    func load(_ url: URL, px: Int) async -> NSImage? {
        let k = key(url, px)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let t = running[k] { return await t.value }
        let t = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            // decoded here, off the main thread, never at first draw
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceShouldCacheImmediately: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: px]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        running[k] = t
        let img = await t.value
        running[k] = nil
        if let img { cache.setObject(img, forKey: k as NSString, cost: Int(img.size.width * img.size.height * 4)) }
        return img
    }
}

/// rounded, cropped artwork; a quiet box (and the title after a moment) until it's in
struct Art: View {
    let url: String?
    var radius: CGFloat
    var px = 800
    var placeholder = ""
    var u: CGFloat = 1

    @State private var img: NSImage?
    @State private var slow = false

    var body: some View {
        ZStack {
            if img == nil {
                RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(0.08))
                if slow && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(Theme.display(22 * u, .medium))
                        .foregroundStyle(Theme.fg3)
                        .multilineTextAlignment(.center)
                        .padding(16 * u)
                }
            }
            if let img {
                Color.clear
                    .overlay { Image(nsImage: img).resizable().interpolation(.high).scaledToFill() }
                    .clipShape(.rect(cornerRadius: radius))
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
        .task(id: url) {
            slow = false
            guard let s = url, let u = URL(string: s) else { img = nil; return }
            if let hit = ImageStore.shared.cached(u, px: px) { img = hit; return }
            img = nil
            let wait = Task { try? await Task.sleep(for: .milliseconds(120)); if !Task.isCancelled { slow = true } }
            img = await ImageStore.shared.load(u, px: px)
            wait.cancel()
        }
    }
}

/// a clearlogo in a fixed box; the title only when there's no logo (never while it loads)
struct LogoBox: View {
    let url: String?
    let title: String
    var loading = false
    var titleSize: CGFloat
    var leading = false

    @State private var img: NSImage?
    @State private var failed = false

    var body: some View {
        let align: Alignment = leading ? .leading : .center
        ZStack(alignment: align) {
            if let img {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                    .transition(.opacity.animation(.easeOut(duration: 0.26)))
            } else if !loading && (url == nil || failed) {
                Text(title)
                    .font(Theme.display(titleSize, .bold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(leading ? .leading : .center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
            }
        }
        .task(id: url) {
            failed = false
            guard let s = url, let u = URL(string: s) else { img = nil; return }
            if let hit = ImageStore.shared.cached(u, px: 1200) { img = hit; return }
            img = nil
            img = await ImageStore.shared.load(u, px: 1200)
            failed = img == nil
        }
    }
}

/// a soft shade behind text over artwork (qml Scrim): darkest in the middle, gone at the edges
struct Scrim: View {
    var strength: Double = 0.55
    var body: some View {
        EllipticalGradient(stops: [
            .init(color: .black.opacity(strength), location: 0),
            .init(color: .black.opacity(strength * 0.55), location: 0.45),
            .init(color: .black.opacity(0), location: 1),
        ])
        .allowsHitTesting(false)
    }
}

/// the tv's glass light (qml glass.frag): a crisp rim lit from the top left (weaker across, a
/// reflection opposite) and a soft glint along the lit shoulder
struct GlassRim<S: InsettableShape>: View {
    let shape: S
    let u: CGFloat
    var glint = true

    var body: some View {
        ZStack {
            if glint {
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.10), location: 0), .init(color: .white.opacity(0), location: 0.35)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 18 * u)
                    .blur(radius: 9 * u)
                    .clipShape(shape)
            }
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0), .init(color: .white.opacity(0.10), location: 0.5),
                                                      .init(color: .white.opacity(0.18), location: 1)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6 * u)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// the tv's panel glass (qml Glass kind "panel"): a touch lighter than what's behind (below 0:
    /// darker, over video), lit like the tv's
    func panelGlass(_ radius: CGFloat, u: CGFloat, lift: Double = 0.025) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return glassEffect(.regular.tint(lift >= 0 ? .white.opacity(lift) : .black.opacity(-lift)), in: shape)
            .overlay { GlassRim(shape: shape, u: u) }
    }
}
