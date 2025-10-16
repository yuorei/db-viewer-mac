// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "db-viewer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DBViewerCore", targets: ["DBViewerCore"]),
        .executable(name: "db-viewer", targets: ["DBViewerApp"])
    ],
    targets: [
        .target(name: "DBViewerCore"),
        .executableTarget(
            name: "DBViewerApp",
            dependencies: ["DBViewerCore"]
        ),
        .testTarget(
            name: "DBViewerCoreTests",
            dependencies: ["DBViewerCore"]
        )
    ]
)
