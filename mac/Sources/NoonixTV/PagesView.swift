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
                         : files ? (Platform.tv ? L("No videos from your network yet") : L("No videos from this Mac yet")) : L("Save something for later"))
                        .font(Theme.display(32 * u, .medium)).foregroundStyle(Theme.fg2)
                    if !history {
                        Text(files ? (Platform.tv ? L("Add a network share from a NAS or computer: Settings › Sources") : Platform.ios ? L("Copy them into the Files app › Noonix TV") : L("Add the folders your movies and shows are in: Settings › Sources")) : L("Open a title's options and choose Add to Library"))
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

/// search (qml Search). a remote or a pad gets the tv terminal: results on the left, a right column
/// with the query, suggestions and the on-screen keyboard. a mouse, a keyboard or a finger get one
/// column: a real field (select, copy, paste), suggestion chips, then the results. results come in two
/// rows, shows then movies, each scrolling sideways
/// all | shows | movies for the one sideways row a small screen has: a white capsule slides to the pick
struct KindPill: View {
    let kind: String
    let u: CGFloat
    let pick: (String) -> Void
    @Namespace private var ns

    var body: some View {
        let opts = [("all", L("All")), ("show", L("Shows")), ("movie", L("Movies"))]
        HStack(spacing: 0) {
            ForEach(opts, id: \.0) { id, label in
                let on = kind == id
                ZStack {
                    // sized for the bold pick: nothing shifts when it moves
                    Text(label).font(Theme.display(24 * u, .semibold)).hidden()
                    Text(label).font(Theme.display(24 * u, on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.focusFg : Theme.fg2)
                }
                .padding(.horizontal, 26 * u)
                .frame(maxHeight: .infinity)
                .background {
                    if on { Capsule().fill(.white).matchedGeometryEffect(id: "pick", in: ns) }
                }
                .contentShape(.capsule)
                .onTapGesture { withAnimation(.easeOut(duration: 0.24)) { pick(id) } }
            }
        }
        .padding(6 * u)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            Capsule().fill(Color.white.opacity(0.1))
                .overlay { Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1 * u) }
        }
    }
}

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
        let topY = 150 * u + WindowState.shared.navDrop(u)
        let osk = s.osk
        // touch: the phone's own keyboard types. the layout ends where it starts
        let ime = Theme.touch
        let bottomY = (ime ? min(H, app.keyboardTop) : H) - 44 * u
        let gap = 40 * u
        let titleH = 31 * u * 1.3
        let sugs = s.suggestions
        let fullW = W - 2 * margin
        let fieldY = topY - 8 * u, fieldH = 64 * u
        let chipsShown = s.chipsShown
        let chipsY = fieldY + fieldH + 18 * u, chipsH = 56 * u
        let listTop = (chipsShown ? chipsY + chipsH : fieldY + fieldH) + 26 * u
        // the results' box: left of the column with the keyboard, under the field without it
        let areaTop = osk ? topY : listTop
        let areaRight = osk ? columnX - 56 * u : W
        // the rows fade out where they run on (into the keyboard column, or off the screen)
        let fadeEnd = (osk ? 150 : 190) * u
        let rowGap = MediaRowView.gap(u)
        // two rows share the height (a lone row gets the same size: nothing jumps between searches)
        let rowPoster = min(214, ((bottomY - areaTop) / 2 - 38 * u - rowGap - 30 * u) / 1.5 / u)
        // a docked phone keyboard leaves less than two rows: one row of both, sideways, right above it
        let rowPosterW = (bottomY - listTop - 26 * u) / 1.5
        let squeezed = !osk && rowPoster < 110
        // too little even for that: the field and the chips only, the results come back when the
        // keyboard goes (a chip tap sends it away)
        let tight = squeezed && rowPosterW < 110 * u
        let posterW = max(110 * u, min(230 * u, rowPosterW))
        let active = !app.navFocused && app.detailStack.isEmpty
        let loading = !s.popularKnown && !s.typing
        let showRows = [(0, s.shows, s.typing ? L("Shows") : L("Popular Shows")), (1, s.movies, s.typing ? L("Movies") : L("Popular Movies"))]
            .filter { !$0.1.items.isEmpty || loading }
        let rowH = MediaRowView.height("poster", u: u, posterW: rowPoster * u)
        // the keyboard on the terminal's 2160 grid, at the bottom of the column
        let ku = u / 2
        let kbH = 2 * 22 * ku + 4 * ((columnW - 2 * 22 * ku - 9 * 14 * ku) / 10 * 1.36) + 3 * 14 * ku
        let sugY = fieldY + fieldH + 30 * u
        let sugH = bottomY - kbH - 22 * u - sugY
        let fits = max(1, min(sugs.count, Int((sugH - titleH - 12 * u + 8 * u) / (46 * u + 8 * u))))
        let chipH = min(62 * u, (sugH - titleH - 12 * u - CGFloat(fits - 1) * 8 * u) / CGFloat(fits))
        let fieldX = osk ? columnX : margin, fieldW = osk ? columnW : fullW
        let keyboardUp = app.keyboardTop < H
        #if os(macOS)
        let editable = !osk && !ime, native = false
        #elseif os(tvOS)
        let editable = false, native = false
        #else
        // the system's own field (select, paste) whenever there's no on-screen keyboard
        let editable = false, native = !osk
        #endif
        ZStack(alignment: .topLeading) {
            Wallpaper()
            if !squeezed {
                // shows, then movies (the column with the keyboard cuts them off on the right)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showRows, id: \.0) { r, model, title in
                        MediaRowView(model: model, active: active && s.zone == "rows" && s.lastRow == r, u: u, width: areaRight,
                                     posterW: rowPoster * u, title: title, fadeEnd: fadeEnd,
                                     point: { i in app.navFocused = false; s.zone = "rows"; s.lastRow = r; model.index = i },
                                     activate: { i in
                                         guard model.items.indices.contains(i) else { return }
                                         model.index = i
                                         app.open(model.items[i])
                                     })
                            .frame(height: rowH, alignment: .top)
                    }
                }
                .frame(width: areaRight, height: bottomY - areaTop, alignment: .topLeading)
                // cut off at the keyboard column; without it the cards keep their lift room
                .mask { Rectangle().padding(osk ? 0 : -300 * u) }
                .offset(y: areaTop)
                // new results on the way over the old ones
                if s.busy && !(s.shows.items.isEmpty && s.movies.items.isEmpty) {
                    Spinner(size: 30 * u, color: Theme.fg2)
                        .offset(x: areaRight - margin - 30 * u, y: areaTop + 2 * u)
                }
            } else if !tight {
                // one row sideways, to the screen's edges, starting in line with the field
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: gap) {
                            ForEach(Array(s.grid.items.enumerated()), id: \.offset) { i, it in
                                Card(media: it, style: "poster", focused: active && s.zone == "grid" && s.grid.index == i, u: u, posterW: posterW)
                                    .contentShape(.rect)
                                    .onTapGesture { s.grid.index = i; Platform.hideKeyboard(); app.open(it) }
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, margin)
                        .padding(.vertical, 10 * u)
                    }
                    .onChange(of: s.grid.index) { _, i in if !Input.pointerHolds { withAnimation(Theme.slide) { proxy.scrollTo(i, anchor: .center) } } }
                }
                .frame(width: W, height: posterW * 1.5 + 24 * u)
                .offset(y: listTop - 8 * u)
            }
            // the first results on their way
            if s.busy && s.shows.items.isEmpty && s.movies.items.isEmpty && !tight {
                Spinner(size: 72 * u, color: .white)
                    .frame(width: areaRight)
                    .offset(y: squeezed ? listTop + (bottomY - listTop) / 2 - 36 * u : areaTop + 240 * u)
            }
            // nothing found: say so where the results would be
            let none = s.shows.items.isEmpty && s.movies.items.isEmpty
            if s.typing && !s.busy && (squeezed ? s.grid.items.isEmpty : none) && !tight {
                let q = s.query.trimmingCharacters(in: .whitespaces)
                VStack(spacing: 22 * u) {
                    Image(systemName: "magnifyingglass").font(.system(size: 64 * u, weight: .light)).foregroundStyle(Theme.fg3)
                    Text(none || s.kind == "all" ? L("No results for “%1”", q) : s.kind == "show" ? L("No shows for “%1”", q) : L("No movies for “%1”", q))
                        .font(Theme.display(34 * u, .semibold)).foregroundStyle(Theme.fg).lineLimit(1)
                        .frame(maxWidth: areaRight - 2 * margin)
                    Text(L("Check the spelling, or try the original title")).font(Theme.text(25 * u)).foregroundStyle(Theme.fg2)
                }
                .frame(width: areaRight)
                .offset(y: areaTop + (squeezed ? 40 : 160) * u)
            }

            // the query: the column's top with the keyboard, the full width without it; on a small
            // screen the all | shows | movies pill beside it
            HStack(spacing: 16 * u) {
                HStack(spacing: 16 * u) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20 * u, weight: .semibold)).foregroundStyle(Theme.fg2)
                        .frame(width: 26 * u, height: 26 * u)
                    if editable {
                        #if os(macOS)
                        EditLine(text: s.query, placeholder: L("Movies and shows"), size: 26 * u, focus: s.fieldFocus,
                                 holds: active && s.zone == "field" && app.menu == nil,
                                 edited: { s.query = $0 },
                                 done: { s.focusRows(0) },
                                 focused: { on in if on { app.navFocused = false; s.zone = "field" } })
                        #endif
                    } else if native {
                        ImeField(text: s.query, open: imeOpen, search: true, shown: true, size: 26 * u, placeholder: L("Movies and shows"),
                                 edited: { s.query = $0 }, done: {
                                     Platform.hideKeyboard()
                                     s.focusRows(0)
                                 })
                    } else {
                        FieldLine(text: s.query, placeholder: L("Movies and shows"), active: active && s.zone == "keys", size: 26 * u, u: u)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24 * u)
                .frame(maxWidth: .infinity)
                .frame(height: fieldH)
                .background {
                    let on = active && s.zone == "field" && editable || ime && keyboardUp
                    Capsule().fill(Color.white.opacity(on ? 0.14 : 0.1))
                        .overlay { Capsule().stroke(Color.white.opacity(on ? 0.3 : 0.14), lineWidth: 1 * u) }
                }
                .contentShape(.capsule)
                .onTapGesture {
                    app.navFocused = false
                    if osk { s.zone = "keys" } else { s.focusField() }
                }
                if squeezed {
                    KindPill(kind: s.kind, u: u) { k in
                        s.kind = k
                        // the keyboard covers the results: picking means looking
                        Platform.hideKeyboard()
                    }
                }
            }
            .frame(width: fieldW, height: fieldH)
            .offset(x: fieldX, y: fieldY)

            if chipsShown {
                // without the keyboard column: the suggestions as one row of chips under the field
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12 * u) {
                            ForEach(Array(sugs.enumerated()), id: \.offset) { i, t in
                                SearchChip(text: t, focused: !ime && active && s.zone == "chips" && s.chip == i, u: u, height: chipsH)
                                    .id(i)
                                    .onContinuousHover { phase in
                                        if case .active = phase, Input.pointerLive { app.navFocused = false; s.zone = "chips"; s.chip = i }
                                    }
                                    .onTapGesture { s.query = t; Platform.hideKeyboard() }
                            }
                        }
                        .padding(.horizontal, margin)
                    }
                    .onChange(of: s.chip) { _, i in if !Input.pointerHolds { withAnimation(Theme.slide) { proxy.scrollTo(i, anchor: .center) } } }
                }
                .frame(width: W, height: chipsH + 16 * u)
                .offset(y: chipsY - 8 * u)
            }
            if osk {
                if !sugs.isEmpty {
                    SearchSection(text: L("Suggestions"), u: u).offset(x: columnX, y: sugY)
                    ForEach(Array(sugs.prefix(fits).enumerated()), id: \.offset) { i, t in
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
        .onChange(of: squeezed, initial: true) { _, q in
            s.squeezed = q
            if q, s.zone == "rows" { s.zone = "grid" } else if !q, s.zone == "grid" { s.focusRows() }
        }
        .onAppear {
            s.upFromTop = { [weak app] in app?.navFocused = true }
            s.imeOpen = { imeOpen += 1 }
        }
        // the keyboard is picked by what came into search; the page stays alive under the others, so
        // the phone's keyboard goes with the page (or a title opened over it)
        .onChange(of: app.page == .search, initial: true) { _, here in
            if !here { Platform.hideKeyboard(); return }
            s.pickKeyboard()
            if !s.osk, s.zone == "keys" || s.zone == "suggestions" { s.zone = "field" }
            if s.osk, s.zone == "field" || s.zone == "chips" { s.zone = "keys" }
            // opened by touch: typing is what search is for
            if Theme.touch { DispatchQueue.main.async { imeOpen += 1 } }
        }
        .onChange(of: PointerMode.shared.kind) { _, k in
            guard app.page == .search else { return }
            if s.remoteish && !Theme.mouse && !Theme.touch { s.setOsk(true) } else if k == "keyboard" { s.setOsk(false) }
        }
        .onChange(of: Theme.mouse) { _, m in
            if app.page == .search, !m, s.remoteish, !Theme.touch { s.setOsk(true) }
        }
        .onChange(of: app.detailStack.isEmpty) { _, none in if !none { Platform.hideKeyboard() } }
    }
}

/// a suggestion under the field: a capsule key, white and lifted when focused (qml KeyCap fn)
private struct SearchChip: View {
    let text: String
    let focused: Bool
    let u: CGFloat
    let height: CGFloat

    var body: some View {
        Text(text).font(Theme.display(24 * u, .medium)).foregroundStyle(focused ? Theme.focusFg : .white).lineLimit(1)
            .padding(.horizontal, 24 * u)
            .frame(height: height)
            .background {
                Capsule().fill(focused ? Color.white.opacity(0.97) : Color.white.opacity(0.10))
                    .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 10 * u, y: 7 * u)
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(Theme.lift, value: focused)
            .padding(.vertical, 8 * u)
            .contentShape(.capsule)
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
