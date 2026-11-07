import SwiftUI
#if os(iOS)
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
                .statusBarHidden()
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

/// the window's own title bar (settings), or the page right up to the window's edge
@MainActor
func showTitleBar(_ on: Bool) {
    #if os(macOS)
    for w in NSApp.windows where w.styleMask.contains(.titled) {
        w.titleVisibility = on ? .visible : .hidden
        w.titlebarAppearsTransparent = !on
        if on { w.styleMask.remove(.fullSizeContentView) } else { w.styleMask.insert(.fullSizeContentView) }
    }
    #endif
}

#if os(iOS)
/// the video's sound plays with the silent switch on, like any video app
final class Launch: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
