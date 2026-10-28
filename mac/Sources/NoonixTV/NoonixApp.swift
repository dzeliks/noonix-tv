import SwiftUI

@main
struct NoonixApp: App {
    @NSApplicationDelegateAdaptor(Quit.self) private var quit
    @State private var app = AppModel()

    init() {
        // artwork is most of what the app downloads
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 1 << 30)
    }

    var body: some Scene {
        WindowGroup("Noonix TV") {
            RootView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 540)
                .task { await app.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}

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
