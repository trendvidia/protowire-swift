// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TrendVidia, LLC.
import PackageDescription

// `ConciseMagicFile`, `ForwardTrailingClosures`, and
// `BareSlashRegexLiterals` are all defaults under Swift 6 — declaring
// them via `.enableUpcomingFeature` here is now an error
// ("upcoming feature ... is already enabled as of Swift version 6").
// Drop them; keep -warnings-as-errors as the only entry.
let sharedSwiftSettings: [SwiftSetting] = [
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
    ],
    // Stay on Swift 5 language mode under the 6.0 toolchain. Bumping
    // to mode 6 turns on strict concurrency checking, which would
    // require auditing every public struct (Position, Token, AST
    // nodes, etc.) for Sendable conformance — scope creep for v0.70.0.
    // Tracked for a follow-up.
    swiftLanguageVersions: [.v5]
)
