// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "transom-host",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // The ONLY dependency. Ask before adding others (invariants I-8).
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Shared logic used by BOTH the CLI and the .app. The implementation is
        // never forked between the two executables; it lives here (issue Part 3).
        .target(
            name: "TransomKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The diagnostic CLI: `transom-host <subcommand>`.
        .executableTarget(
            name: "transom-host",
            dependencies: [
                "TransomKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                // Swift 6 language mode: complete strict concurrency checking.
                .swiftLanguageMode(.v6)
            ]
        ),
        // The SwiftUI probe app. Built as a bare executable here; wrapped into
        // `Transom Probe.app` (stable bundle id, own TCC identity) by
        // scripts/make-app.sh. See issue Part 2/3.
        .executableTarget(
            name: "TransomProbeApp",
            dependencies: [
                "TransomKit"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // The SwiftUI host app: a one-window control panel over `serve` (issue #8).
        // A thin shell — it drives the SAME `TransomKit.HostSession` the CLI does,
        // never a fork of the capture/tile/AX/wire code. Wrapped into
        // `Transom Host.app` (bundle id one.nullstack.transom.host, its OWN TCC
        // identity, distinct from the probe's) by scripts/make-app.sh.
        .executableTarget(
            name: "TransomHostApp",
            dependencies: [
                "TransomKit"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Unit tests for the PURE logic — the tiler and the coordinate-space
        // conversions (I-3). These need no Mac, no AX, and no display, so they run
        // anywhere including CI. The Mac-only behaviour (SCK, AX writes, encode)
        // is verified by running the CLI on the target machine (I-7), not here.
        .testTarget(
            name: "TransomKitTests",
            dependencies: [
                "TransomKit"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
