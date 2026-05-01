// swift-tools-version: 5.9
import PackageDescription

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
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.26.0"),
    ],
    targets: [
        .target(
            name: "Protowire",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]),
        .testTarget(
            name: "ProtowireTests",
            dependencies: ["Protowire"]),
    ]
)
