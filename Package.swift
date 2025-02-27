// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "xcc",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "xcc", targets: ["xcc"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/finnvoor/appstoreconnect-swift-sdk.git", branch: "master"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.28.1"),
    ],
    targets: [
        .executableTarget(
            name: "xcc",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AppStoreConnect-Swift-SDK", package: "AppStoreConnect-Swift-SDK"),
                .product(name: "Noora", package: "Noora")
            ]
        ),
    ]
)
