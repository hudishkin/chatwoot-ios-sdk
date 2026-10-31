import ProjectDescription

/// Release version: the release workflow tags this commit with it.
/// Keep `ChatwootSDK.version` in `Sources/ChatwootSDK/ChatwootSDK.swift` equal to it.
let version = "0.1.0"

let project = Project(
    name: "ChatwootSDK",
    targets: [
        .target(
            name: "ChatwootSDK",
            destinations: .iOS,
            product: .framework,
            bundleId: "com.chatwoot.sdk.ChatwootSDK",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(version)
            ]),
            sources: ["Sources/ChatwootSDK/**"],
            resources: ["Sources/ChatwootSDK/UI/Resources/**"],
            dependencies: []
        ),
        .target(
            name: "ChatwootSDKTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.chatwoot.sdk.ChatwootSDKTests",
            deploymentTargets: .iOS("15.0"),
            sources: ["Tests/ChatwootSDKTests/**"],
            dependencies: [
                .target(name: "ChatwootSDK")
            ]
        ),
        .target(
            name: "ChatwootSDKExample",
            destinations: .iOS,
            product: .app,
            bundleId: "com.chatwoot.sdk.Example",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": .string(version),
                "UILaunchScreen": .dictionary([:])
            ]),
            sources: ["Example/Sources/**"],
            resources: ["Example/Resources/**"],
            dependencies: [
                .target(name: "ChatwootSDK")
            ]
        )
    ],
    schemes: [
        .scheme(
            name: "ChatwootSDKExample",
            buildAction: .buildAction(targets: ["ChatwootSDKExample"]),
            runAction: .runAction(executable: "ChatwootSDKExample")
        )
    ]
)
