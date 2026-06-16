// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "dart_ping_ios",
    platforms: [
        // iOS 13.0 matches Flutter's current minimum-deployment baseline (the
        // FlutterFramework Swift package below targets iOS 13.0), so this package
        // imposes no floor stricter than Flutter already requires. The unprivileged
        // SOCK_DGRAM ICMP API used by the engine is available well below this.
        .iOS("13.0")
    ],
    products: [
        .library(name: "dart-ping-ios", targets: ["dart_ping_ios"])
    ],
    dependencies: [
        // Provides the `Flutter` module under Flutter's Swift Package Manager build
        // mode. Flutter's tooling generates the FlutterFramework package at this
        // relative path when resolving plugins; do not vendor or pin it.
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "dart_ping_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
