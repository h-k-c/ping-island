// UsageMonitorPlugin — monitors Claude and Codex usage via their APIs.
// Sends island/compact with current usage percentage and island/expanded with details.

import Foundation

enum UsageMonitorPlugin {

    private static let refreshInterval: TimeInterval = 300  // 5 minutes

    static func run() {
        // Send initialize response
        if let msg = readLine(), let id = msg["id"] {
            sendJSON(["jsonrpc": "2.0", "id": id,
                      "result": ["name": "用量监控", "ready": true]])
        }

        // Push initial empty compact
        sendCompact(claudePct: nil, codexPct: nil)

        // Start refresh loop in background
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            refresh()
        }
        RunLoop.main.add(timer, forMode: .default)

        // First refresh immediately
        DispatchQueue.global().async { refresh() }

        // Main loop for shutdown
        while let msg = readLine() {
            if (msg["method"] as? String) == "shutdown" {
                timer.invalidate()
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

        group.notify(queue: .main) {
            pushUpdates(claude: claudeData, codex: codexData)
        }
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
        // Pick the highest usage to show in compact
        let pct = [claudePct, codexPct].compactMap { $0 }.max()

        guard let pct else {
            sendJSON(["jsonrpc": "2.0", "method": "island/compact",
                      "params": ["position": "right", "content": NSNull()]])
            return
        }

        let tint: String
        let icon: String
        switch pct {
        case ..<0.6:  tint = "green";  icon = "chart.pie.fill"
        case ..<0.9:  tint = "yellow"; icon = "chart.pie.fill"
        default:      tint = "red";    icon = "exclamationmark.circle.fill"
        }

        let label = "\(Int(pct * 100))%"

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": icon],
                    "label": label,
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
                    "tint": tintString(c.sessionPercentage)
                ])
                sections.append([
                    "type": "progress",
                    "label": "5h 会话用量",
                    "value": c.sessionPercentage,
                    "tint": tintString(c.sessionPercentage)
                ])
            }
            if c.messagesLimit > 0 {
                sections.append([
                    "type": "progress",
                    "label": "7d 消息配额",
                    "value": c.weeklyPercentage,
                    "tint": tintString(c.weeklyPercentage)
                ])
            }
            if !c.weeklyResetText.isEmpty {
                sections.append([
                    "type": "text",
                    "content": c.weeklyResetText,
                    "style": "caption"
                ])
            }
        }

        // Divider between Claude and Codex
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
                    "tint": tintString(pct)
                ])
                sections.append([
                    "type": "progress",
                    "label": "Primary 用量",
                    "value": pct,
                    "tint": tintString(pct)
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

        // No data fallback
        if sections.isEmpty {
            sections.append([
                "type": "text",
                "content": "暂无用量数据，请确认已登录 Claude 和 Codex",
                "style": "caption"
            ])
        }

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func tintString(_ pct: Double) -> String {
        switch pct {
        case ..<0.6: return "green"
        case ..<0.9: return "yellow"
        default:     return "red"
        }
    }
}
