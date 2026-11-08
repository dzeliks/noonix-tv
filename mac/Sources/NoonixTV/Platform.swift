import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// what differs between the mac and iphone / ipad: the shared views use these names
#if os(iOS)
typealias NSImage = UIImage
typealias NSSize = CGSize

extension UIImage {
    convenience init(cgImage: CGImage, size: CGSize) { self.init(cgImage: cgImage) }
    convenience init?(contentsOf url: URL) { self.init(contentsOfFile: url.path) }
}

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}
#endif

@MainActor
enum Platform {
    #if os(iOS)
    static let ios = true
    /// a phone (not an ipad): drawn larger, like android phones (Desktop.boost)
    static var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    /// the lines' word for this device
    static func nameDevice() { UILang.deviceWord = phone ? "iPhone" : "iPad" }
    #else
    static let ios = false
    static let phone = false
    static func nameDevice() {}
    #endif

    /// how much larger than the 1920x1080 grid (qml Desktop.boost; dev: NOONIX_SCALE)
    static var boost: CGFloat {
        if let s = ProcessInfo.processInfo.environment["NOONIX_SCALE"].flatMap(Double.init), s > 0 { return s }
        return phone ? 1.4 : 1
    }

    static func open(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// the system keyboard goes away (ios)
    static func hideKeyboard() {
        #if os(iOS)
        for w in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) { w.endEditing(true) }
        #endif
    }

    /// leaving the app: ios apps don't quit themselves (the home gesture does it)
    static var canQuit: Bool { !ios }
    static func quit() {
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    /// a picture shipped with the app: a file in the mac's resources, the asset catalog on ios (it
    /// can't read svg or pdf files itself)
    static func bundled(_ name: String, _ ext: String, in dir: String? = nil) -> NSImage? {
        #if os(iOS)
        UIImage(named: name)
        #else
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: dir).flatMap(NSImage.init(contentsOf:))
        #endif
    }

    /// the app's own icon, for the about page
    static var icon: NSImage? {
        #if os(iOS)
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let names = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        return names?.last.flatMap { UIImage(named: $0) } ?? UIImage(named: "AppIcon")
        #else
        NSApp.applicationIconImage
        #endif
    }
}

#if os(macOS)
import ServiceManagement
#endif

/// opening at login (the mac only)
enum LoginItem {
    static var on: Bool {
        #if os(macOS)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }
    static func toggle() async throws {
        #if os(macOS)
        if on { try await SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        #endif
    }
}
