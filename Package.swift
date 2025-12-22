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
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "DBViewerCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "DBViewerApp",
            dependencies: ["DBViewerCore"]
        ),
        .executableTarget(
            name: "PostgresTest",
            dependencies: ["DBViewerCore"]
        )
    ]
)
