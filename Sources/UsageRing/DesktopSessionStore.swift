import Foundation

/// Reads the Claude Desktop app's logged-in claude.ai session so UsageRing can
/// work without its own sign-in. All of this is the user's own data and stays
/// on the machine.
///
/// The desktop app is Electron/Chromium: cookies live in a SQLite DB with each
/// value AES-encrypted under a key stored in the "Claude Safe Storage" keychain
/// item (Chromium's standard `OSCrypt` scheme on macOS).
enum DesktopSessionStore {
    static let organizationsURL = "https://claude.ai/api/organizations"
    static let safeStorageService = "Claude Safe Storage"

    private static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude")

    struct Session {
        let cookieHeader: String
        let lastActiveOrg: String?
    }

    // MARK: - Cookie decryption

    static func decryptCookieValue(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let ciphertext = Data(blob.dropFirst(3))
        guard let raw = try? Crypto.aes128CBCDecrypt(
            ciphertext: ciphertext, key: key, iv: Data(repeating: 0x20, count: 16)) else {
            return nil
        }
        // Newer Chromium prepends a 32-byte SHA-256 domain hash; older builds
        // don't. Try the value as-is first, then with the prefix stripped.
        let candidates = [raw, raw.count > 32 ? Data(raw.dropFirst(32)) : nil].compactMap { $0 }
        for candidate in candidates {
            if let text = String(data: candidate, encoding: .utf8), isLikelyText(text) {
                return text
            }
        }
        return nil
    }

    private static func isLikelyText(_ string: String) -> Bool {
        !string.isEmpty && !string.unicodeScalars.contains {
            $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r"
        }
    }

    // MARK: - Organization selection

    /// Which org's usage to show. The desktop app's `lastActiveOrg` cookie is
    /// authoritative; otherwise prefer a paid (stripe) org, then a Claude Code
    /// ("raven") org, then whatever's first.
    static func chooseOrg(orgsData: Data, lastActive: String?) throws -> String {
        guard let orgs = (try? JSONSerialization.jsonObject(with: orgsData)) as? [[String: Any]],
              !orgs.isEmpty else {
            throw FetchError.parse("Could not read the organization list.")
        }
        let known = Set(orgs.compactMap { $0["uuid"] as? String })
        if let lastActive, known.contains(lastActive) { return lastActive }
        if let paid = orgs.first(where: { ($0["billing_type"] as? String) == "stripe_subscription" }),
           let uuid = paid["uuid"] as? String { return uuid }
        if let raven = orgs.first(where: {
            ($0["capabilities"] as? [String])?.contains("raven") == true }),
           let uuid = raven["uuid"] as? String { return uuid }
        if let first = orgs.first?["uuid"] as? String { return first }
        throw FetchError.parse("No organizations found for this account.")
    }

    // MARK: - Loading

    static func load() throws -> Session {
        let cookiesURL = appSupport.appendingPathComponent("Cookies")
        guard FileManager.default.fileExists(atPath: cookiesURL.path) else {
            throw FetchError.noDesktopSession
        }
        guard let password = safeStorageKey(), !password.isEmpty else {
            throw FetchError.desktopSessionLocked
        }
        let aesKey = try Crypto.pbkdf2SHA1(
            password: password, salt: "saltysalt", rounds: 1003, keyLength: 16)

        var cookies: [String: String] = [:]
        for (name, hexValue) in try readCookieRows(cookiesURL) {
            if let value = decryptCookieValue(Data(hex: hexValue), key: aesKey) {
                cookies[name] = value
            }
        }
        guard let sessionKey = cookies["sessionKey"], !sessionKey.isEmpty else {
            // Desktop app present but not signed in — let the caller try other paths.
            throw FetchError.noDesktopSession
        }
        let header = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Session(cookieHeader: header, lastActiveOrg: cookies["lastActiveOrg"])
    }

    // MARK: - Plumbing

    private static func safeStorageKey() -> String? {
        guard let output = run("/usr/bin/security",
                               ["find-generic-password", "-s", safeStorageService, "-w"]),
              output.status == 0,
              let text = String(data: output.data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Copies the (possibly WAL-backed) cookie DB somewhere stable and reads the
    /// claude.ai rows as `name<TAB>hex(encrypted_value)` via the sqlite3 CLI.
    private static func readCookieRows(_ cookiesURL: URL) throws -> [(String, String)] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageRing-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbCopy = tempDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: cookiesURL, to: dbCopy)
        for suffix in ["-wal", "-shm"] {
            let side = cookiesURL.deletingLastPathComponent()
                .appendingPathComponent("Cookies\(suffix)")
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(
                    at: side, to: tempDir.appendingPathComponent("Cookies\(suffix)"))
            }
        }

        let query = "SELECT name || char(9) || hex(encrypted_value) FROM cookies "
            + "WHERE host_key LIKE '%claude.ai%';"
        guard let output = run("/usr/bin/sqlite3", ["-readonly", dbCopy.path, query]),
              output.status == 0,
              let text = String(data: output.data, encoding: .utf8) else {
            throw FetchError.credentialsUnreadable
        }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, data: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Don't let an unexpected keychain prompt wedge the poll loop forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if process.isRunning { process.terminate() }
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
