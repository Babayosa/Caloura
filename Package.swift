// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Caloura",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Caloura", targets: ["Caloura"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1")
    ],
    targets: [
        .target(
            name: "Caloura",
            dependencies: [
                "KeyboardShortcuts",
                "Sparkle"
            ],
            path: "Caloura",
            exclude: [
                "Resources",
                "App/CalouraApp.swift"
            ]
        ),
        .testTarget(
            name: "CalouraTests",
            dependencies: ["Caloura"],
            path: "CalouraTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
