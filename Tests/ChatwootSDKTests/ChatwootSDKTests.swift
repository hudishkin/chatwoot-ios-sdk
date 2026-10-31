import XCTest
@testable import ChatwootSDK

final class ChatwootSDKTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(ChatwootSDK.version.isEmpty)
    }
}
