// swift-tools-version: 6.2
// the native apple clients (macos, ios + ipados, tvos): swiftui on top of the rust core (build.sh puts it in
// .build/core, ios.sh in .build/core-ios or core-tvos for the device or simulator being built)
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "NoonixTV",
    platforms: [.macOS(.v26), .iOS(.v26), .tvOS(.v26)],
    dependencies: [
        // libmpv + ffmpeg + moltenvk as prebuilt universal xcframeworks (lgpl build)
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.1.0-n9.0.2"),
    ],
    targets: [
        .target(
            name: "CNoonix",
            linkerSettings: [
                .unsafeFlags(["-L\(root)/.build/core"], .when(platforms: [.macOS])),
                .unsafeFlags(["-L\(root)/.build/core-ios"], .when(platforms: [.iOS])),
                .unsafeFlags(["-L\(root)/.build/core-tvos"], .when(platforms: [.tvOS])),
                .linkedLibrary("noonix_core"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("c++", .when(platforms: [.iOS, .tvOS])),
                // apple tv: the window's display manager (frame rate and hdr matching)
                .linkedFramework("AVKit", .when(platforms: [.tvOS])),
            ]
        ),
        .executableTarget(
            name: "NoonixTV",
            dependencies: ["CNoonix", .product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
