import XCTest
@testable import UsageRing

final class CredentialsTests: XCTestCase {
    // Mirrors the keychain payload structure with synthetic token values.
    let sample = """
    {
      "claudeAiOauth": {
        "accessToken": "test-access-token",
        "refreshToken": "test-refresh-token",
        "expiresAt": 1785517200000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "team",
        "rateLimitTier": "default_claude_ai"
      },
      "mcpOAuth": {}
    }
    """.data(using: .utf8)!

    func testParsesNestedClaudeAiOauthShape() throws {
        let creds = try CredentialsStore.parse(sample)
        XCTAssertEqual(creds.accessToken, "test-access-token")
        XCTAssertEqual(creds.refreshToken, "test-refresh-token")
        XCTAssertEqual(creds.subscriptionType, "team")
        // expiresAt is milliseconds since epoch
        XCTAssertEqual(try XCTUnwrap(creds.expiresAt).timeIntervalSince1970, 1785517200, accuracy: 1)
    }

    func testParsesFlatShape() throws {
        let flat = """
        {"accessToken": "tok", "refreshToken": "r", "expiresAt": 1785517200000}
        """.data(using: .utf8)!
        let creds = try CredentialsStore.parse(flat)
        XCTAssertEqual(creds.accessToken, "tok")
    }

    func testMissingAccessTokenThrows() {
        let bad = """
        {"claudeAiOauth": {"refreshToken": "r"}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CredentialsStore.parse(bad))
        XCTAssertThrowsError(try CredentialsStore.parse("not json".data(using: .utf8)!))
    }

    func testExpiryLogic() {
        var creds = OAuthCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil, subscriptionType: nil)
        XCTAssertFalse(creds.isExpired, "no expiry recorded means assume valid and let the API decide")
        creds.expiresAt = Date().addingTimeInterval(-10)
        XCTAssertTrue(creds.isExpired)
        creds.expiresAt = Date().addingTimeInterval(30)
        XCTAssertTrue(creds.isExpired, "tokens about to expire within the 60s margin count as expired")
        creds.expiresAt = Date().addingTimeInterval(3600)
        XCTAssertFalse(creds.isExpired)
    }
}
