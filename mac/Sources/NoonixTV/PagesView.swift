#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// the frosted wallpaper the tv app puts behind library, search and settings: here the mac's own
/// desktop picture
struct Wallpaper: View {
    @State private var img: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
                    .blur(radius: 70)
                    .saturation(1.3)
                    .overlay { Color.black.opacity(0.55) }
                    .transition(.opacity)
            }
        }
        .clipped()
        .task {
            #if os(macOS)
            guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
            #else
            // no wallpaper to borrow on ios
            guard let url = URL?.none else { return }
            #endif
            let got = await ImageStore.shared.load(url, px: 1280)
            withAnimation(.easeOut(duration: 0.3)) { img = got }
        }
    }
}

/// the videos on this mac, the watchlist and what was watched, in a grid (qml Library)
struct LibraryPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let u = app.u, W = app.size.width, H = app.size.height
        let m = app.library
        let margin = Theme.margin(u)
        let history = m.section == "history", files = m.section == "files"
        let cellW = (history ? 440 : 254) * u, cellH = (history ? 370 : 380) * u
        let gridW = W - 2 * (margin - 20 * u)
        let cols = max(1, Int(gridW / cellW))
        let active = !app.navFocused && app.detailStack.isEmpty
        ZStack(alignment: .topLeading) {
            Wallpaper()
            Text(L("Library")).font(Theme.display(52 * u, .bold)).foregroundStyle(Theme.fg)
                .offset(x: margin, y: 174 * u)
            GlassEffectContainer(spacing: 24 * u) {
                HStack(spacing: 24 * u) {
                    ForEach(Array(GridModel.librarySections.enumerated()), id: \.offset) { i, s in
                        GlassButton(text: s == "history" ? L("History") : s == "files" ? L("On This Mac") : L("Watchlist"), primary: m.section == s,
                                    focused: active && m.head && m.headIndex == i, u: u)
                            .onContinuousHover { phase in
                                if case .active = phase, Input.pointerLive { app.navFocused = false; m.head = true; m.headIndex = i }
                            }
                            .onTapGesture { m.pickSection(s) }
                    }
                }
            }
            .offset(x: margin, y: 260 * u)
            if history {
                Text(L("Recently watched")).font(Theme.text(23 * u)).foregroundStyle(Theme.fg3)
                    .frame(width: W - margin, alignment: .trailing)
                    .offset(y: 260 * u + 25 * u)
            }

            if m.items.isEmpty && m.loading {
                // loading with nothing to show yet: placeholder cards where the grid will be
                SkeletonGrid(style: history ? "landscape" : "poster", cols: cols, cellW: cellW, cellH: cellH,
                             height: H - 380 * u - 40 * u, cardW: (history ? 400 : 214) * u, u: u)
                    .offset(x: margin - 20 * u, y: 380 * u)
                    .transition(.opacity)
            } else if m.items.isEmpty {
                VStack(spacing: 28 * u) {
                    Text(history ? L("Your watched movies and episodes will appear here")
                         : files ? L("No videos from this Mac yet") : L("Save something for later"))
                        .font(Theme.display(32 * u, .medium)).foregroundStyle(Theme.fg2)
                    if !history {
                        Text(files ? (Platform.ios ? L("Copy them into the Files app › Noonix TV") : L("Add the folders your movies and shows are in: Settings › Sources")) : L("Open a title's options and choose Add to Library"))
                            .font(Theme.text(24 * u)).foregroundStyle(Theme.fg3)
                    }
                }
                .frame(width: W)
                .offset(y: 380 * u + 100 * u)
            } else {
                PosterGrid(model: m, style: history ? "landscape" : "poster", cols: cols, cellW: cellW, cellH: cellH,
                           height: H - 380 * u - 40 * u, active: active && !m.head)
                    .offset(x: margin - 20 * u, y: 380 * u)
                KeyHint(key: "MENU", label: L("Options"), u: u * 0.82, pointLabel: Platform.ios ? L("Hold an item for options") : "")
                    .frame(width: W - margin, alignment: .trailing)
                    .offset(y: 190 * u)
                    .opacity(active && !m.head && !files ? 1 : 0)
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
        .onChange(of: cols, initial: true) { m.columns = cols }
    }
}

extension GridModel {
    static let librarySections = ["files", "watchlist", "history"]

    /// the library page: on the videos on this mac when there are any, until a tab is picked
    func openLibrary() async {
        if !picked, section != "files", let d = try? await Core.shared.raw("library.status"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], ((o["files"] as? NSNumber)?.intValue ?? 0) > 0 {
            section = "files"
            headIndex = 0
        }
        if !picked { headIndex = Self.librarySections.firstIndex(of: section) ?? 1 }
        await load()
    }

    func pickSection(_ s: String) {
        picked = true
        guard section != s else { return }
        section = s
        items = []
        index = 0
        Task { await load() }
    }

    /// library: the tabs over the grid; false = up into the top bar
    func libraryKey(_ k: Key, app: AppModel) -> Bool {
        if head {
            switch k {
            case .left: headIndex = max(0, headIndex - 1)
            case .right: headIndex = min(Self.librarySections.count - 1, headIndex + 1)
            case .ok: pickSection(Self.librarySections[headIndex])
            case .down: if !items.isEmpty { head = false }
            case .up, .back: return false
            default: break
            }
            return true
        }
        // files have no card options
        if k == .menu, section == "files" { return true }
        if key(k, app: app) { return true }
        if k == .back { return false }
        head = true
        return true
    }
}

/// a scrolling grid of cards with the focused cell kept in view
struct PosterGrid: View {
    @Environment(AppModel.self) private var app
    let model: GridModel
    let style: String
    let cols: Int
    let cellW: CGFloat
    let cellH: CGFloat
    let height: CGFloat
    let active: Bool
    var posterW: CGFloat?
    @State private var heldLine: Int?

    var body: some View {
        let u = app.u
        let line = model.index / max(1, cols)
        let lines = (model.items.count + cols - 1) / max(1, cols)
        // the focused line stays in view, a line's worth of room above it once it moved down
        let maxScroll = max(0, CGFloat(lines) * cellH - height + 40 * u)
        let keyed = min(maxScroll, max(0, CGFloat(heldLine ?? line) * cellH - cellH * 0.6))
        let scroll = model.scroll.y ?? keyed
        let first = max(0, Int(scroll / cellH) - 1) * cols
        let last = min(model.items.count, first + (Int(height / cellH) + 3) * cols)
        ZStack(alignment: .topLeading) {
            ForEach(first..<last, id: \.self) { i in
                let it = model.items[i]
                Card(media: it, style: style, focused: active && model.index == i, u: u, posterW: posterW)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active = phase, Input.pointerLive { app.navFocused = false; model.head = false; model.index = i; if app.page == .search { app.search.zone = "grid" } }
                    }
                    .onTapGesture { model.index = i; app.open(it) }
                    #if os(iOS)
                    .onLongPressGesture(minimumDuration: 0.45) {
                        app.navFocused = false; model.head = false; model.index = i
                        if app.page == .search { app.search.zone = "grid" }
                        _ = app.key(.menu)
                    }
                    #endif
                    .zIndex(active && model.index == i ? 1 : 0)
                    .geometryGroup()
                    .offset(x: CGFloat(i % cols) * cellW + 20 * u, y: CGFloat(i / cols) * cellH + 20 * u - scroll)
            }
        }
        .frame(width: CGFloat(cols) * cellW, height: height, alignment: .topLeading)
        .clipped()
        .animation(model.scroll.y == nil ? Theme.slide : nil, value: scroll)
        // the pointer moving the focus doesn't scroll the grid (the wheel does)
        .onChange(of: model.index) { old, _ in heldLine = Input.pointerHolds ? heldLine ?? old / max(1, cols) : nil }
        .onChange(of: PointerMode.shared.on) { _, on in if !on { heldLine = nil } }
        .onChange(of: keyed + maxScroll, initial: true) {
            model.scroll.start = keyed
            model.scroll.end = maxScroll
            model.scroll.rowsTop = cellH
            model.scroll.height = height
        }
    }
}

/// search laid out like the tv terminal: results on the left, the query on the right (the mac
/// has a keyboard: the field takes typing, no on-screen keys)
struct SearchPage: View {
    @Environment(AppModel.self) private var app
    /// bumped to bring up the system keyboard (touch)
    @State private var imeOpen = 0

    var body: some View {
        let u = app.u, W = app.size.width, H = app.size.height
        let s = app.search
        let margin = Theme.margin(u)
        let columnW = 575 * u
        let columnX = W - margin - columnW
        let topY = 150 * u
        // touch: the phone's own keyboard types, ours goes away. the layout ends where it starts
        let ime = Theme.touch
        let bottomY = (ime ? min(H, app.keyboardTop) : H) - 44 * u
        let gap = 40 * u
        let titleH = 31 * u * 1.3
        let sugs = s.suggestions
        // touch: one column over the full width (field, suggestion chips, results). a docked keyboard
        // leaves less than a row: the results become one row sideways right above it
        let fullW = W - 2 * margin
        let imeCols = max(4, min(8, Int(((fullW + gap) / (230 * u + gap)).rounded())))
        let fieldY = topY - 8 * u
        let chipsShown = ime && !sugs.isEmpty
        let chipsY = fieldY + 64 * u + 18 * u, chipsH = 56 * u
        let listTop = (chipsShown ? chipsY + chipsH : fieldY + 64 * u) + 26 * u
        let fullPosterW = (fullW - CGFloat(imeCols - 1) * gap) / CGFloat(imeCols)
        let squeezed = ime && bottomY - listTop < titleH + 18 * u + 10 * u + fullPosterW * 1.5 + gap
        let rowPosterW = (bottomY - listTop - 26 * u) / 1.5
        // too little even for that (a docked keyboard on a phone): the field and the chips only, the
        // results come back when the keyboard goes (a chip tap sends it away)
        let tight = squeezed && rowPosterW < 110 * u
        let posterW = !ime ? (columnX - 64 * u - margin - 3 * gap) / 4
            : squeezed ? max(110 * u, min(fullPosterW, rowPosterW)) : fullPosterW
        let cols = ime ? imeCols : 4
        let cellW = posterW + gap, cellH = posterW * 1.5 + gap
        let titleY = ime ? listTop : topY
        let gridY = titleY + titleH + 8 * u
        let gridW = ime ? fullW : columnX - margin
        let active = !app.navFocused && app.detailStack.isEmpty
        // the keyboard on the terminal's 2160 grid, at the bottom of the column
        let ku = u / 2
        let kbH = 2 * 22 * ku + 4 * ((columnW - 2 * 22 * ku - 9 * 14 * ku) / 10 * 1.36) + 3 * 14 * ku
        let sugY = fieldY + 64 * u + 30 * u
        let sugH = bottomY - kbH - 22 * u - sugY
        let chipH = min(62 * u, (sugH - titleH - 12 * u - 5 * 8 * u) / 6)
        let fieldX = ime ? margin : columnX, fieldW = ime ? fullW : columnW
        let keyboardUp = app.keyboardTop < H
        ZStack(alignment: .topLeading) {
            Wallpaper()
            if !squeezed {
                SearchSection(text: s.busy ? L("Searching…") : s.typing ? (s.grid.items.isEmpty ? L("No results") : L("Top results")) : L("Popular"), u: u)
                    .offset(x: margin, y: titleY)
                PosterGrid(model: s.grid, style: "poster", cols: cols, cellW: cellW, cellH: cellH,
                           height: bottomY - gridY, active: active && s.zone == "grid", posterW: posterW)
                    // the grid's 20 of lift room, where qml's cells hold their cards 10 down and centred
                    .offset(x: margin - 20 * u, y: gridY)
            } else if !tight {
                // one row sideways, to the screen's edges, starting in line with the field
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: gap) {
                        ForEach(Array(s.grid.items.enumerated()), id: \.offset) { i, it in
                            Card(media: it, style: "poster", focused: false, u: u, posterW: posterW)
                                .contentShape(.rect)
                                .onTapGesture { s.grid.index = i; Platform.hideKeyboard(); app.open(it) }
                        }
                    }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 10 * u)
                }
                .frame(width: W, height: posterW * 1.5 + 24 * u)
                .offset(y: listTop - 8 * u)
            }
            // new results on the way over the old ones
            if s.busy && !s.grid.items.isEmpty && !squeezed {
                SearchSection(text: L("Searching…"), u: u).hidden()
                    .overlay(alignment: .trailing) { Spinner(size: 30 * u, color: Theme.fg2).offset(x: 48 * u) }
                    .offset(x: margin, y: titleY)
            }
            // the first results on their way
            if s.busy && s.grid.items.isEmpty && !tight {
                Spinner(size: 72 * u, color: .white)
                    .frame(width: gridW)
                    .offset(x: margin, y: squeezed ? listTop + (bottomY - listTop) / 2 - 36 * u : gridY + 10 * u + 240 * u)
            }
            // popular on its way: placeholder posters where they'll be
            if !s.typing && s.grid.items.isEmpty && !s.popularKnown && !squeezed {
                SkeletonGrid(style: "poster", cols: cols, cellW: cellW, cellH: cellH, height: bottomY - gridY, cardW: posterW, u: u)
                    .offset(x: margin - 20 * u, y: gridY)
                    .transition(.opacity)
            }
            // nothing found: say so where the results would be
            if s.typing && !s.busy && s.grid.items.isEmpty && !tight {
                VStack(spacing: 22 * u) {
                    Image(systemName: "magnifyingglass").font(.system(size: 64 * u, weight: .light)).foregroundStyle(Theme.fg3)
                    Text(L("No results for “%1”", s.query.trimmingCharacters(in: .whitespaces)))
                        .font(Theme.display(34 * u, .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                    Text(L("Check the spelling, or try the original title")).font(Theme.text(25 * u)).foregroundStyle(Theme.fg2)
                }
                .frame(width: gridW)
                .offset(x: margin, y: squeezed ? listTop + 40 * u : gridY + 10 * u + 160 * u)
            }

            // the query (the right column's top; touch: across the page)
            HStack(spacing: 16 * u) {
                Image(systemName: "magnifyingglass").font(.system(size: 20 * u, weight: .semibold)).foregroundStyle(Theme.fg2)
                    .frame(width: 26 * u, height: 26 * u)
                FieldLine(text: s.query, placeholder: L("Movies and shows"), active: !ime || keyboardUp, size: 26 * u, u: u)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24 * u)
            .frame(width: fieldW, height: 64 * u)
            .background {
                Capsule().fill(Color.white.opacity(0.1))
                    .overlay { Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1 * u) }
            }
            .overlay {
                if ime {
                    ImeField(text: s.query, open: imeOpen, search: true, edited: { s.query = $0 }, done: {
                        Platform.hideKeyboard()
                        if !s.grid.items.isEmpty { s.zone = "grid" }
                    })
                    .allowsHitTesting(false)
                }
            }
            .contentShape(.capsule)
            .onTapGesture {
                app.navFocused = false; s.zone = "keys"
                if ime { imeOpen += 1 }
            }
            .offset(x: fieldX, y: fieldY)

            if chipsShown {
                // touch: the suggestions as one row of chips under the field
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12 * u) {
                        ForEach(Array(sugs.enumerated()), id: \.offset) { _, t in
                            Text(t).font(Theme.display(24 * u, .medium)).foregroundStyle(.white).lineLimit(1)
                                .padding(.horizontal, 24 * u)
                                .frame(height: chipsH)
                                .background { Capsule().fill(Color.white.opacity(0.10)) }
                                .contentShape(.capsule)
                                .onTapGesture { s.query = t; Platform.hideKeyboard() }
                        }
                    }
                    .padding(.horizontal, margin)
                }
                .frame(width: W, height: chipsH)
                .offset(y: chipsY)
            }
            if !ime {
                if !sugs.isEmpty {
                    SearchSection(text: L("Suggestions"), u: u).offset(x: columnX, y: sugY)
                    ForEach(Array(sugs.enumerated()), id: \.offset) { i, t in
                        SuggestionChip(text: t, focused: active && s.zone == "suggestions" && s.suggestion == i, u: u)
                            .frame(width: columnW, height: chipH)
                            .offset(x: columnX, y: sugY + titleH + 12 * u + CGFloat(i) * (chipH + 8 * u))
                            .onContinuousHover { phase in
                                if case .active = phase, Input.pointerLive { app.navFocused = false; s.zone = "suggestions"; s.suggestion = i }
                            }
                            .onTapGesture { s.query = t }
                    }
                }
                KeyboardView(model: s.kb, u: ku, width: columnW, active: active && s.zone == "keys")
                    .offset(x: columnX, y: bottomY - kbH)
                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive { app.navFocused = false; s.zone = "keys" } }
            }
        }
        .frame(width: W, height: H, alignment: .topLeading)
        .clipped()
        .task(id: s.query) {
            try? await Task.sleep(for: .milliseconds(320))
            if !Task.isCancelled { await s.run() }
        }
        .onChange(of: cols, initial: true) { _, c in s.cols = c }
        .onAppear { s.upFromTop = { [weak app] in app?.navFocused = true } }
        // opened by touch: typing is what search is for. the page stays alive under the others, so
        // the keyboard goes with the page (or a title opened over it)
        .onChange(of: app.page == .search, initial: true) { _, here in
            if !here { Platform.hideKeyboard() } else if Theme.touch { DispatchQueue.main.async { imeOpen += 1 } }
        }
        .onChange(of: app.detailStack.isEmpty) { _, none in if !none { Platform.hideKeyboard() } }
    }
}

/// a small caps title in the search page (qml Search Section)
private struct SearchSection: View {
    let text: String
    let u: CGFloat

    var body: some View {
        Text(text).font(Theme.display(31 * u, .semibold)).foregroundStyle(Theme.fg2)
            .frame(height: 31 * u * 1.3)
    }
}

/// a suggestion: a dark key with the title, white and lifted when focused (qml KeyCap + Marquee)
private struct SuggestionChip: View {
    let text: String
    let focused: Bool
    let u: CGFloat

    var body: some View {
        Text(text).font(Theme.display(25 * u, .medium)).foregroundStyle(focused ? Theme.focusFg : .white)
            .lineLimit(1)
            .padding(.horizontal, 22 * u)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14 * u)
                    .fill(focused ? Color.white.opacity(0.97) : Color.white.opacity(0.10))
                    .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 10 * u, y: 7 * u)
            }
            .scaleEffect(focused ? 1.04 : 1)
            .animation(Theme.lift, value: focused)
            .contentShape(.rect)
    }
}

extension SearchModel {
    /// the three zones (qml Search); false = up into the top bar
    func key(_ k: Key, app: AppModel) -> Bool {
        switch zone {
        case "suggestions":
            let n = suggestions.count
            switch k {
            case .up: if suggestion > 0 { suggestion -= 1 } else { return false }
            case .down:
                if suggestion < n - 1 { suggestion += 1 } else { zone = "keys"; kb.enterAt("top", 0.5) }
            case .left: if !grid.items.isEmpty { zone = "grid" }
            case .ok: if let t = suggestions[safe: suggestion] { query = t }
            case .back: return false
            default: break
            }
            if n == 0 { zone = "keys" }
            return true
        case "grid":
            grid.columns = cols
            switch k {
            case .right where grid.index % cols == cols - 1 || grid.index == grid.items.count - 1:
                zone = suggestions.isEmpty ? "keys" : "suggestions"
                return true
            case .up where grid.index < cols: return false
            case .back: return false
            default: return grid.key(k, app: app) || true
            }
        default:
            if k == .back { return false }
            return kb.key(k)
        }
    }
}
