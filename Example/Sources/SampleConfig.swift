import ChatwootSDK
import Foundation
import UIKit

/// Test-server values from `Example/Resources/config.json` (git-ignored, see
/// `config.example.json`). Without the file the example stays on the
/// "not configured" screen. The HMAC token is for this example only:
/// a real app must fetch the identifier hash from its backend.
enum SampleConfig {
    private struct File: Decodable {
        let baseURL: String
        let inboxIdentifier: String
        let inboxID: Int
        let hmacToken: String
    }

    private static let file: File? = Bundle.main.url(forResource: "config", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(File.self, from: $0) }

    static let baseURL = file?.baseURL ?? ""
    static let inboxIdentifier = file?.inboxIdentifier ?? ""
    static let inboxID = file?.inboxID ?? 0
    static let hmacToken = file?.hmacToken ?? ""

    static var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !inboxIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inboxID > 0
            && !hmacToken.isEmpty
    }

    static func install() {
        guard isConfigured else { return }
        do {
            let config = try ChatwootConfig(
                baseURL: baseURL,
                inboxIdentifier: inboxIdentifier,
                inboxID: inboxID,
                debugConsoleLogging: true
            )
            Chatwoot.initialize(config)
        } catch {
            installFailed = true
        }
    }

    static var installFailed = false

    static var userID: String {
        let vendor = UIDevice.current.identifierForVendor?.uuidString ?? "example"
        return "sample-\(vendor)"
    }
}
