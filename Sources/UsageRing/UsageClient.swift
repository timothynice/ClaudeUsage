import Foundation
import os

/// Talks to the same OAuth endpoints Claude Code's own `/usage` panel uses,
/// authenticating with the Claude Code credentials already on this machine.
///
/// Debugging note: do NOT probe these endpoints with `curl` — Cloudflare
/// bot-filters its TLS fingerprint and answers 429 "Rate limited" regardless
/// of your actual limits. URLSession gets truthful responses.
struct UsageClient {
    private static let logger = Logger(subsystem: "com.usagering.app", category: "auth")
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// A recent Safari UA so claude.ai's Cloudflare treats the replayed session
    /// like the browser that established it.
    private static let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Primary path: read usage through the Claude Desktop app's logged-in
    /// claude.ai session (no sign-in needed). Falls back to the OAuth token
    /// path only when there's no desktop session to use.
    func fetchUsage() async throws -> UsageSnapshot {
        do {
            let session = try DesktopSessionStore.load()
            return try await fetchWebUsage(session)
        } catch FetchError.noDesktopSession {
            return try await fetchOAuthUsage()
        }
    }

    private func fetchWebUsage(_ session: DesktopSessionStore.Session) async throws -> UsageSnapshot {
        let org: String
        if let last = session.lastActiveOrg {
            org = last
        } else {
            let orgsData = try await webGet(
                URL(string: DesktopSessionStore.organizationsURL)!, cookieHeader: session.cookieHeader)
            org = try DesktopSessionStore.chooseOrg(orgsData: orgsData, lastActive: nil)
        }
        let url = URL(string: "\(DesktopSessionStore.organizationsURL)/\(org)/usage")!
        let data = try await webGet(url, cookieHeader: session.cookieHeader)
        // subscriptionType survives in the CLI creds even when its token is dead;
        // used only for the cosmetic "TEAM" badge.
        let accountType = try? CredentialsStore.load().subscriptionType
        return try UsageParser.parseWebUsage(data, accountType: accountType)
    }

    private func webGet(_ url: URL, cookieHeader: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.network("No HTTP response") }
        if UsageParser.looksLikeCloudflareChallenge(data) { throw FetchError.desktopSessionStale }
        switch http.statusCode {
        case 200: return data
        case 401, 403: throw FetchError.desktopSessionStale
        default: throw FetchError.http(http.statusCode)
        }
    }

    private func fetchOAuthUsage() async throws -> UsageSnapshot {
        var creds = try CredentialsStore.load()
        // If the stored token looks expired, refresh proactively — but when the
        // refresh endpoint is rate-limiting us, still try the stale token: the
        // recorded expiry can be pessimistic.
        var refreshFailure: FetchError?
        if creds.isExpired {
            do {
                creds = try await refreshToken(current: creds)
            } catch let error as FetchError {
                refreshFailure = error
            }
        }
        do {
            let data = try await get(Self.usageURL, token: creds.accessToken)
            return try UsageParser.parse(data, accountType: creds.subscriptionType)
        } catch FetchError.tokenExpired {
            if let refreshFailure { throw refreshFailure }
            // Stored expiry was stale — refresh once and retry.
            creds = try await refreshToken(current: creds)
            let data = try await get(Self.usageURL, token: creds.accessToken)
            return try UsageParser.parse(data, accountType: creds.subscriptionType)
        }
    }

    func fetchProfile() async throws -> ProfileInfo {
        let creds = try CredentialsStore.load()
        let data = try await get(Self.profileURL, token: creds.accessToken)
        return ProfileParser.parse(data)
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UsageRing/1.0 (macOS menu bar)", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network("No HTTP response")
        }
        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw FetchError.tokenExpired("The API rejected the stored token.")
        default:
            throw FetchError.http(http.statusCode)
        }
    }

    /// Refresh the OAuth token the same way Claude Code does, and persist the
    /// rotated tokens back so the CLI and this app stay in sync.
    private func refreshToken(current: OAuthCredentials) async throws -> OAuthCredentials {
        // Claude Code may have refreshed since we loaded — reload before burning
        // the refresh token (they are single-use).
        if let latest = try? CredentialsStore.load(),
           latest.accessToken != current.accessToken, !latest.isExpired {
            return latest
        }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw FetchError.tokenExpired("No refresh token stored — run `claude` and sign in again.")
        }
        let fingerprint = OAuthCredentials.fingerprint(of: refreshToken)
        switch await RefreshGate.shared.decision(for: fingerprint) {
        case .allowed:
            break
        case .blockedCooling:
            throw FetchError.refreshRateLimited
        case .blockedPermanently:
            // Already known dead — report it without touching the network.
            throw FetchError.tokenExpired(Self.signInAgainMessage)
        }

        var request = URLRequest(url: CredentialsStore.refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": CredentialsStore.clientID,
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.network("No HTTP response")
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            await RefreshGate.shared.recordRateLimited(retryAfter: retryAfter)
            throw FetchError.refreshRateLimited
        }
        guard http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = obj["access_token"] as? String, !accessToken.isEmpty else {
            Self.logger.error("token refresh failed: HTTP \(http.statusCode, privacy: .public)")
            if Self.isPermanentFailure(status: http.statusCode, body: data) {
                await RefreshGate.shared.recordPermanentFailure(for: fingerprint)
            }
            throw FetchError.tokenExpired(Self.refreshFailureMessage(status: http.statusCode, body: data))
        }
        Self.logger.info("token refresh succeeded")

        await RefreshGate.shared.recordSuccess()
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        let newRefreshToken = obj["refresh_token"] as? String
        CredentialsStore.persistRefreshed(
            accessToken: accessToken, refreshToken: newRefreshToken, expiresAt: expiresAt)

        var updated = current
        updated.accessToken = accessToken
        if let newRefreshToken { updated.refreshToken = newRefreshToken }
        updated.expiresAt = expiresAt
        return updated
    }

    static let signInAgainMessage =
        "The saved Claude Code sign-in has expired on this Mac. "
        + "Click here to sign in again — the ring recovers automatically once you finish."

    /// True only for failures that will never resolve on their own.
    static func isPermanentFailure(status: Int, body: Data?) -> Bool {
        guard status == 400, let body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return false
        }
        return (obj["error"] as? String) == "invalid_grant"
    }

    static func refreshFailureMessage(status: Int, body: Data?) -> String {
        if let body,
           let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if (obj["error"] as? String) == "invalid_grant" {
                return signInAgainMessage
            }
            if let description = obj["error_description"] as? String, !description.isEmpty {
                return "Token refresh failed: \(description) (HTTP \(status)). "
                    + "If this persists, run `claude` and sign in again."
            }
        }
        return "Token refresh failed (HTTP \(status)). If this persists, run `claude` and sign in again."
    }
}
