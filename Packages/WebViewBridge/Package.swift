// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WebViewBridge",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "WebViewBridge",
            targets: ["WebViewBridge"]
        ),
    ],
    targets: [
        .target(
            name: "WebViewBridge",
            dependencies: [],
            path: "Sources/WebViewBridge",
            resources: [
                .copy("JavaScript")
            ]
        ),
        .testTarget(
            name: "WebViewBridgeTests",
            dependencies: ["WebViewBridge"],
            path: "Tests/WebViewBridgeTests"
        ),
    ]
)
