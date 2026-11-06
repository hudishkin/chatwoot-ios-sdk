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

3. Show the chat. The theme argument is optional; without it the SDK uses its own palette. See [Appearance](#appearance) to match the host app.

```swift
NavigationStack {
    Chatwoot.chatView()
}
```

Call `await Chatwoot.reset()` when the user logs out.

Unread agent replies and unanswered surveys are `Chatwoot.unreadCount`. It replays the latest count (`0` before `identify` and after `reset`). The SDK refreshes it on identify, when the app returns to the foreground, and on a timer while realtime is down. The host only subscribes:

```swift
Chatwoot.unreadCount
    .receive(on: DispatchQueue.main)
    .sink { count in
        // Badge on the chat entry point.
    }
```

## Appearance

The chat has two color sets, light and dark. `ChatwootTheme` picks which one is on screen:

| `darkMode` | Which colors are used |
| --- | --- |
| `.followSystem` (default) | `lightChatColors` while the system is light, `darkChatColors` while it is dark |
| `.light` | always `lightChatColors` |
| `.dark` | always `darkChatColors` |

Each set is a `ChatwootColors`. Leave a token `nil` to keep the SDK color for that appearance. Brand surfaces (the rows marked **accent** or **onAccent** below) fall back to `accent` / `onAccent` first, and those two fall back to the teal palette. Set `accent` alone to recolor the brand, then override a single bubble or the field only where the app needs a different color.

```swift
let theme = ChatwootTheme(
    lightChatColors: ChatwootColors(
        accent: Color(red: 0.10, green: 0.35, blue: 0.85),
        onAccent: .white,
        chatBackground: Color(red: 0.96, green: 0.96, blue: 0.97),
        incomingBubble: .white,
        composerField: Color(red: 0.93, green: 0.94, blue: 0.95)
    ),
    darkChatColors: ChatwootColors(
        accent: Color(red: 0.55, green: 0.75, blue: 1.0),
        onAccent: Color(red: 0.05, green: 0.10, blue: 0.18),
        chatBackground: Color(red: 0.08, green: 0.09, blue: 0.11),
        incomingBubble: Color(red: 0.16, green: 0.17, blue: 0.20),
        composerField: Color(red: 0.12, green: 0.13, blue: 0.16)
    ),
    darkMode: .followSystem
)
```

Colors are SwiftUI `Color` values, including colors from the asset catalog (`Color("Brand")`). Light and dark are separate values: a single dynamic `Color` is not split by the SDK, so set both `lightChatColors` and `darkChatColors`.

### Tokens

Defaults are the built-in palette. Hex values are opaque sRGB.

| Token | What it paints | Fallback | Light | Dark |
| --- | --- | --- | --- | --- |
| `accent` | Brand color. See the accent rows. Also filled survey stars. | palette | `#0B6E6D` | `#5FD4CF` |
| `onAccent` | Content on the brand color. See the onAccent rows. | palette | `#FFFFFF` | `#003735` |
| `navigationBar` | Navigation bar background, while the chat is visible | palette | `#FFFFFF` | `#24272C` |
| `onNavigationBar` | Navigation title and bar buttons | palette | `#222222` | `#ECECEC` |
| `chatBackground` | Feed background, behind the bubbles | palette | `#F2F4F5` | `#131518` |
| `outgoingBubble` | User's bubbles | accent | `#0B6E6D` | `#5FD4CF` |
| `onOutgoingBubble` | Text on the user's bubbles | onAccent | `#FFFFFF` | `#003735` |
| `outgoingMeta` | Time and status on the user's bubbles | onAccent at 85% | `#FFFFFF` at 85% | `#003735` at 85% |
| `outgoingLink` | Links on the user's bubbles (always underlined) | onAccent | `#FFFFFF` | `#003735` |
| `incomingBubble` | Agent's bubbles, including the typing bubble | palette | `#FFFFFF` | `#24272C` |
| `onIncomingBubble` | Text on the agent's bubbles | palette | `#222222` | `#ECECEC` |
| `incomingMeta` | Agent name, time, and the typing dots | palette | `#6B7078` | `#A3A8B0` |
| `incomingLink` | Links on the agent's bubbles | accent | `#0B6E6D` | `#5FD4CF` |
| `systemText` | System rows and the empty state | palette | `#6B7078` | `#A3A8B0` |
| `failed` | "Not sent" row | palette | `#C9383E` | `#FFB4AB` |
| `bannerContainer` | Connection banner | palette | `#FDF3DC` | `#3B3220` |
| `onBannerContainer` | Text and icon on the connection banner | palette | `#5C4300` | `#FBE3A8` |
| `composerContainer` | Bar behind the input | palette | `#FFFFFF` | `#24272C` |
| `composerField` | Input field background | palette | `#F2F4F5` | `#131518` |
| `composerText` | Text typed in the field | palette | `#222222` | `#ECECEC` |
| `composerPlaceholder` | Placeholder and the attach icon | palette | `#6B7078` | `#A3A8B0` |
| `composerSend` | Send button | accent | `#0B6E6D` | `#5FD4CF` |
| `onComposerSend` | Icon on the send button | onAccent | `#FFFFFF` | `#003735` |
| `composerDivider` | Hairline above the composer | palette | `#E3E6EA` | `#3A3E46` |
| `unreadDivider` | "New messages" chip | accent | `#0B6E6D` | `#5FD4CF` |
| `onUnreadDivider` | Label and icon on that chip | onAccent | `#FFFFFF` | `#003735` |
| `avatarPlaceholder` | Agent avatar with initials | palette | `#D3EFED` | `#1F4E4C` |
| `onAvatarPlaceholder` | Initials on the avatar | palette | `#00403E` | `#D0F2EF` |
| `dateChip` | Day separator chip | palette | `#D5DDE1` | `#3A414A` |
| `onDateChip` | Text on the day separator | palette | `#343D43` | `#DCE2E8` |

The survey card, the snackbar, and the image placeholder stay on the built-in neutral palette. Filled survey stars follow `accent`. File and image bubbles use the incoming or outgoing bubble colors. The chat paints the host navigation bar from `navigationBar` and `onNavigationBar` while it is on screen, then restores the bar it replaced.

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
