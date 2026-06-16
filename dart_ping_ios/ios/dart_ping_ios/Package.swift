// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "dart_ping_ios",
    platforms: [
        .iOS("12.0")
    ],
    products: [
        .library(name: "dart-ping-ios", targets: ["dart_ping_ios"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "dart_ping_ios",
            dependencies: []
        )
    ]
)
