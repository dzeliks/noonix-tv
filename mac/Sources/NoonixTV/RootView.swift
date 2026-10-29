import SwiftUI

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
            .onChange(of: g.size, initial: true) { app.size = g.size }
            .onChange(of: app.watchingNow, initial: true) { if app.watchingNow { app.watchStarted() } }
            .onChange(of: app.currentProfile?.id) { if app.watching { app.reloginCheck() } }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            // the app itself; under setup it's a blurred window in the middle (qml Setup frame)
            ZStack(alignment: .topLeading) {
                Group {
                    switch app.page {
                    case .home, .movies, .shows:
                        if let r = app.rails[app.page] { RailsPage(rails: r).id(app.page) }
                    case .library: LibraryPage()
                    case .search: SearchPage()
                    case .settings: SettingsPage()
                    }
                }
                .transition(.opacity)

                if app.detailStack.isEmpty {
                    TopNav().transition(.opacity)
                }

                ForEach(app.detailStack) { d in
                    if d === app.detailStack.last {
                        DetailsView(model: d)
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
            if let f = app.finder {
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
            if let e = app.extSheet {
                ExtensionSheetView(model: e).transition(.opacity).zIndex(8.8)
            }
            if let f = app.folderPicker {
                FolderPickerView(model: f).transition(.opacity).zIndex(8.8)
            }
            if let h = app.help {
                SourcesHelpView(model: h).transition(.opacity).zIndex(9)
            }
            if app.flow.picking {
                PickingView().transition(.opacity).zIndex(9.5)
            }
            // the key card slides up into place and drops away, the page dims behind it
            if app.entry.isOpen {
                Color.black.opacity(0.35).ignoresSafeArea().transition(.opacity).zIndex(7.5)
                    .onTapGesture {}
                KeyEntryView(model: app.entry)
                    .transition(.asymmetric(
                        insertion: .offset(y: 280 * app.u).combined(with: .opacity).animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.44)),
                        removal: .offset(y: 280 * app.u).combined(with: .opacity).animation(.easeIn(duration: 0.23))))
                    .zIndex(7.6)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.page)
        .animation(.easeInOut(duration: 0.26), value: app.detailStack.count)
        .animation(.easeOut(duration: 0.22), value: app.sources == nil)
        .animation(.easeOut(duration: 0.22), value: app.finder == nil)
        .animation(.easeInOut(duration: 0.3), value: app.playing)
        .animation(.easeOut(duration: 0.22), value: app.picker == nil)
        .animation(.easeOut(duration: 0.18), value: app.menu == nil)
        .animation(.easeOut(duration: 0.22), value: app.toastText)
        .animation(.easeOut(duration: 0.22), value: app.trakt == nil)
        .animation(.easeOut(duration: 0.22), value: app.site == nil)
        .animation(.easeOut(duration: 0.2), value: app.profileEdit == nil)
        .animation(.easeOut(duration: 0.23), value: app.entry.isOpen)
        .animation(.easeOut(duration: 0.18), value: app.help == nil)
        .animation(.easeOut(duration: 0.18), value: app.extSheet == nil)
        .animation(.easeOut(duration: 0.18), value: app.folderPicker == nil)
        .animation(.easeOut(duration: 0.18), value: app.flow.picking)
        .animation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.18), value: app.exitChoice == nil)
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
    @Namespace private var ns
    /// what the mouse is over: it lights up, only a click switches or opens (-1 the avatar)
    @State private var hover: Int?

    var body: some View {
        let u = app.u
        let margin = Theme.margin(u)
        ZStack(alignment: .top) {
            HStack {
                if let p = app.currentProfile {
                    // left of the tabs: ok there asks who's watching
                    let on = app.navFocused && app.navIndex < 0
                    Avatar(colour: p.color, letter: String(p.name.prefix(1)).uppercased(), size: 64 * u, image: p.avatar)
                        .overlay { Circle().stroke(.white, lineWidth: 4 * u).padding(-7 * u).opacity(on ? 1 : 0) }
                        .scaleEffect(on ? 1.16 : hover == -1 && Input.pointing ? 1.08 : 1)
                        .animation(Theme.lift, value: on)
                        .animation(Theme.lift, value: hover)
                        .contentShape(.circle)
                        .onHover { inside in hover = inside ? -1 : hover == -1 ? nil : hover }
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
        let focus = app.navFocused
        return HStack(spacing: 0) {
            ForEach(Array(Page.allCases.enumerated()), id: \.element) { i, p in
                // on the avatar no tab is on and the capsule fades out where it was
                let sel = app.navIndex < 0 ? (Page.allCases.firstIndex(of: app.page) ?? 1) : app.navIndex
                let on = app.navIndex == i
                let ink = focus && app.navIndex == i
                let lit = hover == i && Input.pointing && !on
                Group {
                    if let icon = p.icon {
                        Image(systemName: icon).font(.system(size: 26 * u, weight: .medium))
                    } else {
                        Text(L(p.title)).font(Theme.display(28 * u, on ? .semibold : .medium))
                    }
                }
                .foregroundStyle(ink ? Theme.focusFg : on || lit ? Theme.fg : Theme.fg2)
                .modifier(TabWidth(icon: p.icon != nil, u: u))
                .background { Capsule().fill(Color.white.opacity(lit ? 0.1 : 0)).animation(.easeOut(duration: 0.14), value: lit) }
                .background {
                    // the focus capsule glides between tabs
                    if sel == i {
                        Capsule()
                            .fill(focus ? Color.white : Color.white.opacity(0.16))
                            .opacity(app.navIndex < 0 ? 0 : 1)
                            .matchedGeometryEffect(id: "capsule", in: ns)
                    }
                }
                .contentShape(.capsule)
                .onHover { inside in hover = inside ? i : hover == i ? nil : hover }
                .onTapGesture {
                    app.navFocused = true
                    if app.navIndex != i { app.choose(p) } else { app.navFocused = false }
                }
            }
        }
        // qml dims the whole pill to 0.86 off focus; glass can't take opacity, so only its tabs
        .opacity(focus ? 1 : 0.86)
        .padding(7 * u)
        .frame(height: 78 * u)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
        .overlay { GlassRim(shape: Capsule(), u: u, glint: false) }
        // a small bounce as the capsule lands on the tab (qml's spring, ~6 % past it)
        .animation(.spring(response: 0.36, dampingFraction: 0.68), value: app.navIndex)
        .animation(.easeOut(duration: 0.16), value: focus)
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
                if let image, !image.isEmpty, let img = NSImage(contentsOfFile: image) {
                    Image(nsImage: img).resizable().scaledToFill().clipShape(.circle)
                } else {
                    Text(letter).font(Theme.rounded(size * 0.45, .bold)).foregroundStyle(.white)
                }
            }
    }
}
