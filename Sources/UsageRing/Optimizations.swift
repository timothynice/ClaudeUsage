import Foundation

/// Locations UsageRing may edit in the user's global Claude Code config.
/// Injectable so tests run against a temp home.
struct ConfigPaths {
    let claudeDir: URL
    let claudeJSON: URL

    var claudeMd: URL { claudeDir.appendingPathComponent("CLAUDE.md") }
    var settings: URL { claudeDir.appendingPathComponent("settings.json") }
    var skillsDir: URL { claudeDir.appendingPathComponent("skills") }
    var usageRingDir: URL { claudeDir.appendingPathComponent("usagering") }
    var mcpStash: URL { usageRingDir.appendingPathComponent("mcp-stash.json") }
    var backupDir: URL { usageRingDir.appendingPathComponent("backups") }
    var cavemanSkill: URL { skillsDir.appendingPathComponent("usagering-caveman/SKILL.md") }

    init(claudeDir: URL, claudeJSON: URL) {
        self.claudeDir = claudeDir
        self.claudeJSON = claudeJSON
    }

    init(home: URL) {
        self.init(claudeDir: home.appendingPathComponent(".claude"),
                  claudeJSON: home.appendingPathComponent(".claude.json"))
    }

    static var live: ConfigPaths { ConfigPaths(home: FileManager.default.homeDirectoryForCurrentUser) }
}

enum ConfigIO {
    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func writeText(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Insert / remove a uniquely-marked block inside a text file (e.g. CLAUDE.md),
/// leaving all other content byte-for-byte intact and round-tripping exactly.
enum MarkedBlock {
    static func begin(_ id: String) -> String { "<!-- BEGIN usagering:\(id) -->" }
    static func end(_ id: String) -> String { "<!-- END usagering:\(id) -->" }

    static func contains(id: String, in file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains(begin(id))
    }

    static func upsert(id: String, body: String, in file: URL) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let base = stripped(id: id, from: existing)
        let block = "\(begin(id))\n\(body)\n\(end(id))"
        let separator = base.isEmpty ? "" : "\n\n"
        try ConfigIO.writeText(base + separator + block, to: file)
    }

    static func remove(id: String, from file: URL) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try ConfigIO.writeText(stripped(id: id, from: text), to: file)
    }

    /// Remove the block and the exact separator `upsert` inserts before it.
    static func stripped(id: String, from text: String) -> String {
        guard let openRange = text.range(of: begin(id)),
              let closeRange = text.range(of: end(id)),
              openRange.lowerBound < closeRange.upperBound else { return text }
        var start = openRange.lowerBound
        let prefix = text[..<start]
        if prefix.hasSuffix("\n\n") {
            start = text.index(start, offsetBy: -2)
        } else if prefix.hasSuffix("\n") {
            start = text.index(start, offsetBy: -1)
        }
        return String(text[..<start]) + String(text[closeRange.upperBound...])
    }
}

/// Register / unregister UsageRing's own hooks in settings.json. Our hook
/// commands carry a `#usagering-managed` shell comment so removal touches only
/// ours and never the user's hooks.
enum SettingsHooks {
    static let marker = "#usagering-managed"

    struct Entry { let event: String; let matcher: String; let command: String }

    static func apply(_ entries: [Entry], to file: URL) throws {
        var root = ConfigIO.readJSON(file) ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for entry in entries {
            var groups = (hooks[entry.event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append([
                "matcher": entry.matcher,
                "hooks": [["type": "command", "command": entry.command]],
            ])
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
        try ConfigIO.writeJSON(root, to: file)
    }

    static func remove(events: [String], from file: URL) throws {
        guard var root = ConfigIO.readJSON(file), var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try ConfigIO.writeJSON(root, to: file)
    }

    static func isApplied(_ file: URL) -> Bool {
        guard let root = ConfigIO.readJSON(file), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) == true }
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }
}

/// Disable all user-scope MCP servers by stashing the `mcpServers` block out of
/// ~/.claude.json (restored verbatim on re-enable). Every other key in that
/// large, live file is preserved.
enum MCPStash {
    static func isDisabled(_ paths: ConfigPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.mcpStash.path)
    }

    static func disable(_ paths: ConfigPaths) throws {
        guard var root = ConfigIO.readJSON(paths.claudeJSON) else { return }
        try backupOnce(paths)
        let servers = root["mcpServers"] ?? [String: Any]()
        try ConfigIO.writeJSON(["mcpServers": servers], to: paths.mcpStash)
        root["mcpServers"] = [String: Any]()
        try ConfigIO.writeJSON(root, to: paths.claudeJSON)
    }

    static func enable(_ paths: ConfigPaths) throws {
        defer { try? FileManager.default.removeItem(at: paths.mcpStash) }
        guard let stash = ConfigIO.readJSON(paths.mcpStash), let servers = stash["mcpServers"] else { return }
        guard var root = ConfigIO.readJSON(paths.claudeJSON) else { return }
        root["mcpServers"] = servers
        try ConfigIO.writeJSON(root, to: paths.claudeJSON)
    }

    /// One-time full-file safety copy before the first edit.
    private static func backupOnce(_ paths: ConfigPaths) throws {
        let backup = paths.backupDir.appendingPathComponent("claude.json.orig")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.createDirectory(at: paths.backupDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: paths.claudeJSON.path) {
            try FileManager.default.copyItem(at: paths.claudeJSON, to: backup)
        }
    }
}

/// The three menu-bar toggles. Each maps to concrete, reversible config edits.
struct OptimizationManager {
    let paths: ConfigPaths
    let executablePath: String

    init(paths: ConfigPaths = .live, executablePath: String = HookCLI.currentExecutablePath) {
        self.paths = paths
        self.executablePath = executablePath
    }

    enum Optimization: String, CaseIterable, Identifiable {
        case efficiencyPack = "efficiency"
        case caveman
        case disableMCP = "disable_mcp"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .efficiencyPack: return "Efficiency pack"
            case .caveman: return "Caveman mode"
            case .disableMCP: return "Disable MCP servers"
            }
        }
        var subtitle: String {
            switch self {
            case .efficiencyPack: return "Terse output + trims huge file reads & noisy command output"
            case .caveman: return "Aggressively compress Claude's prose (code/commands stay exact)"
            case .disableMCP: return "Frees tool-definition tokens on every request — biggest steady save"
            }
        }
    }

    func isEnabled(_ optimization: Optimization) -> Bool {
        switch optimization {
        case .efficiencyPack: return MarkedBlock.contains(id: efficiencyBlockID, in: paths.claudeMd)
        case .caveman: return FileManager.default.fileExists(atPath: paths.cavemanSkill.path)
        case .disableMCP: return MCPStash.isDisabled(paths)
        }
    }

    func setEnabled(_ optimization: Optimization, _ on: Bool) throws {
        switch (optimization, on) {
        case (.efficiencyPack, true): try enableEfficiency()
        case (.efficiencyPack, false): try disableEfficiency()
        case (.caveman, true): try ConfigIO.writeText(Self.cavemanSkillBody, to: paths.cavemanSkill)
        case (.caveman, false): try? FileManager.default.removeItem(
            at: paths.cavemanSkill.deletingLastPathComponent())
        case (.disableMCP, true): try MCPStash.disable(paths)
        case (.disableMCP, false): try MCPStash.enable(paths)
        }
    }

    // MARK: Efficiency pack

    private let efficiencyBlockID = "efficiency-terse"

    private func hookEntries() -> [SettingsHooks.Entry] {
        let quoted = "\"\(executablePath)\""
        return [
            .init(event: "PreToolUse", matcher: "Read",
                  command: "\(quoted) --hook read-guard \(SettingsHooks.marker)"),
            .init(event: "PostToolUse", matcher: "Bash",
                  command: "\(quoted) --hook bash-compress \(SettingsHooks.marker)"),
        ]
    }

    private func enableEfficiency() throws {
        try MarkedBlock.upsert(id: efficiencyBlockID, body: Self.terseBody, in: paths.claudeMd)
        try SettingsHooks.apply(hookEntries(), to: paths.settings)
    }

    private func disableEfficiency() throws {
        try MarkedBlock.remove(id: efficiencyBlockID, from: paths.claudeMd)
        try SettingsHooks.remove(events: ["PreToolUse", "PostToolUse"], from: paths.settings)
    }

    static let terseBody = """
    ## Token efficiency (managed by UsageRing — toggle in the menu bar)
    - Be concise. Skip preamble and postamble; don't restate the question or summarize what you just did unless asked.
    - Prefer the smallest correct answer. Reference file paths and line numbers instead of pasting file contents back.
    - Read only the ranges you need (offset/limit) rather than whole files when you can target them.
    - Don't echo large command output; rely on the compressed summaries.
    """

    static let cavemanSkillBody = """
    ---
    name: caveman
    description: Ultra-terse "caveman" output. When active, respond in compressed, fragmentary prose to minimize output tokens — while keeping all code, commands, file paths, URLs, numbers, and error text byte-for-byte exact.
    ---
    # Caveman output mode

    Talk like caveman. Few word do trick. Cut filler, pleasantries, hedging, restating the
    question, and summaries of what you just did.

    Keep EXACT and untouched: code blocks, shell commands, file paths, URLs, numbers,
    identifiers, and error messages. Never compress those.

    Use fragments over full sentences. No "I'll now…", "Let me…", "Great!", "Sure!". Give the
    answer, then stop.

    (Inspired by the open-source "Caveman" skill by JuliusBrussee; wording original.)
    """
}
