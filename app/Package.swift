// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VinylWidget",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/rive-app/rive-ios", from: "6.28.1"),
    ],
    targets: [
        .executableTarget(
            name: "VinylWidget",
            dependencies: [.product(name: "RiveRuntime", package: "rive-ios")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
