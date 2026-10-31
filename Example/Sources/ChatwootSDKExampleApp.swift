import ChatwootSDK
import CryptoKit
import SwiftUI

/// Example only: computes the identity on the device from the inbox HMAC token.
struct DebugIdentityProvider: IdentityProvider {
    let userId: String
    let hmacToken: String

    func fetch() async -> Result<Identity, ChatwootError> {
        let identifier = Self.hex(SHA256.hash(data: Data("sample-support-v1:\(userId)".utf8)))
        let key = SymmetricKey(data: Data(hmacToken.utf8))
        let hash = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(identifier.utf8), using: key))
        return .success(Identity(identifier: identifier, identifierHash: hash))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

@main
struct ChatwootSDKExampleApp: App {
    init() {
        SampleConfig.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
