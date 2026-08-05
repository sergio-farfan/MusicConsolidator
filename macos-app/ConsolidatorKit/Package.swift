// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConsolidatorKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ConsolidatorCore",
            targets: ["ConsolidatorCore"]
        ),
        .library(
            name: "MusicBridge",
            targets: ["MusicBridge"]
        ),
        .executable(
            name: "AppleMusicConsolidatorApp",
            targets: ["AppleMusicConsolidatorApp"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AppleMusicConsolidatorApp",
            dependencies: ["MusicBridge", "ConsolidatorCore"]
        ),
        .target(
            name: "ConsolidatorCore",
            dependencies: []
        ),
        .target(
            name: "MusicBridge",
            dependencies: ["ConsolidatorCore"]
        ),
        .testTarget(
            name: "ConsolidatorCoreTests",
            dependencies: ["ConsolidatorCore"]
        ),
        .testTarget(
            name: "MusicBridgeTests",
            dependencies: ["MusicBridge", "ConsolidatorCore"]
        ),
        // M7: headless view-model tests for the app executable target
        // (sanctioned Package.swift change: this test target only, plus
        // @testable import of the executable target's types).
        .testTarget(
            name: "AppleMusicConsolidatorAppTests",
            dependencies: ["AppleMusicConsolidatorApp", "MusicBridge", "ConsolidatorCore"]
        ),
    ]
)
