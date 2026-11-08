import SwiftUI

/// home / movies / shows (qml Home): the hero of the focused card over the rows in the lower 47 %;
/// the focused row sits at the top of that band, the rows above it fade behind the hero
struct RailsPage: View {
    @Environment(AppModel.self) private var app
    let rails: Rails
    /// the row at the top while the pointer moves the focus (the page doesn't scroll for the mouse)
    @State private var held: Int?

    var body: some View {
        let u = app.u, size = app.size
        let shown = rails.shown
        // short (a phone): one whole row of either kind (posters are the taller, their own room under
        // the cards included), clear of the home bar; the next row doesn't peek in
        // (the home bar sits in the room under the cards, not under that room)
        let rowsH = max(size.height * 0.47, app.short ? (31 * 1.2 + 18 + 214 * 1.5) * u + max(30 * u, Theme.safeBottom + 6 * u) : 0)
        let rowsTop = size.height - rowsH
        let gap = 8 * u
        let heights = shown.map { MediaRowView.height($0.row.style, u: u) + gap }
        let cur = min(rails.current, max(0, shown.count - 1))
        let top = min(held ?? cur, cur)
        let keyed = heights.prefix(top).reduce(0, +)
        // the wheel: hero and rows are one page
        let wheelY = rails.scroll.y
        let before = wheelY ?? keyed
        let current = rails.focusedRow?.current
        let pageActive = !app.navFocused && app.detailStack.isEmpty

        ZStack(alignment: .topLeading) {
            Hero(item: current, u: u, size: size, band: max(size.height * 0.475, rowsH))
                .offset(y: -(wheelY ?? 0))

            ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                let y = rowsTop + heights.prefix(i).reduce(0, +) - before
                MediaRowView(model: row, active: pageActive && i == cur, u: u, width: size.width,
                             point: { idx in
                                 // a row behind the hero or fading out under the bar doesn't take the pointer
                                 guard wheelY != nil || i >= top, y + heights[i] / 2 >= 210 * u else { return }
                                 app.navFocused = false
                                 rails.point(row, idx)
                             },
                             activate: { idx in
                                 if row.items.indices.contains(idx) { app.activate(row, row.items[idx]) }
                             })
                    // rows above the focus hide behind the hero: gone at once, back with a fade
                    // (only the fade: the move stays on the page's slide like every other row)
                    // (a phone: the next one starts under the home bar, it doesn't peek in)
                    .animation(i < top ? .easeOut(duration: 0.1) : .easeIn(duration: 0.45)) {
                        $0.opacity(wheelY == nil && (i < top || (app.short && y >= size.height - Theme.safeBottom - 1)) ? 0 : 1)
                    }
                    // one piece: its cards don't trail its title on the way
                    .geometryGroup()
                    .offset(y: y)
            }
            // scrolled: the page goes blurrier and darker all the way up, the screen's top row is black
            let amount = min(1, max(0, (wheelY ?? 0) / (560 * u)))
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.4),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.61), location: 0.25),
                                       .init(color: .black.opacity(0.31), location: 0.5), .init(color: .black.opacity(0.1), location: 0.75),
                                       .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: size.width, height: 340 * u)
            .opacity(amount * amount * (3 - 2 * amount))
            .allowsHitTesting(false)
            // the rows before the page has them: placeholders where they'll be
            if !rails.known {
                ForEach(Array(Rails.placeholders.enumerated()), id: \.offset) { i, row in
                    MediaRowView(model: row, active: false, u: u, width: size.width, point: { _ in }, activate: { _ in })
                        .offset(y: rowsTop + Rails.placeholders.prefix(i).map { MediaRowView.height($0.row.style, u: u) + gap }.reduce(0, +))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .animation(Theme.slide, value: top)
        .onChange(of: rails.current) { old, new in
            held = Input.pointerHolds ? min(held ?? old, new) : nil
            // keys on the scrolled page: it follows, at the top row it's the tv's page again
            if !Input.pointing { rails.scroll.reveal(new) }
        }
        .onChange(of: PointerMode.shared.on) { _, on in if !on { held = nil } }
        .onChange(of: current?.id) { aheadOfFocus() }
        .onAppear { aheadOfFocus() }
        .onChange(of: heights, initial: true) { _, hs in
            var tops: [CGFloat] = [], y: CGFloat = 0
            for h in hs { tops.append(y); y += h }
            rails.scroll.tops = tops
            // a phone: the last row ends well clear of the home indicator
            rails.scroll.end = max(0, y + (app.short ? 56 * u + Theme.safeBottom : 0) - (size.height - rowsTop))
            rails.scroll.rowsTop = rowsTop
            rails.scroll.clearY = 210 * u
            rails.scroll.height = size.height
        }
        .onChange(of: keyed, initial: true) { _, k in rails.scroll.start = k }
    }

    /// details of the next 3 cards each way and of the rows around, so the hero is instant
    private func aheadOfFocus() {
        let shown = rails.shown
        guard let row = rails.focusedRow else { return }
        app.prefetch(row.current)
        for d in 1...3 {
            if row.index + d < row.items.count { app.prefetch(row.items[row.index + d]) }
            if row.index - d >= 0 { app.prefetch(row.items[row.index - d]) }
            for side in [-1, 1] {
                let r = rails.current + side * d
                if shown.indices.contains(r) { app.prefetch(shown[r].current) }
            }
        }
    }
}

/// the spotlight of the focused item (qml Hero): textless backdrop, logo, meta line with "ends
/// at", the story on the right
struct Hero: View {
    @Environment(AppModel.self) private var app
    let item: Item?
    let u: CGFloat
    let size: CGSize
    /// the rows' share of the page (home makes it larger on a short screen)
    var band: CGFloat?

    @State private var cur: Item?
    @State private var textOpacity: Double = 1
    @State private var swap: Task<Void, Never>?

    private var details: Details? { AppModel.key(cur).flatMap { app.heroCache[$0] } }
    private var wanted: String? {
        (AppModel.key(item).flatMap { app.heroCache[$0] }?.item.backdrop) ?? item?.backdrop
    }

    var body: some View {
        let margin = Theme.margin(u)
        let infoBottom = (band ?? size.height * 0.475) + (app.short ? 16 : 34) * u
        // grid units between the top bar (with air under it) and the info's bottom: a short screen
        // gets a smaller logo and fewer lines of story instead of text running into the bar
        // (a phone's top bar is smaller than the tv's)
        let room = (size.height - infoBottom) / u - (app.short ? 135 : 165)
        // a very short screen takes a smaller logo rather than one under the bar
        let logoH = max(app.short ? 40 : 96, min(190, room - 95 - (cur?.kind == "episode" ? 45 : 0))) * u
        ZStack(alignment: .bottomLeading) {
            Backdrop(url: wanted)
                .frame(width: size.width, height: size.height)

            // legibility: dark from the left and towards the rows
            LinearGradient(stops: [.init(color: .black.opacity(0.82), location: 0),
                                   .init(color: .black.opacity(0.45), location: 0.45),
                                   .init(color: .black.opacity(0), location: 0.8)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.55), location: 0.45),
                                   .init(color: .black.opacity(0.9), location: 0.75),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: size.height * 0.72)

            if cur == nil {
                skeleton(margin: margin, infoBottom: infoBottom)
            }

            if let cur {
                let episode = cur.kind == "episode"
                VStack(alignment: .leading, spacing: 16 * u) {
                    LogoBox(url: details?.item.logo, title: (episode ? cur.showTitle : cur.title) ?? "",
                            loading: details == nil, titleSize: 64 * u)
                        .frame(width: 560 * u, height: logoH)
                        // room under the logo: a tall one doesn't sit on the line below
                        .padding(.bottom, 16 * u)
                    if episode, let s = cur.season, let e = cur.episode {
                        Text("S\(s) · E\(e)" + (cur.episodeTitle.map { "  " + $0 } ?? ""))
                            .font(Theme.display(31 * u, .semibold))
                            .foregroundStyle(Theme.fg)
                            .padding(.top, 4 * u)
                    }
                    MetaLine(item: cur, details: details, u: u, maxWidth: size.width * 0.42)
                }
                .frame(width: size.width * 0.42, alignment: .leading)
                .padding(.leading, margin)
                .padding(.bottom, infoBottom)
                .opacity(textOpacity)

                story(cur, margin: margin, infoBottom: infoBottom, lines: max(2, min(7, Int(((room - (app.short ? 108 : 78)) / 28).rounded(.down)))))
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: item?.id, initial: true) { follow() }
    }

    @ViewBuilder
    private func story(_ cur: Item, margin: CGFloat, infoBottom: CGFloat, lines: Int) -> some View {
        let overview = cur.overview ?? cur.showOverview ?? ""
        let cast = (details?.cast ?? []).prefix(3).compactMap(\.name)
        let facts: String = {
            guard let d = details else { return "" }
            var f: [String] = []
            if let n = d.network { f.append(n) }
            if let a = d.nextAir?.airDate { f.append(L("New episode %1", Theme.day(a))) }
            else if let s = d.status, s != "Released", s != "Returning Series" { f.append(Lc(s)) }
            return f.joined(separator: "  ·  ")
        }()
        VStack(alignment: .leading, spacing: 14 * u) {
            Text(overview)
                .font(Theme.text(24 * u))
                .foregroundStyle(Theme.fg.opacity(0.93))
                .lineSpacing(24 * u * 0.19)
                .lineLimit(lines)
                .shadow(color: .black.opacity(0.45), radius: 0, y: 1)
            if !cast.isEmpty {
                Text(L("Starring %1", cast.joined(separator: ", ")))
                    .font(Theme.text(21 * u)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
            if !facts.isEmpty {
                Text(facts).font(Theme.text(21 * u, .medium)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
        }
        .frame(width: size.width * 0.42, alignment: .leading)
        .background(alignment: .topLeading) { StoryScrim(u: u, margin: margin, strength: 0.7) }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, margin)
        .padding(.bottom, infoBottom)
        .opacity(overview.isEmpty ? 0 : textOpacity)
    }

    private func skeleton(margin: CGFloat, infoBottom: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 26 * u) {
                RoundedRectangle(cornerRadius: 26 * u).fill(Theme.skeleton).frame(width: 460 * u, height: 120 * u)
                Capsule().fill(Theme.skeleton).frame(width: 380 * u, height: 26 * u)
            }
            .padding(.leading, margin)
            VStack(alignment: .leading, spacing: 18 * u) {
                ForEach([1, 0.96, 0.98, 0.9, 0.6], id: \.self) { f in
                    Capsule().fill(Theme.skeleton).frame(width: size.width * 0.42 * f, height: 22 * u)
                }
            }
            .frame(width: size.width * 0.42, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, margin)
        }
        .padding(.bottom, infoBottom)
        .transition(.opacity)
    }

    /// the text fades out, swaps, fades back in; moving fast keeps it down until the focus rests
    private func follow() {
        guard let item else { cur = nil; return }
        if cur == nil { cur = item; return }
        if item.id == cur?.id { return }
        swap?.cancel()
        swap = Task {
            withAnimation(.easeIn(duration: 0.12)) { textOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            cur = item
            withAnimation(.easeOut(duration: 0.26)) { textOpacity = 1 }
        }
        // details after the focus rests a moment
        let it = item
        Task {
            try? await Task.sleep(for: .milliseconds(240))
            if it.id == self.item?.id { app.prefetch(it) }
        }
    }
}

/// two layers take turns so a new backdrop fades over the old one (520 ms)
struct Backdrop: View {
    let url: String?
    @State private var shown: NSImage?
    /// the one before, whole under the new one while it fades in (qml's two layers): no dip to black
    @State private var under: NSImage?
    @State private var last: Date = .distantPast

    private func picture(_ img: NSImage) -> some View {
        Color.clear
            .overlay { Image(nsImage: img).resizable().interpolation(.high).scaledToFill() }
            .clipped()
            .id(ObjectIdentifier(img))
    }

    var body: some View {
        ZStack {
            Color.black
            if let under { picture(under) }
            if let shown {
                picture(shown).transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .task(id: url) {
            guard let s = url, let u = URL(string: s) else { return }
            let img = await ImageStore.shared.load(u, px: 1920)
            guard let img, !Task.isCancelled, img !== shown else { return }
            // a new picture before the last fade finished: snap to it
            let snap = Date().timeIntervalSince(last) < 0.52
            last = Date()
            withTransaction(Transaction(animation: nil)) { under = shown }
            withAnimation(snap ? nil : .easeInOut(duration: 0.52)) { shown = img }
        }
    }
}

/// "2024 · Drama, Crime · 2h 46m · 16+  ★ 8.4  Ends at 23:41"
struct MetaLine: View {
    let item: Item?
    let details: Details?
    let u: CGFloat
    /// the room it has (0: any). short of it the genres go first, then the rating (qml: maxWidth)
    var maxWidth: CGFloat = 0

    var body: some View {
        if maxWidth > 0 {
            ViewThatFits(in: .horizontal) {
                line(genres: true, rating: true)
                line(genres: false, rating: true)
                line(genres: false, rating: false)
            }
            .frame(width: maxWidth, alignment: .leading)
        } else {
            line(genres: true, rating: true)
        }
    }

    private func line(genres: Bool, rating: Bool) -> some View {
        let episode = (item?.kind ?? details?.item.kind) == "episode"
        let runtime = episode ? (item?.runtime ?? details?.item.runtime ?? 0) : (details?.item.runtime ?? item?.runtime ?? 0)
        let remaining: Double = {
            guard let item, item.kind == "movie" || item.kind == "episode" else { return 0 }
            if let d = item.duration, let p = item.position, d > 0, p > 0 { return d - p }
            return Double(runtime * 60)
        }()
        var parts: [String] = []
        if let y = item?.year { parts.append(String(y)) }
        if genres, let g = item?.genres, !g.isEmpty { parts.append(g.prefix(2).map { Lc($0) }.joined(separator: ", ")) }
        if runtime > 0 { parts.append(Theme.runtime(runtime)) }
        if let c = details?.certification, !c.isEmpty { parts.append(c) }

        return HStack(spacing: 14 * u) {
            Text(parts.joined(separator: "  ·  ")).foregroundStyle(Theme.fg2)
            if rating, let r = item?.rating, r > 0 {
                Text("★ " + (r.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(r)) : String(format: "%.1f", r)))
                    .foregroundStyle(Theme.fg2)
            }
            if remaining > 0 {
                TimelineView(.everyMinute) { _ in
                    Text(L("Ends at %1", Theme.endsAt(remaining))).fontWeight(.semibold).foregroundStyle(Theme.fg)
                }
            }
        }
        .font(Theme.text(24 * u, .medium))
        .lineLimit(1)
        // whole, like the tv's row of texts: it may run past its column, never cut
        .fixedSize()
    }
}

/// the story always reads, whatever the artwork does behind it (qml: scrim around the story column)
struct StoryScrim: View {
    let u: CGFloat
    let margin: CGFloat
    /// height the story could still grow by: the shade is sized for the tallest
    var extra: CGFloat = 0
    var strength = 0.55
    var body: some View {
        GeometryReader { g in
            let h = g.size.height + extra
            Scrim(strength: strength)
                .frame(width: g.size.width * 1.9 + margin, height: h * 2.6 + 160 * u)
                .offset(x: -g.size.width * 0.45, y: g.size.height - h * 1.8 - 80 * u)
        }
    }
}
