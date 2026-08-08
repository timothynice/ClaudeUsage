import XCTest
@testable import UsageRing

final class RefreshMessageTests: XCTestCase {
    func testInvalidGrantGetsActionableSignInMessage() {
        let body = #"{"error": "invalid_grant", "error_description": "Refresh token expired"}"#
            .data(using: .utf8)
        let message = UsageClient.refreshFailureMessage(status: 400, body: body)
        XCTAssertTrue(message.contains("sign-in has expired"), message)
        // The banner itself is the button now, so point at it rather than at a
        // command the user would have to go find a terminal for.
        XCTAssertTrue(message.localizedCaseInsensitiveContains("click here"), message)
        XCTAssertFalse(message.contains("HTTP 400"), "invalid_grant message should be plain-English only")
    }

    func testOtherErrorsSurfaceServerDescriptionAndStatus() {
        let body = #"{"error": "server_error", "error_description": "Something broke"}"#
            .data(using: .utf8)
        let message = UsageClient.refreshFailureMessage(status: 500, body: body)
        XCTAssertTrue(message.contains("Something broke"), message)
        XCTAssertTrue(message.contains("HTTP 500"), message)
    }

    func testMissingOrGarbageBodyFallsBackToStatus() {
        XCTAssertTrue(UsageClient.refreshFailureMessage(status: 502, body: nil).contains("HTTP 502"))
        XCTAssertTrue(UsageClient.refreshFailureMessage(status: 503, body: Data("nope".utf8)).contains("HTTP 503"))
    }
}
