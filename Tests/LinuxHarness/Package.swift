// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Harness",
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"5.0.0"),
  ],
  targets: [.executableTarget(name: "Harness", dependencies: [
    .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"),
    .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto"),
    .product(name: "CryptoExtras", package: "swift-crypto")],
    swiftSettings: [.swiftLanguageMode(.v5)])])
