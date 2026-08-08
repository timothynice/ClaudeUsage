import XCTest
@testable import UsageRing

final class PermanentFailureTests: XCTestCase {
    private let credsA = "fingerprint-source-A"
    private let credsB = "fingerprint-source-B"

    func testFreshGateAllowsRefresh() async {
        let gate = RefreshGate()
        let decision = await gate.decision(for: credsA)
        XCTAssertEqual(decision, .allowed)
    }

    func testRateLimitBlocksTemporarily() async {
        let gate = RefreshGate()
        await gate.recordRateLimited(retryAfter: 120)
        let decision = await gate.decision(for: credsA)
        XCTAssertEqual(decision, .blockedCooling)
    }

    func testDeadCredentialsAreNeverRetried() async {
        let gate = RefreshGate()
        await gate.recordPermanentFailure(for: credsA)
        // Repeated polls must not produce more requests for the same dead token.
        for _ in 0..<5 {
            let decision = await gate.decision(for: credsA)
            XCTAssertEqual(decision, .blockedPermanently)
        }
    }

    func testNewCredentialsClearThePermanentBlock() async {
        let gate = RefreshGate()
        await gate.recordPermanentFailure(for: credsA)
        // Signing in again stores a different refresh token — retry immediately.
        let decision = await gate.decision(for: credsB)
        XCTAssertEqual(decision, .allowed)
    }

    func testSuccessResetsEverything() async {
        let gate = RefreshGate()
        await gate.recordPermanentFailure(for: credsA)
        await gate.recordRateLimited(retryAfter: 600)
        await gate.recordSuccess()
        let decision = await gate.decision(for: credsA)
        XCTAssertEqual(decision, .allowed)
    }

    func testOnlyInvalidGrantIsPermanent() {
        let invalidGrant = Data(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#.utf8)
        XCTAssertTrue(UsageClient.isPermanentFailure(status: 400, body: invalidGrant))

        // Everything else may succeed later and must stay retryable.
        XCTAssertFalse(UsageClient.isPermanentFailure(status: 429, body: nil))
        XCTAssertFalse(UsageClient.isPermanentFailure(status: 500, body: nil))
        XCTAssertFalse(UsageClient.isPermanentFailure(
            status: 400, body: Data(#"{"error":"temporarily_unavailable"}"#.utf8)))
        XCTAssertFalse(UsageClient.isPermanentFailure(status: 400, body: Data("garbage".utf8)))
        XCTAssertFalse(UsageClient.isPermanentFailure(status: 200, body: invalidGrant),
                       "a 200 is not a failure regardless of body")
    }

    func testFingerprintHidesTheTokenButStaysStable() {
        let token = "synthetic-refresh-token-value"
        let first = OAuthCredentials.fingerprint(of: token)
        let second = OAuthCredentials.fingerprint(of: token)
        XCTAssertEqual(first, second, "same token must map to the same fingerprint")
        XCTAssertNotEqual(first, OAuthCredentials.fingerprint(of: token + "x"))
        XCTAssertFalse(first.contains("synthetic"))
        XCTAssertFalse(first.contains(token))
        XCTAssertFalse(token.contains(first))
    }
}
