import XCTest
@testable import UsageRing

/// Exercises the parser against a synthetic payload matching the shape returned by
/// GET https://claude.ai/api/organizations/{org}/usage.
final class WebUsageParserTests: XCTestCase {
    let payload = """
    {
      "five_hour": {"utilization": 25.0, "resets_at": "2030-01-01T00:00:00Z"},
      "seven_day": {"utilization": 50.0, "resets_at": "2030-01-08T00:00:00Z"},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 0, "used_credits": 0.0},
      "limits": [
        {"kind": "session", "group": "session", "percent": 25, "severity": "normal",
         "resets_at": "2030-01-01T00:00:00Z", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 50, "severity": "normal",
         "resets_at": "2030-01-08T00:00:00Z", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 75, "severity": "warning",
         "resets_at": "2030-01-08T00:00:00Z",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
      ],
      "spend": {
        "used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
        "limit": {"amount_minor": 0, "currency": "USD", "exponent": 2},
        "percent": 0, "severity": "normal", "enabled": true
      }
    }
    """.data(using: .utf8)!

    func testProducesExpectedWindows() throws {
        let snap = try UsageParser.parseWebUsage(payload, accountType: "team")
        XCTAssertEqual(snap.windows.map(\.label),
                       ["5-hour limit", "Weekly · all models", "Weekly · Fable"])
        XCTAssertEqual(snap.accountType, "team")
    }

    func testFiveHourValuesDriveTheRing() throws {
        let snap = try UsageParser.parseWebUsage(payload)
        let five = try XCTUnwrap(snap.fiveHour)
        XCTAssertEqual(five.utilization, 25, accuracy: 0.001)
        XCTAssertEqual(five.resetsAt?.timeIntervalSince1970 ?? 0, 1893456000, accuracy: 1)
    }

    func testScopedWeeklyIsLabelledByModel() throws {
        let snap = try UsageParser.parseWebUsage(payload)
        let fable = try XCTUnwrap(snap.windows.first { $0.label == "Weekly · Fable" })
        XCTAssertEqual(fable.utilization, 75, accuracy: 0.001)
        XCTAssertEqual(fable.key, "seven_day_fable")
    }

    func testSpendBecomesUsageCredits() throws {
        let snap = try UsageParser.parseWebUsage(payload)
        let credits = try XCTUnwrap(snap.credits)
        XCTAssertEqual(credits.usedUSD, 0, accuracy: 0.001)
        XCTAssertEqual(credits.limitUSD, 0, accuracy: 0.001)
    }

    func testSpendMinorUnitsAreScaledByExponent() throws {
        let json = """
        {"limits": [{"kind":"session","percent":10,"resets_at":"2026-08-01T22:00:00Z"}],
         "spend": {"used": {"amount_minor": 1234, "exponent": 2},
                   "limit": {"amount_minor": 5000, "exponent": 2}, "enabled": true}}
        """.data(using: .utf8)!
        let credits = try XCTUnwrap(try UsageParser.parseWebUsage(json).credits)
        XCTAssertEqual(credits.usedUSD, 12.34, accuracy: 0.001)
        XCTAssertEqual(credits.limitUSD, 50.0, accuracy: 0.001)
    }

    func testNullScopedWindowsAreIgnored() throws {
        // Payloads may carry null future-limit keys; none should appear.
        let snap = try UsageParser.parseWebUsage(payload)
        XCTAssertFalse(snap.windows.contains { $0.label.contains("null") })
        XCTAssertEqual(snap.windows.count, 3)
    }

    func testFallsBackToTopLevelWindowsWhenLimitsAbsent() throws {
        let json = """
        {"five_hour": {"utilization": 88, "resets_at": "2026-08-01T22:00:00Z"},
         "seven_day": {"utilization": 12, "resets_at": "2026-08-04T13:00:00Z"}}
        """.data(using: .utf8)!
        let snap = try UsageParser.parseWebUsage(json)
        XCTAssertEqual(snap.windows.map(\.key), ["five_hour", "seven_day"])
        XCTAssertEqual(snap.fiveHour?.utilization, 88)
    }

    func testEmptyPayloadThrows() {
        XCTAssertThrowsError(try UsageParser.parseWebUsage("{}".data(using: .utf8)!))
        XCTAssertThrowsError(try UsageParser.parseWebUsage("garbage".data(using: .utf8)!))
    }

    func testCloudflareChallengeIsDetectable() {
        let html = Data("<!DOCTYPE html><html><head><title>Just a moment...</title>".utf8)
        XCTAssertTrue(UsageParser.looksLikeCloudflareChallenge(html))
        XCTAssertFalse(UsageParser.looksLikeCloudflareChallenge(payload))
    }
}

final class OrgSelectionTests: XCTestCase {
    let orgsJSON = """
    [
      {"uuid": "org-usage-example", "name": "Example Usage Organization", "billing_type": "usage_based",
       "capabilities": []},
      {"uuid": "org-individual-example", "name": "Example Individual", "billing_type": null, "capabilities": ["chat"]},
      {"uuid": "org-subscription-example", "name": "Example Subscription Organization", "billing_type": "stripe_subscription",
       "capabilities": ["chat", "raven"]}
    ]
    """.data(using: .utf8)!

    func testPrefersLastActiveOrgWhenProvided() throws {
        let uuid = try DesktopSessionStore.chooseOrg(orgsData: orgsJSON, lastActive: "org-individual-example")
        XCTAssertEqual(uuid, "org-individual-example")
    }

    func testFallsBackToSubscriptionOrgWhenNoLastActive() throws {
        // The Claude Code / raven org billed via stripe is the right default.
        let uuid = try DesktopSessionStore.chooseOrg(orgsData: orgsJSON, lastActive: nil)
        XCTAssertEqual(uuid, "org-subscription-example")
    }

    func testIgnoresLastActiveThatIsNoLongerAMembership() throws {
        let uuid = try DesktopSessionStore.chooseOrg(orgsData: orgsJSON, lastActive: "deleted-org")
        XCTAssertEqual(uuid, "org-subscription-example", "unknown last-active falls back to the best membership")
    }
}
