import XCTest
@testable import UsageRing

final class MarkedBlockTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("md-\(UUID()).md")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testUpsertThenRemoveRoundTripsToOriginal() throws {
        let original = "# My global rules\n\nSome existing content.\n"
        let url = try tempFile(original)
        defer { try? FileManager.default.removeItem(at: url) }

        try MarkedBlock.upsert(id: "x", body: "hello", in: url)
        XCTAssertTrue(MarkedBlock.contains(id: "x", in: url))
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Some existing content"))

        try MarkedBlock.remove(id: "x", from: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "exact round-trip")
    }

    func testUpsertIsIdempotent() throws {
        let url = try tempFile("base\n")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkedBlock.upsert(id: "x", body: "one", in: url)
        try MarkedBlock.upsert(id: "x", body: "two", in: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        let occurrences = text.components(separatedBy: MarkedBlock.begin("x")).count - 1
        XCTAssertEqual(occurrences, 1, "second upsert replaces, not appends")
        XCTAssertTrue(text.contains("two"))
        XCTAssertFalse(text.contains("one"))
    }

    func testCreatesFileWhenMissing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("new-\(UUID()).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try MarkedBlock.upsert(id: "x", body: "hi", in: url)
        XCTAssertTrue(MarkedBlock.contains(id: "x", in: url))
    }
}

final class SettingsHooksTests: XCTestCase {
    private func tempSettings(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private let entries = [
        SettingsHooks.Entry(event: "PreToolUse", matcher: "Read", command: "usagering --hook read-guard #usagering-managed"),
        SettingsHooks.Entry(event: "PostToolUse", matcher: "Bash", command: "usagering --hook bash-compress #usagering-managed"),
    ]

    func testApplyAddsHooksAndRemovePreservesUserHooks() throws {
        // A pre-existing user hook that must survive our add + remove.
        let url = try tempSettings("""
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"my-linter"}]}]}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        try SettingsHooks.apply(entries, to: url)
        XCTAssertTrue(SettingsHooks.isApplied(url))
        var root = try XCTUnwrap(ConfigIO.readJSON(url))
        XCTAssertEqual(root["model"] as? String, "opus", "unrelated keys preserved")
        let pre = try XCTUnwrap(root["hooks"] as? [String: Any])["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(pre?.count, 2, "our Read hook added alongside the user's Write hook")

        try SettingsHooks.remove(events: ["PreToolUse", "PostToolUse"], from: url)
        XCTAssertFalse(SettingsHooks.isApplied(url))
        root = try XCTUnwrap(ConfigIO.readJSON(url))
        let preAfter = try XCTUnwrap(root["hooks"] as? [String: Any])["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(preAfter?.count, 1, "the user's Write hook survives")
        let command = ((preAfter?[0]["hooks"] as? [[String: Any]])?[0]["command"]) as? String
        XCTAssertEqual(command, "my-linter")
    }

    func testApplyIsIdempotent() throws {
        let url = try tempSettings("{}")
        defer { try? FileManager.default.removeItem(at: url) }
        try SettingsHooks.apply(entries, to: url)
        try SettingsHooks.apply(entries, to: url)
        let post = (ConfigIO.readJSON(url)?["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        XCTAssertEqual(post?.count, 1, "re-apply replaces our group, not appends")
    }

    func testRemoveOnCleanSettingsIsNoOp() throws {
        let url = try tempSettings("{\"model\":\"sonnet\"}")
        defer { try? FileManager.default.removeItem(at: url) }
        try SettingsHooks.remove(events: ["PreToolUse", "PostToolUse"], from: url)
        XCTAssertEqual(ConfigIO.readJSON(url)?["model"] as? String, "sonnet")
    }
}

final class MCPStashTests: XCTestCase {
    private func makePaths(claudeJSON contents: String) throws -> ConfigPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = ConfigPaths(home: root)
        try Data(contents.utf8).write(to: paths.claudeJSON)
        return paths
    }

    func testDisableStashesAndRestoreReinstates() throws {
        let paths = try makePaths(claudeJSON: """
        {"oauthAccount":{"email":"dev@example.com"},"mcpServers":{"figma":{"command":"x"},"pencil":{"command":"y"}},"numberOfStartups":42}
        """)
        defer { try? FileManager.default.removeItem(at: paths.claudeDir.deletingLastPathComponent()) }

        try MCPStash.disable(paths)
        XCTAssertTrue(MCPStash.isDisabled(paths))
        var root = try XCTUnwrap(ConfigIO.readJSON(paths.claudeJSON))
        XCTAssertEqual((root["mcpServers"] as? [String: Any])?.count, 0, "servers removed while disabled")
        XCTAssertEqual((root["oauthAccount"] as? [String: Any])?["email"] as? String, "dev@example.com",
                       "unrelated keys untouched")
        XCTAssertEqual(root["numberOfStartups"] as? Int, 42)

        try MCPStash.enable(paths)
        XCTAssertFalse(MCPStash.isDisabled(paths))
        root = try XCTUnwrap(ConfigIO.readJSON(paths.claudeJSON))
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["figma", "pencil"], "servers restored verbatim")
    }

    func testDisableWritesAOneTimeBackup() throws {
        let paths = try makePaths(claudeJSON: "{\"mcpServers\":{\"a\":{}}}")
        defer { try? FileManager.default.removeItem(at: paths.claudeDir.deletingLastPathComponent()) }
        try MCPStash.disable(paths)
        let backup = paths.backupDir.appendingPathComponent("claude.json.orig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(try String(contentsOf: backup, encoding: .utf8).contains("\"a\""),
                      "backup holds the original servers")
    }
}

final class OptimizationManagerTests: XCTestCase {
    private func makeManager() throws -> (OptimizationManager, ConfigPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = ConfigPaths(home: root)
        // Seed a realistic ~/.claude.json and CLAUDE.md.
        try Data("{\"mcpServers\":{\"figma\":{\"command\":\"x\"}},\"projects\":{}}".utf8).write(to: paths.claudeJSON)
        try FileManager.default.createDirectory(at: paths.claudeDir, withIntermediateDirectories: true)
        try Data("# Existing global rules\n".utf8).write(to: paths.claudeMd)
        return (OptimizationManager(paths: paths, executablePath: "/Applications/UsageRing.app/Contents/MacOS/UsageRing"),
                paths, root)
    }

    func testEachToggleFlipsAndReports() throws {
        let (manager, _, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        for opt in OptimizationManager.Optimization.allCases {
            XCTAssertFalse(manager.isEnabled(opt), "\(opt) starts off")
            try manager.setEnabled(opt, true)
            XCTAssertTrue(manager.isEnabled(opt), "\(opt) turns on")
            try manager.setEnabled(opt, false)
            XCTAssertFalse(manager.isEnabled(opt), "\(opt) turns off")
        }
    }

    func testEfficiencyPackRoundTripLeavesConfigOriginal() throws {
        let (manager, paths, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalMd = try String(contentsOf: paths.claudeMd, encoding: .utf8)

        try manager.setEnabled(.efficiencyPack, true)
        XCTAssertTrue(SettingsHooks.isApplied(paths.settings))
        XCTAssertTrue(MarkedBlock.contains(id: "efficiency-terse", in: paths.claudeMd))
        // The hook command points at the app binary in --hook mode.
        let command = ((ConfigIO.readJSON(paths.settings)?["hooks"] as? [String: Any])?["PostToolUse"]
            as? [[String: Any]])?.first?["hooks"] as? [[String: Any]]
        XCTAssertTrue(((command?.first?["command"]) as? String ?? "").contains("--hook bash-compress"))

        try manager.setEnabled(.efficiencyPack, false)
        XCTAssertEqual(try String(contentsOf: paths.claudeMd, encoding: .utf8), originalMd,
                       "CLAUDE.md returns to its exact original")
        XCTAssertFalse(SettingsHooks.isApplied(paths.settings))
    }

    func testDisableMCPRoundTripPreservesServers() throws {
        let (manager, paths, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try manager.setEnabled(.disableMCP, true)
        XCTAssertEqual((ConfigIO.readJSON(paths.claudeJSON)?["mcpServers"] as? [String: Any])?.count, 0)
        try manager.setEnabled(.disableMCP, false)
        XCTAssertEqual(Set((ConfigIO.readJSON(paths.claudeJSON)?["mcpServers"] as? [String: Any] ?? [:]).keys),
                       ["figma"])
    }

    func testCavemanInstallsAndRemovesSkillFile() throws {
        let (manager, paths, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try manager.setEnabled(.caveman, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cavemanSkill.path))
        XCTAssertTrue(try String(contentsOf: paths.cavemanSkill, encoding: .utf8).contains("name: caveman"))
        try manager.setEnabled(.caveman, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cavemanSkill.path))
    }
}
