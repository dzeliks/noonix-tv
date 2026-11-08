#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// who's watching (qml Main's profile picker): the profiles in a line, then "add profile", and
/// "sign in automatically" under them; menu on a profile edits it
@MainActor @Observable
final class PickerModel {
    var index = 0
    /// the focus is on "sign in automatically"
    var onAuto = false

    init(app: AppModel) {
        index = app.profiles?.profiles.firstIndex { $0.id == app.profiles?.current } ?? 0
    }

    func key(_ k: Key, app: AppModel) {
        let count = (app.profiles?.profiles.count ?? 0) + 1
        if onAuto {
            switch k {
            case .up: onAuto = false
            case .ok: app.setAutoLogin(!app.autoLogin)
            case .back: app.closePicker()
            default: break
            }
            return
        }
        switch k {
        case .left: index = max(0, index - 1)
        case .right: index = min(count - 1, index + 1)
        case .down: onAuto = true
        case .ok: activate(index, app: app)
        case .menu: if let p = app.profiles?.profiles[safe: index] { app.editProfile(p) }
        case .back: app.closePicker()
        default: break
        }
    }

    func activate(_ i: Int, app: AppModel) {
        index = i
        guard let list = app.profiles?.profiles else { return }
        if i >= list.count { app.addProfile(); return }
        Task { await app.selectProfile(list[i]) }
    }
}

struct ProfilePicker: View {
    @Environment(AppModel.self) private var app
    let model: PickerModel
    /// the profile a finger is down on
    @GestureState private var downAt: Int?

    var body: some View {
        let u = app.u
        let list = app.profiles?.profiles ?? []
        let editing = app.profileEdit != nil
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.74)
            // the line of profiles sits in the middle, the title above it, the switch below
            HStack(alignment: .top, spacing: 60 * u) {
                ForEach(0...list.count, id: \.self) { i in
                    let p = list[safe: i]
                    // a finger sees no focus, only the press
                    let foc = Theme.touch ? downAt == i : model.index == i && !model.onAuto && !editing
                    VStack(spacing: 24 * u) {
                        ZStack {
                            if let p {
                                Avatar(colour: p.color, letter: String(p.name.prefix(1)).uppercased(), size: 200 * u, image: p.avatar)
                            } else {
                                Circle().fill(Color.white.opacity(foc ? 0.22 : 0.1))
                                    .overlay { Image(systemName: "plus").font(.system(size: 60 * u, weight: .semibold)).foregroundStyle(Theme.fg) }
                                    .frame(width: 200 * u, height: 200 * u)
                            }
                            Circle().stroke(.white, lineWidth: 6 * u).opacity(foc ? 1 : 0)
                                .animation(.easeOut(duration: 0.14), value: foc)
                            if let p, p.id == app.profiles?.current {
                                Circle().fill(.white).frame(width: 52 * u, height: 52 * u)
                                    .overlay { Image(systemName: "checkmark").font(.system(size: 24 * u, weight: .bold)).foregroundStyle(Theme.focusFg) }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                    .padding(4 * u)
                            }
                        }
                        .frame(width: 200 * u, height: 200 * u)
                        .scaleEffect(foc ? 1.12 : 1)
                        .animation(Theme.lift, value: foc)
                        Text(p?.name ?? L("Add Profile"))
                            .font(Theme.display(32 * u, .semibold))
                            .foregroundStyle(foc || Theme.touch ? Theme.fg : Theme.fg2)
                            .lineLimit(1)
                    }
                    .frame(width: 240 * u)
                    .contentShape(.rect)
                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive, !editing { model.onAuto = false; model.index = i } }
                    .onTapGesture { model.activate(i, app: app) }
                    #if os(iOS)
                    .simultaneousGesture(DragGesture(minimumDistance: 0).updating($downAt) { _, d, _ in d = i })
                    #endif
                }
            }
            // short screens: no slack under the names, so the gaps above and below match
            .frame(height: (app.short ? 270 : 320) * u, alignment: .top)
            .overlay(alignment: .top) {
                Text(L("Who's watching?")).font(Theme.display(56 * u, .bold)).foregroundStyle(Theme.fg)
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + (app.short ? 72 : 96) * u }
            }
            .overlay(alignment: .bottom) {
                SettingsRow(line: .init(label: L("Sign in automatically"), detail: L("Open on the last profile without asking"),
                                        checkable: true, checked: app.autoLogin),
                            focused: model.onAuto && !editing, u: u * 1.25)
                    .frame(width: 800 * u)
                    .fixedSize(horizontal: false, vertical: true)
                    .alignmentGuide(.bottom) { $0[.top] - (app.short ? 24 : 64) * u }
                    .onContinuousHover { phase in if case .active = phase, Input.pointerLive, !editing { model.onAuto = true } }
                    .onTapGesture { app.setAutoLogin(!app.autoLogin) }
            }
        }
    }
}

/// a new profile or an edit of one (qml ProfileAdd): a name on the glass keyboard (or a real one)
/// and a look: one of the colours or a picture from the avatars folder
@MainActor @Observable
final class ProfileEditModel {
    static let colours = ["green", "pink", "blue", "orange", "purple"]
    var name = "" { didSet { kb.shift = name.isEmpty } }
    var editId = 0
    var files: [String] = []
    var dir = ""
    var choice = 0 { didSet { if !pictured { lastColour = Self.colours[choice] } } }
    var lastColour = "green"
    /// the focus is on the looks (else the keyboard)
    var onLooks = false
    let kb = KeyboardModel()
    @ObservationIgnored var done: (Profile, Bool) -> Void = { _, _ in }
    @ObservationIgnored var cancel: () -> Void = {}

    var choices: [String] { Self.colours + files }
    var pictured: Bool { choice >= Self.colours.count }
    var colour: String { pictured ? lastColour : Self.colours[choice] }
    var avatar: String { pictured ? choices[choice] : "" }

    init() {
        kb.enterLabel = L("done")
        kb.shift = true
        kb.typed = { [weak self] t in if let self, name.count < 20 { name += t } }
        kb.special = { [weak self] n in
            guard let self else { return }
            switch n {
            case "backspace": if !name.isEmpty { name.removeLast() }
            case "clear": name = ""
            case "enter": create()
            default: break
            }
        }
        kb.leave = { [weak self] d in if d == "up" { self?.onLooks = true } }
    }

    private func loadFiles(_ then: (() -> Void)? = nil) {
        Task {
            if let d = try? await Core.shared.raw("profiles.avatars"),
               let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                files = r["files"] as? [String] ?? []
                dir = (r["dir"] as? String ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
            then?()
        }
    }

    func open(taken: [String]) {
        name = ""; editId = 0; onLooks = false
        let free = Self.colours.firstIndex { !taken.contains($0) }
        choice = free ?? taken.count % Self.colours.count
        loadFiles()
    }

    func openEdit(_ p: Profile) {
        name = p.name; editId = p.id; onLooks = false
        choice = max(0, Self.colours.firstIndex(of: p.color) ?? 0)
        loadFiles { [weak self] in
            guard let self, let a = p.avatar, let i = files.firstIndex(of: a) else { return }
            choice = Self.colours.count + i
        }
    }

    func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let fields: [String: Any] = ["name": n, "color": colour, "avatar": avatar]
        Task {
            if editId != 0 {
                guard (try? await Core.shared.raw("profiles.update", fields.merging(["id": editId]) { a, _ in a })) != nil else { return }
                done(Profile(id: editId, name: n, color: colour, trakt: "", avatar: avatar), true)
            } else {
                guard let d = try? await Core.shared.raw("profiles.add", fields),
                      let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let id = (r["id"] as? NSNumber)?.intValue else { return }
                done(Profile(id: id, name: n, color: colour, trakt: "", avatar: avatar), false)
            }
        }
    }

    func key(_ k: Key) -> Bool {
        if k == .back { cancel(); return true }
        if onLooks {
            switch k {
            case .left: choice = max(0, choice - 1)
            case .right: choice = min(choices.count - 1, choice + 1)
            case .down, .ok: onLooks = false
            default: break
            }
            return true
        }
        _ = kb.key(k)
        return true
    }

    func typed(_ t: Typed) {
        switch t {
        case .text(let s): if name.count < 20 { name += s }
        case .erase: if !name.isEmpty { name.removeLast() }
        case .submit: create()
        }
    }
}

struct ProfileEditView: View {
    @Environment(AppModel.self) private var app
    let model: ProfileEditModel
    /// under the mouse: a click picks it, hovering only shows it
    @State private var pointedLook: Int?
    @State private var open = 0
    @State private var cardH: CGFloat = 0
    private func fit(_ u: CGFloat) -> CGFloat { cardH > 0 ? min(1, (app.size.height - 32 * u) / cardH) : 1 }

    var body: some View {
        let u = app.u
        let touch = Theme.touch
        let w = 760 * u, inner = w - 2 * 48 * u
        let count = CGFloat(model.choices.count)
        VStack(spacing: 26 * u) {
            Text(model.editId != 0 ? L("Edit Profile") : L("New Profile")).font(Theme.display(40 * u, .bold)).foregroundStyle(Theme.fg)
            Avatar(colour: model.colour, letter: String(model.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased(),
                   size: 150 * u, image: model.avatar)
            // the looks: the colours, then the pictures
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 18 * u) {
                        ForEach(Array(model.choices.enumerated()), id: \.offset) { i, c in
                            let foc = i == model.choice && model.onLooks
                            let pointed = pointedLook == i
                            ZStack {
                                Avatar(colour: i < ProfileEditModel.colours.count ? c : model.lastColour, letter: "",
                                       size: 64 * u, image: i < ProfileEditModel.colours.count ? nil : c)
                                    .scaleEffect(foc || pointed ? 1.14 : 1)
                                    .animation(.easeOut(duration: 0.14), value: foc || pointed)
                                Circle().stroke(.white, lineWidth: 4 * u).frame(width: 80 * u, height: 80 * u)
                                    .opacity(i == model.choice ? (foc ? 1 : 0.45) : pointed ? 0.3 : 0)
                            }
                            .frame(width: 72 * u, height: 92 * u)
                            .id(i)
                            .contentShape(.rect)
                            .onHover { inside in pointedLook = inside ? i : pointedLook == i ? nil : pointedLook }
                            .onTapGesture { model.choice = i; model.onLooks = false }
                        }
                    }
                    .padding(.horizontal, 10 * u)
                }
                .scrollIndicators(.never)
                .frame(width: min(inner, count * 90 * u - 18 * u + 20 * u), height: 92 * u)
                .onChange(of: model.choice) { withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(model.choice, anchor: .center) } }
            }
            EntryField(text: model.name, placeholder: L("Name"), active: true, size: 28 * u, u: u,
                       ime: touch ? ImeField(text: model.name, limit: 20, open: open, words: true, shown: true, size: 28 * u, placeholder: L("Name"),
                                             edited: { model.name = $0 }, done: { model.create() }) : nil)
                .contentShape(.rect)
                .onTapGesture { model.onLooks = false }
            if touch {
                // the phone's keyboard has no done of ours
                GlassButton(text: model.editId != 0 ? L("Save") : L("Create"), primary: true, focused: false, u: u)
                    .onTapGesture { model.create() }
            } else {
                KeyboardView(model: model.kb, u: u / 2, width: inner, active: !model.onLooks)
                Text(L("Up to pick a colour or a picture. Pictures: PNG or JPG files in %1", Platform.ios ? "Files › Noonix TV › Avatars" : model.dir))
                    .font(Theme.text(22 * u)).foregroundStyle(Theme.fg3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: inner)
        .padding(48 * u)
        .panelGlass(56 * u, u: u, lift: -0.22)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardH = $0 }
        // a docked phone keyboard: up above it
        // a phone with the glass keyboard (a pad): the whole card in view
        .fixedSize()
        .scaleEffect(fit(u))
        .frame(width: (inner + 96 * u) * fit(u), height: cardH > 0 ? cardH * fit(u) : nil)
        .offset(y: -max(0, app.size.height / 2 + cardH / 2 + 24 * u - app.keyboardTop))
        .onAppear { if touch { open += 1 } }
        // in the middle of the app, over whatever asked for it; nothing behind it takes the mouse
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color.black.opacity(0.001).contentShape(.rect).onTapGesture { model.cancel() } }
    }
}

/// apple's activity indicator (qml Spinner): eight rounded spokes, the lit one steps round
struct Spinner: View {
    let size: CGFloat
    var color = Color.white

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate * 10) % 8
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let age = (step - i + 8) % 8
                    Capsule().fill(color)
                        .frame(width: size * 0.09, height: size * 0.28)
                        .opacity(1 - Double(age) * 0.11)
                        .offset(y: -size * 0.36)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

/// trakt sign-in (qml TraktCode): the code big, polled until trakt says yes; back cancels
@MainActor @Observable
final class TraktCodeModel {
    let profile: Int
    let name: String
    var code: [String: Any]?
    /// signed in on a profile with a history here: what it has
    var local: [String: Any]?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var userCode: String? { code?["user_code"] as? String }
    var url: String { code?["verification_url"] as? String ?? "trakt.tv/activate" }

    init(profile: Int, name: String) {
        self.profile = profile
        self.name = name
    }

    /// done(ok, the toast to show)
    func start(done: @escaping (Bool, String?) -> Void) {
        poll = Task {
            guard let data = try? await Core.shared.raw("trakt.deviceCode"),
                  let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let device = c["device_code"] as? String else {
                done(false, L("Trakt isn't answering"))
                return
            }
            code = c
            let every = (c["interval"] as? NSNumber)?.doubleValue ?? 5
            var left = Int(((c["expires_in"] as? NSNumber)?.doubleValue ?? 600) / every)
            while left > 0, !Task.isCancelled {
                left -= 1
                try? await Task.sleep(for: .seconds(every))
                if Task.isCancelled { return }
                do {
                    let r = try await Core.shared.raw("trakt.devicePoll", ["code": device, "profile": profile])
                    let o = try? JSONSerialization.jsonObject(with: r) as? [String: Any]
                    if o?["done"] as? Bool == true {
                        local = o?["local"] as? [String: Any]
                        done(true, L("Signed in to Trakt"))
                        return
                    }
                } catch {
                    done(false, L("That code didn't work"))
                    return
                }
            }
            if !Task.isCancelled { done(false, nil) }
        }
    }

    func cancel() { poll?.cancel() }
}

/// first trakt sign-in on a profile that already has a history here (qml TraktChoice).
/// back leaves both as they are
@MainActor @Observable
final class TraktChoiceModel {
    let profile: Int
    let local: [String: Any]
    var index = 1
    var busy = false

    init(profile: Int, local: [String: Any]) {
        self.profile = profile
        self.local = local
    }

    var summary: String {
        let n = { (k: String) in (self.local[k] as? NSNumber)?.intValue ?? 0 }
        return [("watched", "%1 watched"), ("progress", "%1 in progress"), ("library", "%1 in Library")]
            .filter { n($0.0) > 0 }.map { L($0.1, String(n($0.0))) }.joined(separator: "  ·  ")
    }
    let lines = [SettingsModel.Line(label: L("Overwrite with Trakt"), detail: L("Delete what's here and use Trakt's history"), act: "trakt"),
                 SettingsModel.Line(label: L("Merge"), detail: L("Add what's here to Trakt and keep both"), act: "merge"),
                 SettingsModel.Line(label: L("Use Local"), detail: L("Keep what's here, only new watches go to Trakt"), act: "local")]

    func pick(_ i: Int, app: AppModel) {
        guard !busy, let l = lines[safe: i] else { return }
        busy = true
        Task {
            let ok = (try? await Core.shared.raw("trakt.choose", ["profile": profile, "choice": l.act])) != nil
            busy = false
            guard ok else {
                app.toast(l.act == "merge" ? L("Trakt isn't answering") : L("Couldn't save it"))
                return
            }
            app.traktChoice = nil
            app.refreshLists()
        }
    }

    func key(_ k: Key, app: AppModel) {
        switch k {
        case .up: index = max(0, index - 1)
        case .down: index = min(lines.count - 1, index + 1)
        case .ok: pick(index, app: app)
        case .back: if !busy { app.traktChoice = nil; app.refreshLists() }
        default: break
        }
    }
}

struct TraktChoiceView: View {
    @Environment(AppModel.self) private var app
    let model: TraktChoiceModel

    var body: some View {
        let u = app.u
        ZStack {
            Color.black.opacity(0.4).contentShape(.rect).onTapGesture { model.key(.back, app: app) }
            VStack(alignment: .leading, spacing: 14 * u) {
                Text(L("This profile already has a history")).font(Theme.display(42 * u, .bold)).foregroundStyle(Theme.fg)
                Text(model.summary).font(Theme.text(27 * u, .medium)).foregroundStyle(Theme.fg2).padding(.bottom, 10 * u)
                VStack(spacing: 4 * u) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { i, l in
                        SettingsRow(line: l, focused: model.index == i, u: u, grow: 1)
                            .opacity(model.busy ? 0.5 : 1)
                            .onContinuousHover { phase in if case .active = phase, Input.pointerLive { model.index = i } }
                            .onTapGesture { model.index = i; model.pick(i, app: app) }
                    }
                }
                Text(model.busy ? L("Sending it to Trakt…") : L("Back changes nothing"))
                    .font(Theme.text(22 * u)).foregroundStyle(Theme.fg3)
                    .frame(maxWidth: .infinity).padding(.top, 8 * u)
            }
            .padding(52 * u)
            .frame(width: 1040 * u)
            .panelGlass(52 * u, u: u)
        }
    }
}

struct TraktCodeView: View {
    @Environment(AppModel.self) private var app
    let model: TraktCodeModel

    var body: some View {
        let u = app.u
        ZStack {
            Color.black.opacity(0.4).contentShape(.rect).onTapGesture { app.closeTrakt(false) }
            VStack(spacing: 14 * u) {
                Text(model.name.isEmpty ? L("Trakt") : L("Trakt for %1", model.name)).font(Theme.display(46 * u, .bold)).foregroundStyle(Theme.fg)
                TraktCodeLine(code: model.userCode, url: model.url, u: u, weight: .medium)
                    .padding(.bottom, 6 * u)
                Text(model.userCode ?? "· · · ·")
                    .font(Theme.rounded(96 * u, .bold)).tracking(10 * u)
                    .foregroundStyle(Theme.fg)
                    .textSelection(.enabled)
                Spinner(size: 44 * u)
                Text(L("Back cancels")).font(Theme.text(22 * u)).foregroundStyle(Theme.fg3)
            }
            .padding(.vertical, 60 * u)
            .frame(width: 980 * u - 120 * u)
            .padding(.horizontal, 60 * u)
            .panelGlass(52 * u, u: u)
        }
    }
}
