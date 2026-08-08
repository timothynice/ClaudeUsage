import Foundation

/// One rate-limit window as reported by the OAuth usage endpoint.
struct UsageWindow: Identifiable, Equatable {
    let key: String
    let label: String
    let utilization: Double // 0–100
    let resetsAt: Date?

    var id: String { key }
    var fraction: Double { min(max(utilization / 100.0, 0), 1) }
}

/// Extra usage-credit balance, when the account reports one.
struct CreditsInfo: Equatable {
    let usedUSD: Double
    let limitUSD: Double
}

struct UsageSnapshot: Equatable {
    let windows: [UsageWindow]
    let credits: CreditsInfo?
    let accountType: String?

    var fiveHour: UsageWindow? { windows.first { $0.key == "five_hour" } }
}

struct ProfileInfo: Equatable {
    let email: String?
    let organization: String?
}

struct OAuthCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var subscriptionType: String?

    /// A one-way identifier for a token, used to tell "same credentials as the
    /// ones the server rejected" from "the user signed in again" without
    /// holding or logging the secret itself.
    static func fingerprint(of token: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Treat tokens expiring within the next minute as already expired.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum FetchError: Error, Equatable {
    case noCredentials
    case credentialsUnreadable
    case tokenExpired(String)
    case refreshRateLimited
    case http(Int)
    case network(String)
    case parse(String)
    // Desktop-session path (reads the Claude Desktop app's claude.ai login).
    case noDesktopSession
    case desktopSessionLocked
    case desktopSessionStale

    var title: String {
        switch self {
        case .noCredentials: return "No Claude Code credentials"
        case .credentialsUnreadable: return "Couldn't read credentials"
        case .tokenExpired: return "Session token expired"
        case .refreshRateLimited: return "Token refresh rate-limited"
        case .http(let code): return "Anthropic returned HTTP \(code)"
        case .network: return "Network error"
        case .parse: return "Unexpected response"
        case .noDesktopSession: return "Not signed in"
        case .desktopSessionLocked: return "Keychain access needed"
        case .desktopSessionStale: return "Session needs a refresh"
        }
    }

    /// True when signing in again would actually fix this — never for
    /// transient network or server problems.
    var isSignInFixable: Bool {
        switch self {
        case .noCredentials, .credentialsUnreadable, .tokenExpired:
            return true
        case .refreshRateLimited, .http, .network, .parse,
             .noDesktopSession, .desktopSessionLocked, .desktopSessionStale:
            return false
        }
    }

    var message: String {
        switch self {
        case .noCredentials:
            return "Sign in to Claude Code first: run `claude` in a terminal and log in, then refresh here."
        case .credentialsUnreadable:
            return "The Claude Code keychain entry exists but couldn't be parsed."
        case .tokenExpired(let detail):
            return detail
        case .refreshRateLimited:
            return "Anthropic is rate-limiting token refreshes. Will retry on the next poll."
        case .http:
            return "Temporary server issue — will retry automatically."
        case .network(let detail), .parse(let detail):
            return detail
        case .noDesktopSession:
            return "Sign in to Claude Code or the Claude desktop app, then refresh."
        case .desktopSessionLocked:
            return "Approve the “Claude Safe Storage” keychain prompt (choose Always Allow) so the "
                + "usage data can be read from the desktop app’s session."
        case .desktopSessionStale:
            return "Open the Claude desktop app once to refresh its session, then this updates automatically."
        }
    }
}
