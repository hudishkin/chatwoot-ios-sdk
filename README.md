# Chatwoot iOS SDK

A ready-made chat screen for [Chatwoot](https://www.chatwoot.com) in your iOS app, written in SwiftUI.

Requirements: iOS 15+, Swift 5.9+.

## Installation

Add the package with Swift Package Manager.

In Xcode: **File → Add Package Dependencies…**, paste the URL below and add the `ChatwootSDK` library to your app target.

```
https://github.com/hudishkin/chatwoot-ios-sdk.git
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/hudishkin/chatwoot-ios-sdk.git", branch: "main")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "ChatwootSDK", package: "chatwoot-ios-sdk")
    ])
]
```

## Usage

1. Initialize the SDK once at app start:

```swift
import ChatwootSDK

let config = try ChatwootConfig(
    baseURL: "https://chat.example.com",
    inboxIdentifier: "YOUR_INBOX_IDENTIFIER",
    inboxID: 1
)
Chatwoot.initialize(config)
```

2. Identify the user. The identity hash must come from your backend — never ship the inbox HMAC token in the app:

```swift
struct BackendIdentityProvider: IdentityProvider {
    func fetch() async -> Result<Identity, ChatwootError> {
        // Request identifier and identifierHash from your backend.
    }
}

let result = await Chatwoot.identify(
    user: ChatwootUser(name: "Jane"),
    identity: BackendIdentityProvider()
)
```

3. Show the chat:

```swift
NavigationStack {
    Chatwoot.chatView()
}
```

Call `await Chatwoot.reset()` when the user logs out.

## Example app

The example app is in `Example/`. The project is generated with [Tuist](https://tuist.dev).

1. Install Tuist: `brew install tuist` (or see [the Tuist docs](https://docs.tuist.dev)).
2. Create the config with your test server values:

   ```sh
   cp Example/config.example.json Example/Resources/config.json
   ```

   `config.json` is git-ignored. Without it the app starts on a "not configured" screen.
3. Generate and open the project:

   ```sh
   tuist generate
   ```

4. Select the `ChatwootSDKExample` scheme and run it on a simulator or device.

The example computes the identity hash on the device from `hmacToken` for testing only. Do not do this in a real app.

## Tests

```sh
swift test
```

## Releasing

1. Set the new version in `Project.swift` (`let version = "X.Y.Z"`) and the same value in `ChatwootSDK.version` (`Sources/ChatwootSDK/ChatwootSDK.swift`). Push to `main`.
2. On GitHub open **Actions → Release → Run workflow**.

The workflow runs the tests, builds the SDK for iOS, then creates the `X.Y.Z` tag and a GitHub release.

## License

MIT. See [LICENSE](LICENSE).
