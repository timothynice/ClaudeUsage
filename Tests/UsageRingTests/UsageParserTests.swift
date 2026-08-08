import XCTest
@testable import UsageRing

final class UsageParserTests: XCTestCase {
    // Synthetic payload matching the documented API response shape.
    let sample = """
    {
      "five_hour": {"utilization": 42, "resets_at": "2030-01-01T00:00:00Z"},
      "seven_day": {"utilization": 27, "resets_at": "2030-01-08T00:00:00Z"},
      "seven_day_opus": {"utilization": 13, "resets_at": "2030-01-15T00:00:00Z"}
    }
    """.data(using: .utf8)!

    func testParsesAllWindowsInStableOrder() throws {
        let snap = try UsageParser.parse(sample, accountType: "team")
        XCTAssertEqual(snap.windows.map(\.key), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(snap.accountType, "team")
    }

    func testFiveHourWindowValues() throws {
        let snap = try UsageParser.parse(sample)
        let five = try XCTUnwrap(snap.fiveHour)
        XCTAssertEqual(five.utilization, 42, accuracy: 0.001)
        XCTAssertEqual(five.label, "5-hour limit")
        let resets = try XCTUnwrap(five.resetsAt)
        XCTAssertEqual(resets.timeIntervalSince1970, 1893456000, accuracy: 1)
    }

    func testLabels() {
        XCTAssertEqual(UsageParser.label(for: "five_hour"), "5-hour limit")
        XCTAssertEqual(UsageParser.label(for: "seven_day"), "Weekly · all models")
        XCTAssertEqual(UsageParser.label(for: "seven_day_opus"), "Weekly · Opus")
        XCTAssertEqual(UsageParser.label(for: "seven_day_fable"), "Weekly · Fable")
        XCTAssertEqual(UsageParser.label(for: "some_new_window"), "Some New Window")
    }

    func testUnknownWindowsAreKeptAfterKnownOnes() throws {
        let json = """
        {
          "brand_new_limit": {"utilization": 12, "resets_at": "2026-08-01T00:00:00Z"},
          "five_hour": {"utilization": 40, "resets_at": "2026-08-01T00:00:00Z"}
        }
        """.data(using: .utf8)!
        let snap = try UsageParser.parse(json)
        XCTAssertEqual(snap.windows.map(\.key), ["five_hour", "brand_new_limit"])
    }

    func testNullAndNonWindowEntriesAreSkipped() throws {
        let json = """
        {
          "five_hour": {"utilization": 10, "resets_at": "2026-08-01T00:00:00Z"},
          "seven_day_opus": null,
          "some_flag": true,
          "note": "hi"
        }
        """.data(using: .utf8)!
        let snap = try UsageParser.parse(json)
        XCTAssertEqual(snap.windows.map(\.key), ["five_hour"])
    }

    func testUtilizationIsClampedTo0Through100() throws {
        let json = """
        {"five_hour": {"utilization": 130.5, "resets_at": "2026-08-01T00:00:00Z"}}
        """.data(using: .utf8)!
        let snap = try UsageParser.parse(json)
        XCTAssertEqual(snap.fiveHour?.utilization, 100)
        XCTAssertEqual(snap.fiveHour?.fraction, 1.0)
    }

    func testMissingResetDateIsTolerated() throws {
        let json = """
        {"five_hour": {"utilization": 5}}
        """.data(using: .utf8)!
        let snap = try UsageParser.parse(json)
        XCTAssertNil(snap.fiveHour?.resetsAt)
    }

    func testEmptyOrNonObjectResponseThrows() {
        XCTAssertThrowsError(try UsageParser.parse("[]".data(using: .utf8)!))
        XCTAssertThrowsError(try UsageParser.parse("{}".data(using: .utf8)!))
    }

    func testProfileParserTolerant() {
        let json = """
        {"account": {"email_address": "dev@example.com"}, "organization": {"name": "Example Organization"}}
        """.data(using: .utf8)!
        let p = ProfileParser.parse(json)
        XCTAssertEqual(p.email, "dev@example.com")
        XCTAssertEqual(p.organization, "Example Organization")
        // Garbage input never crashes
        XCTAssertEqual(ProfileParser.parse(Data()), ProfileInfo(email: nil, organization: nil))
    }
}
