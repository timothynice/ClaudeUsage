import XCTest
@testable import UsageRing

final class RefreshGateTests: XCTestCase {
    func testServerRetryAfterWins() {
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 1, retryAfter: 42), 42)
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 5, retryAfter: 7), 7)
    }

    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 1, retryAfter: nil), 300)
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 2, retryAfter: nil), 600)
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 3, retryAfter: nil), 900)
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 99, retryAfter: nil), 1800, "capped at 30 min")
    }

    func testRateLimitCycleAllowsBlocksThenRecovers() async {
        let gate = RefreshGate()
        let fingerprint = "abc123"

        var decision = await gate.decision(for: fingerprint)
        XCTAssertEqual(decision, .allowed)

        await gate.recordRateLimited(retryAfter: 60)
        decision = await gate.decision(for: fingerprint)
        XCTAssertEqual(decision, .blockedCooling, "cooldown active after a 429")

        await gate.recordSuccess()
        decision = await gate.decision(for: fingerprint)
        XCTAssertEqual(decision, .allowed, "success clears the cooldown")
    }

    func testRepeatedRateLimitsLengthenTheCooldown() async {
        let gate = RefreshGate()
        await gate.recordRateLimited(retryAfter: nil)
        await gate.recordRateLimited(retryAfter: nil)
        // Second failure should be backing off longer than the first would alone.
        XCTAssertEqual(RefreshGate.backoffInterval(failures: 2, retryAfter: nil), 600)
        let decision = await gate.decision(for: "abc123")
        XCTAssertEqual(decision, .blockedCooling)
    }
}
