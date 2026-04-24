// swift-tools-version: 6.0
//
// TapPairCore — platform-agnostic core for the TapPair iOS (and future
// Android) app. This package contains:
//   * Codable models that mirror the wire protocol in `spec/PROTOCOL.md`.
//   * The websocket-message reducer (`GameStore`) for the client UI to bind to.
//   * The `PairingProvider` protocol that radio implementations conform to.
//
// It is intentionally free of Apple-platform dependencies (no UIKit, no
// CoreBluetooth, no NearbyInteraction) so that:
//   * It builds and tests on Linux CI without a Mac runner.
//   * The same logic could be ported to a Kotlin Android client by mirroring
//     these types, with no platform-specific surprises.
//
// The iOS-only `TapPairApp` target lives under Sources/TapPairApp/ and is
// built by Xcode (or xcodegen) — see project.yml.

import PackageDescription

let package = Package(
    name: "TapPair",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TapPairCore", targets: ["TapPairCore"]),
    ],
    targets: [
        .target(
            name: "TapPairCore",
            path: "Sources/TapPairCore"
        ),
        .testTarget(
            name: "TapPairCoreTests",
            dependencies: ["TapPairCore"],
            path: "Tests/TapPairCoreTests"
        ),
    ]
)
