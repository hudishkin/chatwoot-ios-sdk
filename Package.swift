// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatwootSDK",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        // Нужно только для сборки и запуска тестов на macOS-хосте.
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ChatwootSDK",
            targets: ["ChatwootSDK"]
        )
    ],
    targets: [
        .target(
            name: "ChatwootSDK",
            path: "Sources/ChatwootSDK",
            resources: [.process("UI/Resources")]
        ),
        .testTarget(
            name: "ChatwootSDKTests",
            dependencies: ["ChatwootSDK"],
            path: "Tests/ChatwootSDKTests"
        )
    ]
)
