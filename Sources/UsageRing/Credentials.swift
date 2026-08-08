import Foundation
import Security

/// Reads (and after a token refresh, writes back) the credentials Claude Code
/// keeps on this machine. Read order:
///   1. `security` CLI  — same Apple-signed binary Claude Code uses to manage
///      the item, so the keychain ACL allows it without a password prompt.
///   2. Security.framework — fallback; may show a one-time consent prompt.
///   3. `~/.claude/.credentials.json` — file fallback (Linux-style installs).
enum CredentialsStore {
    static let service = "Claude Code-credentials"
    static let refreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id (embedded in the CLI; required for token refresh).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let credentialsFile = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    // MARK: - Reading

    static func load() throws -> OAuthCredentials {
        guard let data = rawJSON() else { throw FetchError.noCredentials }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> OAuthCredentials {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.credentialsUnreadable
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            throw FetchError.credentialsUnreadable
        }
        var expiresAt: Date?
        if let number = oauth["expiresAt"] as? NSNumber {
            let value = number.doubleValue
            // Stored as milliseconds since epoch; tolerate seconds too.
            expiresAt = Date(timeIntervalSince1970: value > 4_102_444_800 ? value / 1000 : value)
        }
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String)
    }

    private static func rawJSON() -> Data? {
        viaSecurityCLI() ?? viaSecItem() ?? viaFile()
    }

    private static func viaSecurityCLI() -> Data? {
        guard let result = runSecurity(["find-generic-password", "-s", service, "-w"]),
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.data(using: .utf8)
    }

    private static func viaSecItem() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func viaFile() -> Data? {
        try? Data(contentsOf: credentialsFile)
    }

    // MARK: - Writing back after a token refresh

    /// Merge rotated tokens into the stored JSON (preserving every other field,
    /// e.g. `mcpOAuth`) and persist to wherever the credentials came from.
    /// Refresh tokens are single-use, so losing this write would sign the CLI
    /// out — which is why the merge rewrites the full original document.
    static func persistRefreshed(accessToken: String, refreshToken: String?, expiresAt: Date) {
        let fromKeychain = viaSecurityCLI() ?? viaSecItem()
        guard let data = fromKeychain ?? viaFile(),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        root["claudeAiOauth"] = oauth

        guard let json = try? JSONSerialization.data(withJSONObject: root),
              let jsonString = String(data: json, encoding: .utf8) else { return }

        if fromKeychain != nil {
            let account = keychainAccount() ?? NSUserName()
            _ = runSecurity(["add-generic-password", "-U", "-a", account, "-s", service, "-w", jsonString])
        } else {
            try? json.write(to: credentialsFile, options: .atomic)
        }
    }

    /// The existing item's account name, so `-U` updates it rather than adding a duplicate.
    private static func keychainAccount() -> String? {
        guard let result = runSecurity(["find-generic-password", "-s", service]),
              result.status == 0,
              let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            if let range = line.range(of: "\"acct\"<blob>=\"") {
                let rest = line[range.upperBound...]
                if let end = rest.firstIndex(of: "\"") {
                    return String(rest[..<end])
                }
            }
        }
        return nil
    }

    private static func runSecurity(_ arguments: [String]) -> (status: Int32, stdout: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // If the keychain ever decides to prompt and the user walks away,
        // don't hang the poll loop forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
