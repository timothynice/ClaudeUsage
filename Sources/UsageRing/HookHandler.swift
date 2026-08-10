import Foundation

/// The logic behind UsageRing's Claude Code hooks. Hooks invoke the app binary
/// in `--hook <name>` mode (see `HookCLI`), so all parsing lives here in tested
/// Swift rather than depending on `jq`/`python` being present.
///
/// Every handler is fail-safe: on any doubt it returns `nil` (emit nothing →
/// Claude Code proceeds unchanged), so a hook can never corrupt tool output.
enum HookHandler {
    /// Compress Bash output larger than this many characters (roughly 1k tokens).
    static let bashCompressThreshold = 4000
    /// Nudge on Read when the target file is larger than this many bytes.
    static let readGuardByteThreshold = 100_000

    // MARK: PostToolUse(Bash) — compress noisy command output

    static func compressBash(_ stdin: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              let text = extractOutput(root), text.count > bashCompressThreshold else {
            return nil
        }
        let compressed = compress(text)
        guard compressed.count < text.count else { return nil }
        return hookOutput(event: "PostToolUse", fields: ["updatedToolOutput": compressed])
    }

    /// Pulls the command output out of the PostToolUse stdin, tolerating the
    /// several shapes `tool_response` can take across Claude Code versions.
    static func extractOutput(_ root: [String: Any]) -> String? {
        for key in ["tool_response", "tool_output", "tool_result"] {
            if let string = root[key] as? String, !string.isEmpty { return string }
            if let dict = root[key] as? [String: Any] {
                for inner in ["stdout", "output", "content", "stderr", "result"] {
                    if let string = dict[inner] as? String, !string.isEmpty { return string }
                }
            }
        }
        return nil
    }

    static func compress(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let headCount = 40, tailCount = 20
        guard lines.count > headCount + tailCount + 5 else {
            // Not many lines but big (one long blob) — clip by characters.
            let head = String(text.prefix(2500))
            let tail = String(text.suffix(1500))
            return head + "\n… [UsageRing trimmed \(text.count - 4000) chars] …\n" + tail
        }
        let head = lines.prefix(headCount)
        let tail = lines.suffix(tailCount)
        let middle = lines.dropFirst(headCount).dropLast(tailCount)

        let pattern = "(?i)(error|fail|fatal|exception|traceback|warning|denied|panic|not found|cannot|refused|✗|✘|❌)"
        let regex = try? NSRegularExpression(pattern: pattern)
        var notable: [String] = []
        for line in middle {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex?.firstMatch(in: line, range: range) != nil {
                notable.append(line)
                if notable.count >= 40 { break }
            }
        }

        var parts = Array(head)
        if notable.isEmpty {
            parts.append("… [UsageRing compressed \(middle.count) middle lines] …")
        } else {
            parts.append("… [UsageRing hid \(middle.count) lines; kept \(notable.count) notable] …")
            parts.append(contentsOf: notable)
        }
        parts.append(contentsOf: tail)
        return parts.joined(separator: "\n")
    }

    // MARK: PreToolUse(Read) — nudge away from whole-file reads

    static func readGuard(_ stdin: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any],
              let input = root["tool_input"] as? [String: Any],
              let path = input["file_path"] as? String,
              // If the model already targeted a range, don't nag.
              input["offset"] == nil, input["limit"] == nil else {
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > readGuardByteThreshold else {
            return nil
        }
        let note = "\(path) is ~\(size / 1024) KB. To save tokens, read only the ranges you need "
            + "with the Read tool's offset/limit rather than the whole file."
        return hookOutput(event: "PreToolUse",
                          fields: ["permissionDecision": "allow", "additionalContext": note])
    }

    // MARK: -

    private static func hookOutput(event: String, fields: [String: Any]) -> String? {
        var specific = fields
        specific["hookEventName"] = event
        let payload: [String: Any] = ["hookSpecificOutput": specific]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Command-line entry for hook mode. Reads stdin, runs the handler, prints the
/// result (if any), and exits — without touching AppKit.
enum HookCLI {
    static var currentExecutablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "UsageRing"
    }

    static func run(event: String) {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let output: String?
        switch event {
        case "bash-compress": output = HookHandler.compressBash(data)
        case "read-guard": output = HookHandler.readGuard(data)
        default: output = nil
        }
        if let output { print(output) }
    }
}
