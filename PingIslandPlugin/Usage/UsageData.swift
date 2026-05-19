import Foundation

/// Claude.ai API usage data model
struct UsageData {
    var planType: String
    var sessionUsed: Int = 0
    var sessionLimit: Int = 0
    var messagesUsed: Int = 0
    var messagesLimit: Int = 0
    var resetDate: Date?
    var weeklyResetDate: Date?
    var weeklyResetText: String = ""
    var sonnetPercentage: Double = 0
    var sonnetResetDate: Date?
    var claudeDesignPercentage: Double = 0
    var claudeDesignResetDate: Date?
    var extraUsageSpent: Double = 0
    var extraUsageLimit: Double = 0
    var routineRunsUsed: Int = 0
    var routineRunsLimit: Int = 0
    var lastUpdated: Date

    // Burn rate history — rolling window of (timestamp, sessionPercentage), max 10 points
    var usageHistory: [(date: Date, pct: Double)] = []

    // MARK: - Computed

    var hasSessionData: Bool { sessionLimit > 0 }

    var sessionPercentage: Double {
        guard sessionLimit > 0 else { return 0 }
        return min(1.0, Double(sessionUsed) / Double(sessionLimit))
    }

    var weeklyPercentage: Double {
        guard messagesLimit > 0 else { return 0 }
        return min(1.0, Double(messagesUsed) / Double(messagesLimit))
    }

    var hasSonnetData: Bool { sonnetPercentage > 0 }
    var hasClaudeDesignData: Bool { claudeDesignPercentage > 0 }
    var hasExtraUsage: Bool { extraUsageLimit > 0 }
    var hasRoutineData: Bool { routineRunsLimit > 0 }

    var routineRunsPercentage: Double {
        guard routineRunsLimit > 0 else { return 0 }
        return min(1.0, Double(routineRunsUsed) / Double(routineRunsLimit))
    }

    var routineRunsRemaining: Int { max(0, routineRunsLimit - routineRunsUsed) }

    var extraUsagePercentage: Double {
        guard extraUsageLimit > 0 else { return 0 }
        return min(1.0, extraUsageSpent / extraUsageLimit)
    }

    // MARK: - Burn rate

    var burnRatePerMinute: Double? {
        guard usageHistory.count >= 2 else { return nil }
        let oldest = usageHistory.first!
        let newest = usageHistory.last!
        let minutes = newest.date.timeIntervalSince(oldest.date) / 60.0
        guard minutes >= 5 else { return nil }
        let consumed = newest.pct - oldest.pct
        guard consumed > 0 else { return nil }
        return consumed / minutes
    }

    var estimatedMinutesRemaining: Double? {
        guard let rate = burnRatePerMinute, rate > 0 else { return nil }
        let remaining = 1.0 - sessionPercentage
        let estimated = remaining / rate
        if let reset = resetDate {
            let actual = reset.timeIntervalSince(Date()) / 60.0
            guard actual > 0 else { return nil }
            return min(estimated, actual)
        }
        return estimated
    }

    var burnRateLabel: String? {
        guard let mins = estimatedMinutesRemaining else { return nil }
        if mins < 60 { return "~\(Int(mins))min" }
        let h = Int(mins / 60)
        let m = Int(mins.truncatingRemainder(dividingBy: 60))
        return m > 0 ? "~\(h)h\(m)m" : "~\(h)h"
    }

    // MARK: - Reset labels

    var sessionResetLabel: String? {
        guard let date = resetDate else { return nil }
        let secs = date.timeIntervalSince(Date())
        guard secs > 60 else { return nil }
        let totalMins = Int(secs / 60)
        let h = totalMins / 60
        let m = totalMins % 60
        if h > 0 { return "重置于 \(h)h\(m)m" }
        return "重置于 \(m)m"
    }

    var weeklyResetLabel: String? {
        if !weeklyResetText.isEmpty { return "重置于 \(weeklyResetText)" }
        guard let date = weeklyResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "重置于 \(f.string(from: date))"
    }

    var sonnetResetLabel: String? {
        guard let date = sonnetResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "重置于 \(f.string(from: date))"
    }

    var claudeDesignResetLabel: String? {
        guard let date = claudeDesignResetDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return "重置于 \(f.string(from: date))"
    }

    var lastUpdatedFormatted: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: lastUpdated)
    }

    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 600
    }

    // MARK: - Menu bar label

    var menuBarLabel: String {
        let sessionStr: String? = hasSessionData ? "\(Int(sessionPercentage * 100))%" : nil
        let wPct = messagesLimit > 0 ? "\(Int(weeklyPercentage * 100))%" : nil
        switch (sessionStr, wPct) {
        case let (s?, w?): return "\(s) | \(w)"
        case let (s?, nil): return s
        case let (nil, w?): return w
        default: return ""
        }
    }
}
