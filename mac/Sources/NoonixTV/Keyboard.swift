import SwiftUI

/// on-screen keyboard (qml Keyboard): the ios glass keyboard without the terminal row. the owner
/// sends keys with key(_:) and gets typed / special (backspace, enter, clear) / leave(direction)
@MainActor @Observable
final class KeyboardModel {
    struct Cap {
        enum Kind { case char, fn, gap }
        let t: String
        let w: CGFloat
        let kind: Kind
        let v: String
        var symbol = ""
    }

    var page = "abc"
    var shift = false
    var caps = false
    var row = 2
    var col = 4                                 // starts on "g"
    var enterLabel = "return"
    /// the key that was just pressed (row, index) and a counter, for its squash
    var popped: (row: Int, index: Int, n: Int) = (-1, -1, 0)
    @ObservationIgnored var typed: (String) -> Void = { _ in }
    @ObservationIgnored var special: (String) -> Void = { _ in }
    @ObservationIgnored var leave: (String) -> Void = { _ in }

    var upper: Bool { shift || caps }

    private static func c(_ s: String) -> [Cap] { s.split(separator: " ").map { Cap(t: String($0), w: 1, kind: .char, v: String($0)) } }
    private func f(_ t: String, _ w: CGFloat, _ v: String, _ s: String = "") -> Cap { Cap(t: t, w: w, kind: .fn, v: v, symbol: s) }
    private static func g(_ w: CGFloat) -> Cap { Cap(t: "", w: w, kind: .gap, v: "") }

    var rows: [[Cap]] {
        let last = { (p: String, l: String) in [self.f(l, 1.5, "page:" + p), self.f(L("space"), 4.5, "space"), self.f(L("clear"), 1.5, "clear"), self.f(self.enterLabel, 2.5, "enter")] }
        switch page {
        case "123":
            return [Self.c("1 2 3 4 5 6 7 8 9 0"), Self.c("- / : ; ( ) $ & @ \""),
                    [f("#+=", 1.5, "page:sym")] + Self.c(". , ? ! ' | ~") + [f("", 1.5, "backspace", "backspace")],
                    last("abc", "ABC")]
        case "sym":
            return [Self.c("[ ] { } # % ^ * + ="), Self.c("_ \\ < > & ` $ ~ : \""),
                    [f("123", 1.5, "page:123")] + Self.c(". , ? ! ' @ %") + [f("", 1.5, "backspace", "backspace")],
                    last("abc", "ABC")]
        default:
            return [Self.c("q w e r t y u i o p"), [Self.g(0.5)] + Self.c("a s d f g h j k l") + [Self.g(0.5)],
                    [f("", 1.5, "shift", "shift")] + Self.c("z x c v b n m") + [f("", 1.5, "backspace", "backspace")],
                    last("123", "123")]
        }
    }

    /// the keys of a row that take focus (not the spacers), with their centre in units
    private func keys(_ r: Int) -> [(i: Int, cx: CGFloat)] {
        var out: [(Int, CGFloat)] = [], x: CGFloat = 0
        for (i, k) in rows[r].enumerated() {
            if k.kind != .gap { out.append((i, x + k.w / 2)) }
            x += k.w
        }
        return out
    }
    var focusIndex: Int { let ks = keys(row); return ks[min(col, ks.count - 1)].i }
    private var centre: CGFloat { let ks = keys(row); return ks[min(col, ks.count - 1)].cx }
    private func nearest(_ r: Int, _ cx: CGFloat) -> Int {
        let ks = keys(r)
        return ks.indices.min { abs(ks[$0].cx - cx) < abs(ks[$1].cx - cx) } ?? 0
    }

    /// the focus comes in from outside: side = the edge it crosses, fraction = where along it
    func enterAt(_ side: String, _ fraction: CGFloat) {
        if side == "top" || side == "bottom" {
            row = side == "top" ? 0 : rows.count - 1
            col = nearest(row, fraction * 10)
        } else {
            row = max(0, min(rows.count - 1, Int(fraction * CGFloat(rows.count))))
            col = side == "left" ? 0 : keys(row).count - 1
        }
    }

    /// the arrows and ok; true when handled
    func key(_ k: Key) -> Bool {
        let n = keys(row).count
        switch k {
        case .left: if col > 0 { col -= 1 } else { leave("left") }
        case .right: if col < n - 1 { col += 1 } else { leave("right") }
        case .up, .down:
            let r = row + (k == .up ? -1 : 1)
            if r < 0 || r >= rows.count { leave(k == .up ? "up" : "down"); return true }
            col = nearest(r, centre)
            row = r
        case .ok: press(rows[row][focusIndex], at: (row, focusIndex))
        default: return false
        }
        return true
    }

    func point(_ r: Int, _ i: Int) {
        row = r
        col = max(0, keys(r).firstIndex { $0.i == i } ?? 0)
    }

    func press(_ k: Cap, at: (Int, Int)) {
        popped = (at.0, at.1, popped.n + 1)
        if k.kind == .char {
            typed(upper ? k.v.uppercased() : k.v)
            if shift { shift = false }
            return
        }
        if k.v.hasPrefix("page:") {
            page = String(k.v.dropFirst(5))
            col = min(col, keys(row).count - 1)
            return
        }
        switch k.v {
        case "shift":
            if caps { caps = false; shift = false } else if shift { caps = true; shift = false } else { shift = true }
        case "space": typed(" ")
        default: special(k.v)
        }
    }
}

struct KeyboardView: View {
    let model: KeyboardModel
    /// the keyboard's own unit (qml: Theme.u / 2)
    let u: CGFloat
    let width: CGFloat
    let active: Bool

    var body: some View {
        let pad = 22 * u, gap = 14 * u
        let unit = (width - 2 * pad - 9 * gap) / 10
        let keyH = unit * 1.36
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 48 * u)
                .fill(Color.white.opacity(0.055))
                .overlay { RoundedRectangle(cornerRadius: 48 * u).stroke(Color.white.opacity(0.1), lineWidth: 2 * u) }
            ForEach(Array(model.rows.enumerated()), id: \.offset) { r, caps in
                ForEach(Array(caps.enumerated()), id: \.offset) { i, k in
                    if k.kind != .gap {
                        let start = caps[..<i].reduce(0) { $0 + $1.w }
                        KeyCapView(label: k.kind == .char ? (model.upper ? k.t.uppercased() : k.t) : k.t,
                                   symbol: k.v == "shift" ? (model.caps ? "capslock.fill" : model.shift ? "shift.fill" : "shift")
                                       : k.symbol == "backspace" ? "delete.left" : "",
                                   fn: k.kind == .fn,
                                   lit: k.v == "shift" && model.upper,
                                   focused: active && model.row == r && model.focusIndex == i,
                                   labelSize: k.kind == .char ? 54 * u : (k.t.count > 3 ? 34 : 38) * u,
                                   symbolSize: 46 * u,
                                   radius: 20 * u,
                                   pop: model.popped.row == r && model.popped.index == i ? model.popped.n : 0,
                                   u: u)
                            .frame(width: k.w * (unit + gap) - gap, height: keyH)
                            .offset(x: pad + start * (unit + gap), y: pad + CGFloat(r) * (keyH + gap))
                            .zIndex(active && model.row == r && model.focusIndex == i ? 1 : 0)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.point(r, i) } }
                            .onTapGesture { model.point(r, i); model.press(k, at: (r, i)) }
                    }
                }
            }
        }
        .frame(width: width, height: 2 * pad + 4 * keyH + 3 * gap, alignment: .topLeading)
    }
}

/// one key (qml KeyCap): dark glass at rest, white and lifted when focused, a squash on press
struct KeyCapView: View {
    let label: String
    let symbol: String
    let fn: Bool
    let lit: Bool
    let focused: Bool
    let labelSize: CGFloat
    let symbolSize: CGFloat
    let radius: CGFloat
    let pop: Int
    let u: CGFloat
    @State private var squash: CGFloat = 1

    var body: some View {
        let ink = focused ? Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255) : .white
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(focused ? Color.white.opacity(0.97) : lit ? Color(red: 0.04, green: 0.52, blue: 1).opacity(0.85) : Color.white.opacity(fn ? 0.10 : 0.21))
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20 * u, y: 14 * u)
            if symbol.isEmpty {
                Text(label).font(Theme.display(labelSize, fn ? .medium : .regular)).foregroundStyle(ink)
            } else {
                Image(systemName: symbol).font(.system(size: symbolSize * 0.62, weight: .medium)).foregroundStyle(ink)
            }
        }
        .scaleEffect(squash)
        .scaleEffect(focused ? 1.14 : 1)
        .animation(Theme.lift, value: focused)
        .animation(.easeOut(duration: 0.16), value: lit)
        .onChange(of: pop) {
            withAnimation(.easeOut(duration: 0.07)) { squash = 0.88 } completion: {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) { squash = 1 }
            }
        }
    }
}
