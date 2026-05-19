import Foundation

/// Codex (OpenAI) usage data from /backend-api/wham/usage
struct CodexUsageData {
    let planType: String
    let primaryUsedPercent: Int
    let primaryResetAt: Date?
    let primaryWindowSeconds: Int
    let secondaryUsedPercent: Int
    let secondaryResetAt: Date?
    let secondaryWindowSeconds: Int
    let limitReached: Bool
    let allowed: Bool
    let creditBalance: Double?
    let approxLocalMessages: [Int]?
    let approxCloudMessages: [Int]?
    let email: String?
    let lastUpdated: Date

    // MARK: - Computed

    var hasPrimaryData: Bool { primaryWindowSeconds > 0 }
    var hasSecondaryData: Bool { secondaryWindowSeconds > 0 }
    var hasCredits: Bool { creditBalance != nil }

    var primaryFraction: Double { Double(primaryUsedPercent) / 100.0 }
    var secondaryFraction: Double { Double(secondaryUsedPercent) / 100.0 }

    var primaryResetLabel: String? {
        guard let date = primaryResetAt else { return nil }
        return Self.formatReset(from: date)
    }

    var secondaryResetLabel: String? {
        guard let date = secondaryResetAt else { return nil }
        return Self.formatReset(from: date)
    }

    var localMessagesUsed: Int? { approxLocalMessages?.first }
    var localMessagesLimit: Int? { approxLocalMessages?.last }
    var cloudMessagesUsed: Int? { approxCloudMessages?.first }
    var cloudMessagesLimit: Int? { approxCloudMessages?.last }

    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 600
    }

    // MARK: - Helpers

    static func formatReset(from date: Date) -> String? {
        let secs = date.timeIntervalSince(Date())
        guard secs > 60 else { return nil }
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    // MARK: - Parse from API JSON

    static func parse(from json: [String: Any], email: String? = nil) -> CodexUsageData? {
        guard let rateLimit = json["rate_limit"] as? [String: Any] else { return nil }

        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]
        let credits = json["credits"] as? [String: Any]

        // used_percent is Double (0-100), round to Int for display
        let primaryUsed = Int(primary?["used_percent"] as? Double ?? 0)
        let secondaryUsed = Int(secondary?["used_percent"] as? Double ?? 0)

        let now = Date()
        let primaryReset: Date? = {
            if let ts = primary?["reset_at"] as? Double {
                // Unix timestamp — but if it's >1 year from now, it's probably milliseconds
                let date = ts > 1e12 ? Date(timeIntervalSince1970: ts / 1000) : Date(timeIntervalSince1970: ts)
                return date
            }
            if let secs = primary?["reset_after_seconds"] as? Double {
                // Cap at 48h to guard against bad data (e.g. milliseconds)
                return now.addingTimeInterval(min(secs, 172800))
            }
            return nil
        }()
        let secondaryReset: Date? = {
            if let ts = secondary?["reset_at"] as? Double {
                let date = ts > 1e12 ? Date(timeIntervalSince1970: ts / 1000) : Date(timeIntervalSince1970: ts)
                return date
            }
            if let secs = secondary?["reset_after_seconds"] as? Double {
                return now.addingTimeInterval(min(secs, 604800))
            }
            return nil
        }()

        let balance: Double? = {
            if let val = credits?["balance"] as? Double { return val }
            if let str = credits?["balance"] as? String { return Double(str) }
            return nil
        }()

        return CodexUsageData(
            planType: json["plan_type"] as? String ?? "unknown",
            primaryUsedPercent: primaryUsed,
            primaryResetAt: primaryReset,
            primaryWindowSeconds: primary?["limit_window_seconds"] as? Int ?? 0,
            secondaryUsedPercent: secondaryUsed,
            secondaryResetAt: secondaryReset,
            secondaryWindowSeconds: secondary?["limit_window_seconds"] as? Int ?? 0,
            limitReached: rateLimit["limit_reached"] as? Bool ?? false,
            allowed: rateLimit["allowed"] as? Bool ?? true,
            creditBalance: balance,
            approxLocalMessages: credits?["approx_local_messages"] as? [Int],
            approxCloudMessages: credits?["approx_cloud_messages"] as? [Int],
            email: email,
            lastUpdated: Date()
        )
    }
}
