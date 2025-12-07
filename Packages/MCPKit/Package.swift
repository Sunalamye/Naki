// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "MCPKit",
            targets: ["MCPKit"]
        ),
    ],
    targets: [
        .target(
            name: "MCPKit",
            dependencies: [],
            path: "Sources/MCPKit"
        ),
        .testTarget(
            name: "MCPKitTests",
            dependencies: ["MCPKit"],
            path: "Tests/MCPKitTests"
        ),
    ]
)
