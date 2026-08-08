import Foundation

enum RefreshDecision: Equatable {
    /// Go ahead and try the token endpoint.
    case allowed
    /// These exact credentials were already rejected as invalid — retrying can
    /// never succeed, so don't send anything until the user signs in again.
    case blockedPermanently
    /// Transient backoff after a rate limit.
    case blockedCooling
}

/// Decides whether hitting the OAuth token endpoint is worth doing.
///
/// Without this, a dead refresh token would be retried on every poll — about
/// 1,400 futile requests a day per machine.
actor RefreshGate {
    static let shared = RefreshGate()

    private var cooldownUntil = Date.distantPast
    private var failures = 0
    private var deadFingerprint: String?

    func decision(for credentialFingerprint: String) -> RefreshDecision {
        if deadFingerprint == credentialFingerprint { return .blockedPermanently }
        return Date() >= cooldownUntil ? .allowed : .blockedCooling
    }

    /// The server declared these credentials invalid. Only signing in again
    /// (which produces a different refresh token) clears this.
    func recordPermanentFailure(for credentialFingerprint: String) {
        deadFingerprint = credentialFingerprint
    }

    func recordRateLimited(retryAfter: TimeInterval?) {
        failures += 1
        cooldownUntil = Date().addingTimeInterval(
            Self.backoffInterval(failures: failures, retryAfter: retryAfter))
    }

    func recordSuccess() {
        failures = 0
        cooldownUntil = .distantPast
        deadFingerprint = nil
    }

    /// Server-provided Retry-After wins; otherwise 5, 10, 15… minutes, capped at 30.
    static func backoffInterval(failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return retryAfter }
        return min(Double(max(failures, 1)) * 300, 1800)
    }
}
