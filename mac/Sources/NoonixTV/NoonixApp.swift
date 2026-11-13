import SwiftUI
#if !os(macOS)
import UIKit
import AVFAudio
#endif

@main
struct NoonixApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(Quit.self) private var quit
    #else
    @UIApplicationDelegateAdaptor(Launch.self) private var launch
    @Environment(\.scenePhase) private var phase
    #endif
    @State private var app = AppModel()

    init() {
        // artwork is most of what the app downloads
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 1 << 30)
        Platform.nameDevice()
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup("Noonix TV") {
            RootView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 540)
                .task { await app.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        #else
        WindowGroup {
            RootView()
                .environment(app)
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
                #if os(iOS)
                .statusBarHidden()
                #endif
                .task { await app.start() }
        }
        // leaving the app pauses the video (the place is kept like a quit's)
        .onChange(of: phase) { _, p in
            if p == .background { app.player.background() }
            // back from the files app: videos may have been copied in
            if p == .active { Task { _ = try? await Core.shared.raw("library.scan") } }
        }
        #endif
    }
}

/// the window as the player's buttons see it: its own title bar (with the system's full screen
/// button) or not, full screen or not (qml Remote.titleBar / fullScreen)
@MainActor @Observable
final class WindowState {
    static let shared = WindowState()
    var titleBar = false
    var fullScreen = false
    /// the window's own buttons (close, minimise, zoom) over the page's top left corner
    var lights: Bool {
        #if os(macOS)
        !titleBar && !fullScreen
        #else
        false
        #endif
    }
    /// how far the top bar sits under its usual 44 to clear those buttons in a small window: what starts
    /// right under the bar (search's field) moves down as much
    func navDrop(_ u: CGFloat) -> CGFloat { lights ? max(0, 34 - 7 * u - 44 * u) : 0 }
    /// a top left control's y, below those buttons while they show
    func belowLights(_ y: CGFloat) -> CGFloat { lights ? max(y, 40) : y }
    #if os(macOS)
    /// full screen entered while something played in a window: back leaves it first, the player after
    @ObservationIgnored var enteredPlaying = false
    @ObservationIgnored private var watching = false
    func watch() {
        guard !watching else { return }
        watching = true
        fullScreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }
        for n in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let s = WindowState.shared
                    s.fullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
                    s.enteredPlaying = note.name == NSWindow.didEnterFullScreenNotification && AppModel.current?.playing == true
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PlayerCursor.show() }
        }
    }
    func toggle() { (NSApp.keyWindow ?? NSApp.windows.first { $0.styleMask.contains(.titled) })?.toggleFullScreen(nil) }
    #endif
}

/// the window's own title bar (settings), or the page right up to the window's edge
@MainActor
func showTitleBar(_ on: Bool) {
    WindowState.shared.titleBar = on
    #if os(macOS)
    WindowState.shared.watch()
    for w in NSApp.windows where w.styleMask.contains(.titled) {
        w.titleVisibility = on ? .visible : .hidden
        w.titlebarAppearsTransparent = !on
        if on { w.styleMask.remove(.fullSizeContentView) } else { w.styleMask.insert(.fullSizeContentView) }
    }
    #endif
}

#if !os(macOS)
/// the video's sound plays with the silent switch on, like any video app
final class Launch: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        #if os(tvOS)
        // every press and swipe of the remote comes to the app first (TVRemote.swift)
        TVApp.take(application)
        // the database back when tvos cleared the caches, and kept from now on (TVStore.swift)
        TVStore.restore()
        TVStore.install()
        #endif
        return true
    }
}
#else

/// on quit: the last playback point and anything the build started shut down before the process goes
/// (a mac has no parent-death signal: they'd outlive the app)
final class Quit: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// dev: NOONIX_WINDOW=1280x720 sizes the window's content, top left (parity shots at 16:9)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let spec = ProcessInfo.processInfo.environment["NOONIX_WINDOW"]?.split(separator: "x").compactMap { Double($0) } ?? []
        guard spec.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let w = NSApp.windows.first(where: { $0.isVisible }), let screen = w.screen else { return }
            w.setContentSize(NSSize(width: spec[0], height: spec[1]))
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.current?.player.stop(reason: "quit") }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await Core.shared.raw("local.stop")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }
}
#endif
