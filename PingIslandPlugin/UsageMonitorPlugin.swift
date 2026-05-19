// UsageMonitorPlugin — monitors Claude and Codex usage via their APIs.
// Requires claudeSessionKey in Keychain (set via ClaudeMonitor app or manually).
// Sends island/compact with usage percentage, island/expanded with details.

import Foundation

enum UsageMonitorPlugin {

    private static let refreshInterval: TimeInterval = 300  // 5 minutes

    static func run() {
        // Initialize
        if let msg = readLine(), let id = msg["id"] {
            sendJSON(["jsonrpc": "2.0", "id": id,
                      "result": ["name": "用量监控", "ready": true]])
        }

        // Push initial empty compact while data loads
        sendCompact(claudePct: nil, codexPct: nil)

        // Refresh runs on a background thread so it doesn't block stdin reading
        let refreshQueue = DispatchQueue(label: "usage-refresh", qos: .utility)

        func scheduleRefresh() {
            refreshQueue.async {
                refresh()
                // Schedule next refresh after interval
                Thread.sleep(forTimeInterval: refreshInterval)
                scheduleRefresh()
            }
        }

        // First refresh immediately
        scheduleRefresh()

        // Main thread reads stdin for shutdown signal
        while let msg = readLine() {
            if (msg["method"] as? String) == "shutdown" {
                exit(0)
            }
        }
    }

    // MARK: - Refresh

    private static func refresh() {
        let group = DispatchGroup()
        var claudeData: UsageData?
        var codexData: CodexUsageData?

        // Fetch Claude usage
        group.enter()
        let claudeService = ClaudeAPIService()
        claudeService.onUsageUpdated = { data in
            claudeData = data
            group.leave()
        }
        claudeService.onError = { _ in group.leave() }
        claudeService.onNeedsLogin = { group.leave() }
        claudeService.refresh()

        // Fetch Codex usage
        group.enter()
        let codexService = CodexAPIService()
        codexService.onUsageUpdated = { data in
            codexData = data
            group.leave()
        }
        codexService.onError = { _ in group.leave() }
        codexService.onNeedsLogin = { group.leave() }
        codexService.refresh()

        group.wait()  // blocking wait on background thread — OK
        pushUpdates(claude: claudeData, codex: codexData)
    }

    // MARK: - Push updates

    private static func pushUpdates(claude: UsageData?, codex: CodexUsageData?) {
        let claudePct = claude?.sessionPercentage
        let codexPct: Double? = codex.map { $0.primaryFraction }

        sendCompact(claudePct: claudePct, codexPct: codexPct)
        sendExpanded(claude: claude, codex: codex)
    }

    // MARK: - island/compact

    private static func sendCompact(claudePct: Double?, codexPct: Double?) {
        let pct = [claudePct, codexPct].compactMap { $0 }.max()

        guard let pct else {
            // No auth / no data — don't occupy the slot
            sendJSON(["jsonrpc": "2.0", "method": "island/compact",
                      "params": ["position": "right", "content": NSNull()]])
            return
        }

        let (tint, icon): (String, String) = {
            switch pct {
            case ..<0.6: return ("green",  "chart.pie.fill")
            case ..<0.9: return ("yellow", "chart.pie.fill")
            default:     return ("red",    "exclamationmark.circle.fill")
            }
        }()

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": icon],
                    "label": "\(Int(pct * 100))%",
                    "tint": tint
                ]
            ]
        ])
    }

    // MARK: - island/expanded

    private static func sendExpanded(claude: UsageData?, codex: CodexUsageData?) {
        var sections: [[String: Any]] = []

        // Claude section
        if let c = claude {
            if c.hasSessionData {
                sections.append([
                    "type": "stat",
                    "label": "Claude 会话",
                    "value": "\(Int(c.sessionPercentage * 100))%",
                    "icon": ["type": "sf", "name": "brain.head.profile"],
                    "tint": tint(c.sessionPercentage)
                ])
                sections.append([
                    "type": "progress",
                    "label": "5h 会话用量",
                    "value": c.sessionPercentage,
                    "tint": tint(c.sessionPercentage)
                ])
            }
            if c.messagesLimit > 0 {
                sections.append([
                    "type": "progress",
                    "label": "7d 消息配额",
                    "value": c.weeklyPercentage,
                    "tint": tint(c.weeklyPercentage)
                ])
            }
            if !c.weeklyResetText.isEmpty {
                sections.append(["type": "text", "content": c.weeklyResetText, "style": "caption"])
            }
            if !c.hasSessionData && c.messagesLimit == 0 {
                sections.append([
                    "type": "text",
                    "content": "Claude 未登录 — 请在 ClaudeMonitor 中登录后重试",
                    "style": "caption"
                ])
            }
        } else {
            sections.append([
                "type": "text",
                "content": "Claude 数据加载中…",
                "style": "caption"
            ])
        }

        // Divider
        if claude != nil && codex != nil {
            sections.append(["type": "divider"])
        }

        // Codex section
        if let cx = codex {
            if cx.hasPrimaryData {
                let pct = cx.primaryFraction
                sections.append([
                    "type": "stat",
                    "label": "Codex 会话",
                    "value": "\(cx.primaryUsedPercent)%",
                    "icon": ["type": "sf", "name": "terminal.fill"],
                    "tint": tint(pct)
                ])
                sections.append([
                    "type": "progress",
                    "label": "Primary 用量",
                    "value": pct,
                    "tint": tint(pct)
                ])
                if let reset = cx.primaryResetLabel {
                    sections.append(["type": "text", "content": "\(reset) 后重置", "style": "caption"])
                }
            }
            if let balance = cx.creditBalance, balance > 0 {
                sections.append([
                    "type": "stat",
                    "label": "Credits 余额",
                    "value": String(format: "$%.2f", balance),
                    "icon": ["type": "sf", "name": "dollarsign.circle"]
                ])
            }
        }

        if sections.isEmpty {
            sections.append([
                "type": "text",
                "content": "暂无用量数据",
                "style": "caption"
            ])
        }

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func tint(_ pct: Double) -> String {
        switch pct {
        case ..<0.6: return "green"
        case ..<0.9: return "yellow"
        default:     return "red"
        }
    }
}
