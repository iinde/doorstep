// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OpenRingPackage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenRingFeature", targets: ["OpenRingFeature"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "RingClient", targets: ["RingClient"]),
        .library(name: "Storage", targets: ["Storage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.49.0"),
        .package(url: "https://github.com/stasel/WebRTC.git", from: "158.0.0"),
        // Auto-updates from GitHub Releases (EdDSA-signed appcast, no server of our own).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Design System - colors, typography, components
        .target(
            name: "DesignSystem",
            dependencies: []
        ),

        // Ring API Client
        .target(
            name: "RingClient",
            dependencies: [
                "RTCAudioShim",
                .product(name: "WebRTC", package: "WebRTC")
            ]
        ),

        // The header WebRTC leaves out on macOS, so speech can stand in for the microphone.
        .target(
            name: "RTCAudioShim",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")]
        ),

        // Local Storage (SQLite via GRDB)
        .target(
            name: "Storage",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),

        // Main Feature module
        .target(
            name: "OpenRingFeature",
            dependencies: [
                "DesignSystem",
                "RingClient",
                "Storage",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),

        .testTarget(
            name: "OpenRingFeatureTests",
            dependencies: ["OpenRingFeature", "RingClient"]
        ),
    ]
)
