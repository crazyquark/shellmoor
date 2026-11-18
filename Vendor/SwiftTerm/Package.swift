// swift-tools-version:6.0
// Vendored SwiftTerm v1.20.0 (MIT, see LICENSE).
// Patched for Tether: upstream excludes the Apple/iOS sources whenever the
// manifest is evaluated on a Linux host, which breaks cross-compiling iOS apps
// with xtool. This manifest always includes them and skips the Metal shader
// resource (no Metal compiler on Linux; the CoreGraphics renderer is used).
// The build-info plugin is replaced by a fixed SwiftTermBuildInfo.swift, and the
// iOS target is raised to 17 (Tether's) because the sources need iOS 14 APIs.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md", "Apple/Metal/Shaders.metal"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
