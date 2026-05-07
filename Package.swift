// swift-tools-version: 5.10
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
    name: "Protowire",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "Protowire",
            targets: ["Protowire"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.37.0"),
    ],
    targets: [
        .target(
            name: "Protowire",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: sharedSwiftSettings),
        .testTarget(
            name: "ProtowireTests",
            dependencies: ["Protowire"],
            swiftSettings: sharedSwiftSettings),
        // Cross-port harness binaries. These produce JSON output the spec
        // repo's `scripts/cross_*_bench.sh` aggregates.
        .executableTarget(
            name: "dump-envelope",
            dependencies: ["Protowire"],
            path: "cmd/dump-envelope",
            swiftSettings: sharedSwiftSettings),
        .executableTarget(
            name: "bench-pxf",
            dependencies: ["Protowire"],
            path: "cmd/bench-pxf",
            swiftSettings: sharedSwiftSettings),
        // HARDENING.md M8 conformance corpus driver. The protowire spec repo's
        // `scripts/cross_security_check.sh` greps for the literal string
        // `"check-decode"` in this file to gate building this product.
        .executableTarget(
            name: "check-decode",
            dependencies: ["Protowire"],
            path: "cmd/check-decode",
            swiftSettings: sharedSwiftSettings),
    ]
)
