import SwiftUI
#if !os(macOS)
import UIKit
#endif

/// the window: pages under the top bar, details over them, then sources, the finder, the player
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black
                if g.size.width > 0 {
                    content.coordinateSpace(.named("root")).scaleEffect(app.splash?.uiScale ?? 1)
                    if let s = app.splash { SplashView(model: s, size: g.size).zIndex(30) }
                }
            }
            .onChange(of: g.size, initial: true) {
                #if !os(macOS)
                // the notch and the home bar (qml Main safeProbe): set before the size makes it all lay out again
                if let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first {
                    Theme.safeSide = max(w.safeAreaInsets.left, w.safeAreaInsets.right)
                    Theme.safeBottom = w.safeAreaInsets.bottom
                }
                #endif
                app.size = g.size
            }
            .onChange(of: app.watchingNow, initial: true) { if app.watchingNow { app.watchStarted() } }
            .onChange(of: app.currentProfile?.id) { if app.watching { app.reloginCheck() } }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func page(_ p: Page) -> some View {
        switch p {
        case .home, .movies, .shows:
            if let r = app.rails[p] { RailsPage(rails: r).id(ObjectIdentifier(r)) }
        case .library: LibraryPage()
        case .search: SearchPage()
        case .settings: SettingsPage()
        }
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            // the app itself; under setup it's a blurred window in the middle (qml Setup frame)
            ZStack(alignment: .topLeading) {
                // a page stays built once shown or warmed, a switch only shows another one
                // (settings is made each time: it starts over on its first section)
                ZStack(alignment: .topLeading) {
                    ForEach(Page.allCases.filter { $0 == app.page || $0 == app.pageBehind || ($0 != .settings && app.built.contains($0)) }) { p in
                        page(p)
                            // one layer: a fade would thin its shading along with the rest
                            .compositingGroup()
                            .opacity(p == app.page || p == app.pageBehind ? 1 : 0)
                            .allowsHitTesting(p == app.page)
                            .environment(\.pageLive, p == app.page && app.detailStack.isEmpty)
                            .zIndex(p == app.page ? 1 : p == app.pageBehind ? 0.5 : 0)
                    }
                }
                .animation(.easeInOut(duration: AppModel.pageFade), value: app.page)

                if app.detailStack.isEmpty {
                    TopNav().transition(.opacity)
                }

                ForEach(app.detailStack) { d in
                    if d === app.detailStack.last {
                        // one layer: a fade would thin its shading along with the rest
                        DetailsView(model: d)
                            .compositingGroup()
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }
            }
            .modifier(SetupWindow(reveal: app.setup?.reveal, u: app.u))

            if let s = app.sources {
                SourcesView(model: s).transition(.opacity).zIndex(2)
            }
            if app.playing {
                PlayerView(player: app.player).transition(.opacity).zIndex(3)
            }
            if let f = app.finder, f.shown {
                FinderView(model: f).transition(.opacity).zIndex(4)
            }
            if let m = app.menu {
                CardMenuView(model: m).transition(.opacity).zIndex(4.5)
            }
            // slides in from the right edge with a spring, out quickly
            if let t = app.toastText {
                ToastView(text: t)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).animation(.spring(response: 0.5, dampingFraction: 0.82)),
                                            removal: .move(edge: .trailing).animation(.easeIn(duration: 0.24))))
                    .zIndex(7)
            }
            if let p = app.picker {
                ProfilePicker(model: p).transition(.opacity).zIndex(5)
            }
            if let t = app.trakt {
                TraktCodeView(model: t).transition(.opacity.combined(with: .scale(scale: 0.96))).zIndex(6)
            }
            if let t = app.traktChoice {
                TraktChoiceView(model: t).transition(.opacity.combined(with: .scale(scale: 0.96))).zIndex(8.7)
            }
            if let s = app.site {
                SiteCardView(model: s).transition(.opacity.combined(with: .scale(scale: 0.96))).zIndex(6)
            }
            if let s = app.setup {
                SetupView(model: s).transition(.opacity).zIndex(5.5)
            }
            // the profile card floats over the picker or the wizard, which show through its glass
            if let p = app.profileEdit {
                ProfileEditView(model: p).transition(.opacity.combined(with: .scale(scale: 0.96))).zIndex(5.8)
            }
            if let c = app.exitChoice {
                ExitPromptView(choice: c).transition(.opacity).zIndex(9)
            }
            if let c = app.confirm {
                ConfirmView(model: c).transition(.opacity).zIndex(9)
            }
            if let e = app.extSheet {
                ExtensionSheetView(model: e).transition(.opacity).zIndex(8.8)
            }
            if let f = app.folderPicker {
                FolderPickerView(model: f).transition(.opacity).zIndex(8.8)
            }
            if let p = app.profileSheet {
                ProfileSheetView(model: p).transition(.opacity).zIndex(8.8)
            }
            if let h = app.help {
                SourcesHelpView(model: h).transition(.opacity).zIndex(9)
            }
            if let c = app.choices {
                ChoicesView(model: c).transition(.opacity).zIndex(9.2)
            }
            if let b = app.bindSheet {
                BindSheetView(model: b).transition(.opacity).zIndex(9.2)
            }
            if let s = app.speed {
                SpeedCheckView(model: s).transition(.opacity).zIndex(9.2)
            }
            // the key card slides up into place and drops away, the page dims behind it. over every
            // sheet: the folder picker and the extension sheet ask for text too
            if app.entry.isOpen {
                Color.black.opacity(0.35).ignoresSafeArea().transition(.opacity).zIndex(9.5)
                    .onTapGesture { app.entry.cancel() }
                KeyEntryView(model: app.entry)
                    .transition(.asymmetric(
                        insertion: .offset(y: 280 * app.u).combined(with: .opacity).animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.44)),
                        removal: .offset(y: 280 * app.u).combined(with: .opacity).animation(.easeIn(duration: 0.23))))
                    .zIndex(9.6)
            }
        }
        .animation(.easeInOut(duration: 0.26), value: app.detailStack.count)
        .animation(.easeOut(duration: 0.22), value: app.sources == nil)
        .animation(.easeOut(duration: 0.22), value: app.finder?.shown == true)
        .animation(.easeInOut(duration: 0.3), value: app.playing)
        .animation(.easeOut(duration: 0.22), value: app.picker == nil)
        .animation(.easeOut(duration: 0.18), value: app.choices == nil)
        .animation(.easeOut(duration: 0.18), value: app.bindSheet == nil)
        .animation(.easeOut(duration: 0.2), value: app.speed == nil)
        .animation(.easeOut(duration: 0.18), value: app.menu == nil)
        .animation(.easeOut(duration: 0.22), value: app.toastText)
        .animation(.easeOut(duration: 0.22), value: app.trakt == nil)
        .animation(.easeOut(duration: 0.22), value: app.site == nil)
        .animation(.easeOut(duration: 0.2), value: app.profileEdit == nil)
        .animation(.easeOut(duration: 0.23), value: app.entry.isOpen)
        .animation(.easeOut(duration: 0.18), value: app.help == nil)
        .animation(.easeOut(duration: 0.18), value: app.extSheet == nil)
        .animation(.easeOut(duration: 0.18), value: app.folderPicker == nil)
        .animation(.easeOut(duration: 0.18), value: app.profileSheet == nil)
        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.18), value: app.exitChoice == nil)
        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.18), value: app.confirm == nil)
    }
}

/// the app as a blurred window in the middle while setup runs (reveal 0) -> the whole screen,
/// sharp (reveal 1); darker by scaling, not subtracting: the empty app's placeholders still show
private struct SetupWindow: ViewModifier {
    let reveal: CGFloat?
    let u: CGFloat

    func body(content: Content) -> some View {
        if let r = reveal {
            content
                .blur(radius: 32 * u * (1 - r))
                .clipShape(RoundedRectangle(cornerRadius: 60 * u * (1 - r)))
                .overlay { Color.black.opacity(0.62 * (1 - r)) }
                .scaleEffect(0.84 + 0.16 * r)
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}

/// the glass tab pill (tvos 26) with the profile on the left and the clock on the right (qml TopNav)
struct TopNav: View {
    @Environment(AppModel.self) private var app
    /// where each tab sits in the pill: the capsule goes there
    @State private var tabs: [Int: CGRect] = [:]
    /// what the mouse is over: it lights up, only a click switches or opens (-1 the avatar)
    @State private var hover: Int?

    var body: some View {
        let u = app.u
        let margin = Theme.margin(u)
        ZStack(alignment: .top) {
            HStack {
                if let p = app.currentProfile {
                    // left of the tabs: ok there asks who's watching
                    let on = app.navFocused && app.navIndex < 0 && !Theme.touch
                    Avatar(colour: p.color, letter: String(p.name.prefix(1)).uppercased(), size: 64 * u, image: p.avatar)
                        .overlay { Circle().stroke(.white, lineWidth: 4 * u).padding(-7 * u).opacity(on ? 1 : 0) }
                        .scaleEffect(on ? 1.16 : hover == -1 && Input.pointing ? 1.08 : 1)
                        .animation(Theme.lift, value: on)
                        .animation(Theme.lift, value: hover)
                        .contentShape(.circle)
                        .hover { inside in hover = inside ? -1 : hover == -1 ? nil : hover }
                        .onTapGesture { app.openPicker() }
                }
                Spacer()
                TimelineView(.everyMinute) { ctx in
                    Text(Theme.clock(ctx.date))
                        .font(Theme.rounded(40 * u, .bold))
                        .foregroundStyle(Theme.fg)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, margin)
            .frame(height: 78 * u)
            .padding(.top, 44 * u)

            pill(u)
                .padding(.top, 44 * u)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150 * u, alignment: .top)
    }

    private func pill(_ u: CGFloat) -> some View {
        // white capsule for the remote's focus; a finger just sees where it is
        let focus = app.navFocused && !Theme.touch
        // on the avatar no tab is on and the capsule fades out where it was
        let sel = app.navIndex < 0 ? (Page.allCases.firstIndex(of: app.page) ?? 1) : app.navIndex
        let spot = tabs[sel] ?? .zero
        return ZStack(alignment: .topLeading) {
            // the focus capsule glides between tabs, under the letters
            Capsule()
                .fill(focus ? Color.white : Color.white.opacity(0.16))
                .frame(width: spot.width, height: spot.height)
                .offset(x: spot.minX, y: spot.minY)
                .opacity(app.navIndex < 0 ? 0 : 1)
            tabRow { i, p in
                let lit = hover == i && Input.pointing && app.navIndex != i
                label(i, p, u, ink: false)
                    .background { Capsule().fill(Color.white.opacity(lit ? 0.1 : 0)).animation(.easeOut(duration: 0.14), value: lit) }
                    .contentShape(.capsule)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("pill")) } action: { tabs[i] = $0 }
                    .hover { inside in hover = inside ? i : hover == i ? nil : hover }
                    .onTapGesture {
                        app.navFocused = true
                        if app.navIndex != i { app.choose(p) } else { app.navFocused = false }
                    }
            }
            // a black copy of the tabs seen only through the capsule, so letters ink as it passes
            tabRow { i, p in label(i, p, u, ink: true) }
                .mask(alignment: .topLeading) {
                    Capsule().frame(width: spot.width, height: spot.height).offset(x: spot.minX, y: spot.minY)
                }
                .opacity(focus && app.navIndex >= 0 ? 1 : 0)
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named("pill"))
        // qml dims the whole pill to 0.86 off focus; glass can't take opacity, so only its tabs
        .opacity(focus ? 1 : 0.86)
        .padding(7 * u)
        .frame(height: 78 * u)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
        .overlay { GlassRim(shape: Capsule(), u: u, glint: false) }
        // a light bounce as the capsule lands on the tab (qml's spring, ~2 % past it)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: app.navIndex)
        .animation(.easeOut(duration: 0.16), value: focus)
    }

    private func tabRow<Tab: View>(@ViewBuilder _ tab: @escaping (Int, Page) -> Tab) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in tab(i, p) }
        }
    }

    private func label(_ i: Int, _ p: Page, _ u: CGFloat, ink: Bool) -> some View {
        let on = app.navIndex == i
        let lit = hover == i && Input.pointing && !on
        return Group {
            if let icon = p.icon {
                Image(systemName: icon).font(.system(size: 26 * u, weight: .medium))
            } else {
                Text(L(p.title)).font(Theme.display(28 * u, .medium))
            }
        }
        .foregroundStyle(ink ? Theme.focusFg : on || lit ? Theme.fg : Theme.fg2)
        .modifier(TabWidth(icon: p.icon != nil, u: u))
    }
}

/// an icon tab is 76 wide, a text tab its label + 56; the capsule sits 7 in
private struct TabWidth: ViewModifier {
    let icon: Bool
    let u: CGFloat
    func body(content: Content) -> some View {
        if icon {
            content.frame(width: 76 * u, height: 64 * u)
        } else {
            content.padding(.horizontal, 28 * u).frame(height: 64 * u).fixedSize()
        }
    }
}

/// a profile's circle: its colour with a little depth and the initial on it
struct Avatar: View {
    let colour: String
    let letter: String
    let size: CGFloat
    /// a picture from the avatars folder instead of the letter
    var image: String?
    /// or one in memory (a profile file's)
    var picture: NSImage?

    private var base: Color {
        switch colour {
        case "pink": Color(red: 1, green: 0x5F / 255, blue: 0xA2 / 255)
        case "blue": Color(red: 0x3D / 255, green: 0x8B / 255, blue: 1)
        case "orange": Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
        case "purple": Color(red: 0xA5 / 255, green: 0x6B / 255, blue: 1)
        default: Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
        }
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [base.mix(with: .white, by: 0.15), base.mix(with: .black, by: 0.18)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                if let img = picture ?? image.flatMap({ $0.isEmpty ? nil : NSImage(contentsOfFile: $0) }) {
                    Image(nsImage: img).resizable().scaledToFill().clipShape(.circle)
                } else {
                    Text(letter).font(Theme.rounded(size * 0.45, .bold)).foregroundStyle(.white)
                }
            }
    }
}

extension EnvironmentValues {
    /// the page in front (not one kept alive under it, nor under a title's details)
    @Entry var pageLive = true
}
