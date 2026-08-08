import Foundation

/// Tolerant parser for the OAuth usage endpoint. The response is a JSON object
/// whose entries are rate-limit windows (`{"utilization": 0-100, "resets_at": ISO8601}`).
/// Windows we don't know yet still render, with a prettified label, so the app
/// keeps working when Anthropic adds or renames limits.
enum UsageParser {
    private static let knownOrder = [
        "five_hour",
        "seven_day",
        "seven_day_sonnet",
        "seven_day_opus",
        "seven_day_fable",
    ]

    static func parse(_ data: Data, accountType: String? = nil) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.parse("Usage response was not a JSON object.")
        }

        var windows: [UsageWindow] = []
        var credits: CreditsInfo?
        for (key, value) in root {
            guard let dict = value as? [String: Any] else { continue }
            if let utilization = doubleValue(dict["utilization"]) {
                windows.append(UsageWindow(
                    key: key,
                    label: label(for: key),
                    utilization: min(max(utilization, 0), 100),
                    resetsAt: parseDate(dict["resets_at"])))
            } else if credits == nil {
                credits = parseCredits(key: key, dict: dict)
            }
        }
        guard !windows.isEmpty else {
            throw FetchError.parse("No usage windows in response.")
        }
        windows.sort {
            (orderIndex($0.key), $0.key) < (orderIndex($1.key), $1.key)
        }
        return UsageSnapshot(windows: windows, credits: credits, accountType: accountType)
    }

    /// Parses the claude.ai web endpoint shape
    /// (GET /api/organizations/{org}/usage), which exposes a clean `limits`
    /// array plus a `spend` block. Falls back to the top-level window objects
    /// when `limits` is absent.
    static func parseWebUsage(_ data: Data, accountType: String? = nil) throws -> UsageSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FetchError.parse("Usage response was not a JSON object.")
        }

        var windows: [UsageWindow] = []
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            for limit in limits {
                guard let kind = limit["kind"] as? String else { continue }
                let (key, label) = webWindowLabel(kind: kind, scope: limit["scope"] as? [String: Any])
                windows.append(UsageWindow(
                    key: key,
                    label: label,
                    utilization: min(max(doubleValue(limit["percent"]) ?? 0, 0), 100),
                    resetsAt: parseDate(limit["resets_at"])))
            }
        } else {
            for key in ["five_hour", "seven_day"] {
                guard let dict = root[key] as? [String: Any],
                      let utilization = doubleValue(dict["utilization"]) else { continue }
                windows.append(UsageWindow(
                    key: key,
                    label: label(for: key),
                    utilization: min(max(utilization, 0), 100),
                    resetsAt: parseDate(dict["resets_at"])))
            }
        }
        guard !windows.isEmpty else { throw FetchError.parse("No usage windows in response.") }
        windows.sort { (orderIndex($0.key), $0.key) < (orderIndex($1.key), $1.key) }
        return UsageSnapshot(windows: windows, credits: parseSpend(root["spend"]), accountType: accountType)
    }

    private static func webWindowLabel(kind: String, scope: [String: Any]?) -> (key: String, label: String) {
        switch kind {
        case "session":
            return ("five_hour", "5-hour limit")
        case "weekly_all":
            return ("seven_day", "Weekly · all models")
        case "weekly_scoped":
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            if let model, !model.isEmpty {
                return ("seven_day_\(model.lowercased())", "Weekly · \(model)")
            }
            return ("seven_day_scoped", "Weekly · scoped")
        default:
            return (kind, titleCased(kind))
        }
    }

    /// `spend` reports money in minor units (cents) with an exponent. Shown as
    /// "Usage credits" whenever the account has spend enabled, matching Claude
    /// Code's own panel (which shows "$0.00 of $0.00").
    private static func parseSpend(_ any: Any?) -> CreditsInfo? {
        guard let spend = any as? [String: Any] else { return nil }
        func dollars(_ key: String) -> Double? {
            guard let bucket = spend[key] as? [String: Any],
                  let minor = doubleValue(bucket["amount_minor"]) else { return nil }
            let exponent = doubleValue(bucket["exponent"]) ?? 2
            return minor / pow(10, exponent)
        }
        let enabled = (spend["enabled"] as? Bool) ?? false
        guard let used = dollars("used"), let limit = dollars("limit") else { return nil }
        guard enabled || limit > 0 else { return nil }
        return CreditsInfo(usedUSD: used, limitUSD: limit)
    }

    /// True when a response body is Cloudflare's interstitial rather than JSON —
    /// happens when the desktop session's `cf_clearance` has gone stale.
    static func looksLikeCloudflareChallenge(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(600), encoding: .utf8) else { return false }
        return text.contains("Just a moment")
            || text.contains("cf-challenge")
            || text.contains("Enable JavaScript and cookies")
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour limit"
        case "seven_day": return "Weekly · all models"
        default:
            if key.hasPrefix("seven_day_") {
                return "Weekly · \(titleCased(String(key.dropFirst("seven_day_".count))))"
            }
            return titleCased(key)
        }
    }

    private static func titleCased(_ key: String) -> String {
        key.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    private static func orderIndex(_ key: String) -> Int {
        knownOrder.firstIndex(of: key) ?? knownOrder.count
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber else { return nil }
        // JSON booleans also bridge to NSNumber; they're not utilizations.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    private static func parseDate(_ any: Any?) -> Date? {
        if let string = any as? String {
            return isoWithFraction.date(from: string) ?? iso.date(from: string)
        }
        if let epoch = doubleValue(any) {
            // Heuristic: values past year 2100 must be milliseconds.
            return Date(timeIntervalSince1970: epoch > 4_102_444_800 ? epoch / 1000 : epoch)
        }
        return nil
    }

    /// Extra usage credits ("$0.00 of $0.00" in Claude Code's panel). Field
    /// names probed generously since this shape varies by plan.
    private static func parseCredits(key: String, dict: [String: Any]) -> CreditsInfo? {
        let lowered = key.lowercased()
        guard lowered.contains("extra") || lowered.contains("credit") || lowered.contains("overage") else {
            return nil
        }
        func amount(_ names: [String], scale: Double) -> Double? {
            for name in names {
                if let value = doubleValue(dict[name]) { return value / scale }
            }
            return nil
        }
        let used = amount(["used_cents", "used_credits_cents", "spent_cents"], scale: 100)
            ?? amount(["used", "used_usd", "used_credits", "used_dollars"], scale: 1)
        let limit = amount(["limit_cents", "monthly_limit_cents", "total_cents"], scale: 100)
            ?? amount(["limit", "limit_usd", "total_credits", "monthly_limit"], scale: 1)
        guard let used, let limit else { return nil }
        return CreditsInfo(usedUSD: used, limitUSD: limit)
    }
}

enum ProfileParser {
    static func parse(_ data: Data) -> ProfileInfo {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ProfileInfo(email: nil, organization: nil)
        }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        let email = (account?["email_address"] as? String) ?? (account?["email"] as? String)
        let orgName = (organization?["name"] as? String) ?? (organization?["organization_name"] as? String)
        return ProfileInfo(email: email, organization: orgName)
    }
}
