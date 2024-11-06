// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DropBoxJSON",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "DropBoxJSON",
            targets: ["DropBoxJSON"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/dropbox/SwiftyDropbox.git", from: "10.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", from: "1.4.1"),
        .package(url: "https://github.com/nosteponsnekkk/ConnectionManager", branch: "main"),

        // Add other dependencies here
    ],
    targets: [
        .target(
            name: "DropBoxJSON",
            dependencies: [
                .product(name: "SwiftyDropbox", package: "SwiftyDropbox"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "ConnectionManager", package: "connectionmanager")
                // Add other dependencies here
            ],
            path: "Sources"),
        .testTarget(
            name: "DropBoxJSONTests",
            dependencies: ["DropBoxJSON"]),
    ]
)
