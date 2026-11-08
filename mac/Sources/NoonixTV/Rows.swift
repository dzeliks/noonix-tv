import SwiftUI

/// one tile (qml Card): poster 2:3 or landscape 16:9 with two lines under it. focus = the tvos
/// lift: a spring scale, a deeper shadow
struct Card: View {
    let media: Item
    let style: String
    let focused: Bool
    let u: CGFloat
    var label: String?
    var sublabel: String?
    var posterW: CGFloat?
    /// waiting out its undo time: the cover pulls in, a line round the border drains
    var removal: Removal?
    @State private var me = UUID()
    @Environment(\.pageLive) private var pageLive
    private var lifted: Bool { focused && (!PointerMode.shared.on || PointerMode.shared.onCard) }

    var wide: Bool { style != "poster" }
    var artW: CGFloat { wide ? 400 * u : posterW ?? 214 * u }
    var artH: CGFloat { wide ? artW * 9 / 16 : artW * 1.5 }

    private var title: String {
        label ?? (media.kind == "episode" ? media.showTitle ?? media.title ?? "" : media.title ?? "")
    }
    private var sub: String {
        if let sublabel { return sublabel }
        guard media.kind == "episode", let s = media.season, let e = media.episode else { return "" }
        return "S\(s) · E\(e)" + (media.episodeTitle.map { "  " + $0 } ?? "")
    }

    var body: some View {
        let removing = removal != nil
        let inset = removing ? 16 * u : 0
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottom) {
                Art(url: wide ? (media.still ?? media.backdrop) : media.poster, radius: 18 * u,
                    px: wide ? 900 : 700, placeholder: title, u: u)
                    // pulled in; the outline round it rounds out to stay concentric
                    .padding(inset)
                    .opacity(removing ? 0.55 : 1)
                if let removal {
                    UndoFace(removal: removal, radius: 18 * u, u: u, width: artW)
                        .transition(.opacity)
                }
                if !removing, let p = media.progress, p > 0.01, p < 0.97 {
                    Capsule().fill(Color.white.opacity(0.28))
                        .frame(height: 7 * u)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Capsule().fill(.white).frame(width: g.size.width * p) }
                        }
                        .padding(16 * u)
                }
            }
            .frame(width: artW, height: artH)
            .animation(.easeInOut(duration: 0.42), value: removing)
            // where the focused card's art is, for the card menu (a page kept alive under another
            // one keeps its focus, it mustn't move the menu)
            .background {
                if focused && pageLive {
                    GeometryReader { g in
                        let f = g.frame(in: .named("root"))
                        Color.clear.onAppear { AppModel.current?.focusedArt = f }.onChange(of: f) { AppModel.current?.focusedArt = f }
                    }
                }
            }
            .shadow(color: .black.opacity(lifted ? 0.6 : 0.35), radius: (lifted ? 30 : 12) * u, y: (lifted ? 26 : 8) * u)
            .scaleEffect(lifted ? 1.1 : 1)
            .animation(Theme.lift, value: lifted)
            .zIndex(1)

            if wide {
                VStack(alignment: .leading, spacing: 4 * u) {
                    Text(title)
                        .font(Theme.display(25 * u, .semibold))
                        .foregroundStyle(lifted ? Theme.fg : Theme.fg2)
                    if !sub.isEmpty {
                        Text(sub).font(Theme.text(21 * u)).foregroundStyle(Theme.fg3)
                    }
                }
                .lineLimit(1)
                .frame(width: artW, alignment: .leading)
                .padding(.top, (lifted ? 30 : 16) * u)
                .animation(.easeOut(duration: 0.2), value: lifted)
            }
        }
        .frame(width: artW, height: artH + (wide ? 92 * u : 0), alignment: .top)
        .onHover { PointerMode.shared.card(me, $0) }
        .onDisappear { PointerMode.shared.card(me, false) }
    }
}

/// the line runs clockwise from the top centre, so trimming its end drains it back counter clockwise
struct DrainLine: Shape {
    var radius: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.midX, y: r.minY), radius: radius)
        p.addLine(to: CGPoint(x: r.midX, y: r.minY))
        return p
    }
}

/// what shows on a tile that's on its way out (qml Card's removal)
struct UndoFace: View {
    let removal: Removal
    let radius: CGFloat
    let u: CGFloat
    let width: CGFloat
    @State private var left: CGFloat = 1

    var body: some View {
        ZStack {
            // concentric with the cover (16u in): the outline rounds out, the line sits centred between
            RoundedRectangle(cornerRadius: radius + 16 * u).strokeBorder(.white.opacity(0.16), lineWidth: 2 * u)
            DrainLine(radius: radius + 7 * u)
                .trim(from: 0, to: left)
                .stroke(.white, style: StrokeStyle(lineWidth: 4 * u, lineCap: .round))
                .padding(9 * u)
            VStack(spacing: 10 * u) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 34 * u, weight: .semibold))
                Text(PointerMode.shared.on ? (Platform.ios ? L("Tap to undo") : L("Click to undo")) : L("Press OK to undo"))
                    .font(Theme.display(24 * u, .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .frame(width: width - 56 * u)
            .shadow(color: .black.opacity(0.6), radius: 10 * u)
        }
        .onAppear {
            let rest = max(0, removal.until.timeIntervalSinceNow)
            left = rest / AppModel.removalSecs
            withAnimation(.linear(duration: rest)) { left = 0 }
        }
    }
}

/// a horizontal strip of cards that slides under the focus (qml MediaRow's list): the focus rests
/// on the row's rest slot, cards that scroll into the margin leave instead of peeking
struct CardStrip: View {
    let items: [Item]
    let style: String
    let index: Int
    let focused: Bool
    let u: CGFloat
    let width: CGFloat
    var restSlot: Int
    var spacing: CGFloat
    var labels: ((Item) -> (String?, String?))?
    var badge: ((Item) -> Bool)?
    /// the rows a removal is for: the same title elsewhere (library, search) isn't leaving
    var undoable = false
    /// pulled on past an end (+1 the last, -1 the first)
    var pastEnd: ((Int) -> Void)?
    /// a poster size of its own (search's rows share the height)
    var posterW: CGFloat? = nil
    /// a row that runs on past its end: the last stretch fades out
    var fadeEnd: CGFloat = 0
    let point: (Int) -> Void
    let activate: (Int) -> Void

    private var cardW: CGFloat { style == "poster" ? posterW ?? 214 * u : 400 * u }
    private var cardH: CGFloat { style == "poster" ? cardW * 1.5 : 400 * u * 9 / 16 + 92 * u }
    private var step: CGFloat { cardW + spacing }
    private var margin: CGFloat { Theme.margin(u) }

    /// where the pointer left the row: it doesn't scroll for the mouse
    @State private var held: Int?
    /// the wheel sideways, in pixels
    @State private var side = PageScroll()
    /// the pointer is over the row: its page arrows show (mouse only, gone with the first key)
    @State private var over = false
    private var pointer: PointerMode { .shared }

    private var lastFirst: Int {
        let end = CGFloat(items.count) * step - spacing + 2 * margin - width
        return Int((max(0, end) / step - 0.01).rounded(.up))
    }

    /// first card left in view: the rest slot, or less once the row has hit its end
    private func firstShown(_ i: Int) -> Int { max(0, min(i - restSlot, lastFirst)) }

    /// whole cards in view: what a page arrow moves
    private var page: Int { max(1, Int(((width - margin - cardW) / step).rounded(.down)) + 1) }

    /// the pointer's way along the row: a page at a time, the focus on the new page's rest slot (where
    /// the keys would have it, so they go on from there without a jump)
    @ViewBuilder private func arrows(_ first: Int) -> some View {
        let size = 64 * u, y = (style == "poster" ? cardH : 400 * u * 9 / 16) / 2 - size / 2
        let show = over && Theme.mouse
        ZStack(alignment: .topLeading) {
            if show && first > 0 {
                RoundButton(icon: "chevron.left", u: u) {
                    let f = max(0, first - page)
                    held = f
                    point(min(items.count - 1, f + restSlot))
                }
                .offset(x: (margin - size) / 2, y: y)
                .transition(.opacity)
            }
            if show && first < lastFirst {
                RoundButton(icon: "chevron.right", u: u) {
                    let f = min(lastFirst, first + page)
                    held = f
                    point(min(items.count - 1, f + restSlot))
                }
                .offset(x: width - margin / 2 - size / 2, y: y)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: show)
    }

    var body: some View {
        let keyed = held.map { min($0, lastFirst) } ?? firstShown(index)
        let first = side.y.map { Int(($0 / step).rounded()) } ?? keyed
        let px = side.y ?? CGFloat(first) * step
        let visible = Int((width / step).rounded(.up)) + 1
        let range = max(0, first - 3)..<min(items.count, first + visible + 3)
        ZStack(alignment: .topLeading) {
            ForEach(range.map { ($0, items[$0]) }, id: \.1.id) { i, it in
                let l = labels?(it)
                Card(media: it, style: style, focused: focused && i == index, u: u, label: l?.0, sublabel: l?.1,
                     posterW: posterW, removal: undoable ? AppModel.current?.removal(it) : nil)
                    .overlay(alignment: .topTrailing) {
                        if badge?(it) == true {
                            Circle().fill(Color.black.opacity(0.55))
                                .frame(width: 40 * u, height: 40 * u)
                                .overlay { Image(systemName: "checkmark").font(.system(size: 18 * u, weight: .bold)) }
                                .padding(14 * u)
                                .scaleEffect(focused && i == index ? 1.1 : 1)
                        }
                    }
                    .contentShape(.rect)
                    // one faded out at the edge doesn't take the pointer
                    .onContinuousHover { phase in
                        if case .active = phase, Input.pointerLive, i >= first { point(i) }
                    }
                    .onTapGesture { point(i); activate(i) }
                    #if os(iOS)
                    // held: its options (android's long press)
                    .onLongPressGesture(minimumDuration: 0.45) { point(i); _ = AppModel.current?.key(.menu) }
                    #endif
                    .opacity(i < first ? 0 : 1)
                    .animation(.easeInOut(duration: 0.22), value: first)
                    .zIndex(focused && i == index ? 1 : 0)
                    .geometryGroup()
                    .offset(x: margin + CGFloat(i) * step - px)
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .offset(x: -36 * u))))
            }
        }
        .frame(width: width, height: cardH + 30 * u, alignment: .topLeading)
        .mask {
            // the end in view: no fade
            let on = fadeEnd > 0 && first < lastFirst
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(on ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fadeEnd)
            }
            // room for a lifted card's growth and shadow
            .padding(.vertical, -200 * u)
            .padding(.leading, -200 * u)
            .animation(.easeOut(duration: 0.25), value: on)
        }
        .overlay(alignment: .topLeading) { arrows(first) }
        .onHover { inside in
            over = inside
            side.past = pastEnd
            if inside { Input.row = side } else if Input.row === side { Input.row = nil }
        }
        .onDisappear { if Input.row === side { Input.row = nil } }
        #if os(iOS)
        // a finger down here: a sideways drag moves this row (Touch)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if Touch.claimed !== side { side.past = pastEnd; Touch.claimed = side }
        })
        #endif
        .animation(side.y == nil ? Theme.slide : nil, value: first)
        .onChange(of: first, initial: true) { side.start = CGFloat(first) * step; side.end = CGFloat(lastFirst) * step }
        // one gone left of the view: the view stays on its cards, nothing moves. one handler for both: a new
        // list and its new index come in one go
        .onChange(of: StripState(ids: items.map(\.id), index: index)) { old, new in
            if old.ids != new.ids {
                // a whole new list (another season): the keys' place again
                if !old.ids.isEmpty, !new.ids.contains(where: old.ids.contains) { side.y = nil; held = nil; return }
                let gone = old.ids.prefix(first).filter { !new.ids.contains($0) }.count
                if gone > 0 {
                    if let y = side.y { side.y = max(0, y - CGFloat(gone) * step) }
                    if let h = held { held = max(0, h - gone) }
                }
            }
            if old.index != new.index {
                held = Input.pointerHolds ? (side.y == nil ? held.map { min($0, lastFirst) } ?? firstShown(old.index) : held) : nil
            }
        }
        // a key: the selection if it's still in view, else the first card in view
        .onChange(of: PointerMode.shared.on) { _, on in
            guard !on, side.y != nil else { return }
            let f = max(0, min(lastFirst, first))
            side.y = nil
            held = f
            if focused, index < f || index >= f + page { point(min(items.count - 1, f)) }
        }
    }
}

private struct StripState: Equatable { var ids: [String]; var index: Int }

/// a titled row (qml MediaRow): title, then the strip; skeleton cards while it loads
struct MediaRowView: View {
    let model: RowModel
    let active: Bool
    let u: CGFloat
    let width: CGFloat
    /// search's rows: their own poster size, title and end fade
    var posterW: CGFloat? = nil
    var title: String? = nil
    var fadeEnd: CGFloat = 0
    let point: (Int) -> Void
    let activate: (Int) -> Void

    static func height(_ style: String, u: CGFloat, posterW: CGFloat? = nil) -> CGFloat {
        let cardH = style == "poster" ? (posterW ?? 214 * u) * 1.5 : 400 * u * 9 / 16 + 92 * u
        return 31 * u * 1.2 + gap(u) + cardH + 30 * u
    }
    /// room under the title for the focused card's growth (less on a short screen: the cards come first)
    static func gap(_ u: CGFloat) -> CGFloat { (AppModel.current?.short == true ? 18 : 40) * u }

    var body: some View {
        let style = model.row.style
        let cardW = style == "poster" ? posterW ?? 214 * u : 400 * u
        let spacing = (style == "poster" ? 34 : 44) * u
        VStack(alignment: .leading, spacing: Self.gap(u)) {
            HStack {
                // a placeholder row (no title yet) has a placeholder title
                if (title ?? model.row.title).isEmpty {
                    Capsule().fill(Theme.skeleton).frame(width: 260 * u, height: 24 * u)
                } else {
                    Text(title ?? Lc(model.row.title))
                        .font(Theme.display(31 * u, .semibold))
                        .foregroundStyle(active ? Theme.fg : Theme.fg2)
                        .animation(.easeInOut(duration: 0.18), value: active)
                }
                Spacer()
                // the options are one key away: say so on the focused row
                KeyHint(key: "MENU", label: L("Options"), u: u * 0.82, labelColor: Theme.fg3, pointLabel: Platform.ios ? L("Hold an item for options") : "")
                    .opacity(active && !model.items.isEmpty ? 1 : 0)
                    .animation(.easeOut(duration: 0.22), value: active)
            }
            .frame(height: 31 * u * 1.2)
            .padding(.horizontal, Theme.margin(u))
            ZStack(alignment: .topLeading) {
                if !model.loaded {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<Int(((width - Theme.margin(u)) / (cardW + spacing)).rounded(.up)), id: \.self) { _ in
                            SkeletonCard(style: style, cardW: cardW, u: u)
                        }
                    }
                    .padding(.leading, Theme.margin(u))
                    .transition(.opacity)
                } else if model.items.isEmpty {
                    Text(L("Nothing here yet"))
                        .font(Theme.text(24 * u))
                        .foregroundStyle(Theme.fg3)
                        .padding(.leading, Theme.margin(u))
                        .padding(.top, 40 * u)
                } else {
                    CardStrip(items: model.items, style: style, index: model.index, focused: active, u: u, width: width,
                              restSlot: model.restSlot, spacing: spacing, undoable: Rails.undoable.contains(model.id),
                              posterW: posterW, fadeEnd: fadeEnd, point: point, activate: activate)
                }
            }
            .frame(width: width, height: MediaRowView.height(style, u: u, posterW: posterW) - 31 * u * 1.2 - Self.gap(u), alignment: .topLeading)
            .animation(.easeOut(duration: 0.14), value: model.loaded)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// a card's placeholder while its row or grid loads (qml Skeleton)
struct SkeletonCard: View {
    let style: String
    let cardW: CGFloat
    let u: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * u) {
            RoundedRectangle(cornerRadius: 18 * u).fill(Theme.skeleton)
                .frame(width: cardW, height: style == "poster" ? cardW * 1.5 : cardW * 9 / 16)
            if style != "poster" {
                Capsule().fill(Theme.skeleton).frame(width: cardW * 0.6, height: 20 * u)
                Capsule().fill(Theme.skeleton).frame(width: cardW * 0.4, height: 16 * u)
            }
        }
    }
}

/// placeholder cards in a grid's cells (library, search) while it loads, laid out like PosterGrid
struct SkeletonGrid: View {
    let style: String
    let cols: Int
    let cellW: CGFloat
    let cellH: CGFloat
    let height: CGFloat
    let cardW: CGFloat
    let u: CGFloat

    var body: some View {
        let lines = max(1, Int((height / cellH).rounded(.up)))
        ZStack(alignment: .topLeading) {
            ForEach(0..<cols * lines, id: \.self) { i in
                SkeletonCard(style: style, cardW: cardW, u: u)
                    .offset(x: CGFloat(i % cols) * cellW + 20 * u, y: CGFloat(i / cols) * cellH + 20 * u)
            }
        }
        .frame(width: CGFloat(cols) * cellW, height: height, alignment: .topLeading)
        .clipped()
    }
}
