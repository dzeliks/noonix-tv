// swift-tools-version: 6.2
// the native macos client: swiftui on top of the rust core (built by build.sh into .build/core)
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "NoonixTV",
    platforms: [.macOS(.v26)],
    dependencies: [
        // libmpv + ffmpeg + moltenvk as prebuilt universal xcframeworks (lgpl build)
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .target(
            name: "CNoonix",
            linkerSettings: [
                .unsafeFlags(["-L\(root)/.build/core"]),
                .linkedLibrary("noonix_core"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "NoonixTV",
            dependencies: ["CNoonix", .product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
