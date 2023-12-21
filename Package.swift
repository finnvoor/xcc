// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "xcc",
    platforms: [.macOS(.v11)],
    products: [.executable(name: "xcc", targets: ["xcc"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/AvdLee/appstoreconnect-swift-sdk.git", from: "3.0.1"),
        .package(url: "https://github.com/Finnvoor/SwiftTUI.git", from: "1.0.3")
    ],
    targets: [
        .executableTarget(
            name: "xcc",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AppStoreConnect-Swift-SDK", package: "AppStoreConnect-Swift-SDK"),
                .product(name: "SwiftTUI", package: "SwiftTUI")
            ]
        ),
    ]
)
