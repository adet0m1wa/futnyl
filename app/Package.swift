// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VinylWidget",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/rive-app/rive-ios", from: "6.28.1"),
    ],
    targets: [
        .target(name: "LyricsCore"),
        .testTarget(name: "LyricsCoreTests", dependencies: ["LyricsCore"]),
        .testTarget(name: "VinylWidgetTests", dependencies: ["VinylWidget", "LyricsCore", .product(name: "RiveRuntime", package: "rive-ios")]),
        .executableTarget(
            name: "VinylWidget",
            dependencies: ["LyricsCore", .product(name: "RiveRuntime", package: "rive-ios")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
