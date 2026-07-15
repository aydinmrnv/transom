// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "transom-host",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // The ONLY dependency. Ask before adding others.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "transom-host",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                // Swift 6 language mode: complete strict concurrency checking.
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
