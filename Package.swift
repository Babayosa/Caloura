// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Caloura",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "Caloura", targets: ["Caloura"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
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
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CalouraTests",
            dependencies: ["Caloura"],
            path: "CalouraTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
