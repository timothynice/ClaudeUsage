import XCTest
@testable import UsageRing

final class HookHandlerTests: XCTestCase {
    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: Bash compression

    func testLargeOutputIsCompressedAndSmaller() throws {
        let big = (1...500).map { "line \($0) some content here" }.joined(separator: "\n")
        let out = try XCTUnwrap(HookHandler.compressBash(json(["tool_response": big])))
        let root = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any])
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        let replaced = try XCTUnwrap(specific["updatedToolOutput"] as? String)
        XCTAssertEqual(specific["hookEventName"] as? String, "PostToolUse")
        XCTAssertLessThan(replaced.count, big.count)
        XCTAssertTrue(replaced.contains("line 1 "), "keeps the head")
        XCTAssertTrue(replaced.contains("line 500"), "keeps the tail")
        XCTAssertTrue(replaced.contains("UsageRing"), "marks what it hid")
    }

    func testErrorLinesInTheMiddleAreKept() throws {
        // Padded so the payload clears the compression threshold.
        var lines = (1...200).map { "ok line \($0) — routine build output padding to exceed the size threshold" }
        lines[120] = "ERROR: the build exploded at widget.ts:42"
        let out = try XCTUnwrap(HookHandler.compressBash(json(["tool_response": lines.joined(separator: "\n")])))
        XCTAssertTrue(out.contains("the build exploded"), "notable middle lines survive compression")
    }

    func testSmallOutputIsLeftUntouched() {
        XCTAssertNil(HookHandler.compressBash(json(["tool_response": "just a short line\nand another"])))
    }

    func testStdoutStderrDictShapeIsHandled() throws {
        let big = String(repeating: "x", count: 6000)
        let out = HookHandler.compressBash(json(["tool_response": ["stdout": big, "stderr": ""]]))
        XCTAssertNotNil(out, "should read output from the {stdout,stderr} shape")
    }

    func testGarbageStdinPassesThrough() {
        XCTAssertNil(HookHandler.compressBash(Data("not json".utf8)))
        XCTAssertNil(HookHandler.compressBash(Data()))
        XCTAssertNil(HookHandler.compressBash(json(["something_else": 1])))
    }

    // MARK: Read guard

    func testReadGuardNudgesOnLargeFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID()).txt")
        try Data(repeating: 0x41, count: 200_000).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out = try XCTUnwrap(HookHandler.readGuard(json(["tool_input": ["file_path": tmp.path]])))
        let root = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any])
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "allow", "nudges, never blocks")
        XCTAssertTrue((specific["additionalContext"] as? String ?? "").contains("offset/limit"))
    }

    func testReadGuardSilentOnSmallFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("small-\(UUID()).txt")
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(HookHandler.readGuard(json(["tool_input": ["file_path": tmp.path]])))
    }

    func testReadGuardSilentWhenRangeAlreadyRequested() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("big2-\(UUID()).txt")
        try Data(repeating: 0x41, count: 200_000).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(HookHandler.readGuard(json(["tool_input": ["file_path": tmp.path, "offset": 1, "limit": 50]])),
                     "don't nag when the model already targeted a range")
    }
}
