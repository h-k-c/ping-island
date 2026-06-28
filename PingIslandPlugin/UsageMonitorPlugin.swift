// UsageMonitorPlugin — built-in AI Monitor island tool.
// Monitors Claude and/or Codex usage via their APIs and renders compact/expanded IPP.
// Pass a Provider to restrict to one service; .all shows both (original behavior).

import Foundation

enum UsageMonitorPlugin {

    enum Provider {
        case claude, codex, all
        var showsClaude: Bool { self == .claude || self == .all }
        var showsCodex: Bool  { self == .codex  || self == .all }
    }

    private static var provider: Provider = .all
    private static var refreshInterval: TimeInterval = 300  // 5 minutes
    private static let refreshQueue = DispatchQueue(label: "ai-monitor-refresh", qos: .utility)
    private static var refreshTimer: DispatchSourceTimer?
    private static var isRefreshing = false
    private static var claudeSessionKeyFromConfig: String?  // avoids keychain read in subprocess

    private struct ProviderResult<T> {
        var data: T?
        var needsLogin = false
        var errorMessage: String?

        var isConnected: Bool { data != nil && !needsLogin && errorMessage == nil }
    }

    private struct RefreshSnapshot {
        var claude: ProviderResult<UsageData>
        var codex: ProviderResult<CodexUsageData>
        var todayTokens: Int
        var lastUpdated: Date
    }

    private final class Once {
        private let lock = NSLock()
        private var didRun = false

        func run(_ block: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !didRun else { return }
            didRun = true
            block()
        }
    }

    static func run(as p: Provider = .all) {
        provider = p
        guard let initialMessage = readLine() else { return }
        handleInitialize(initialMessage)

        sendLoadingState()
        scheduleRefresh(immediate: true)

        DispatchQueue.global(qos: .utility).async {
            while let msg = readLine() {
                handleMessage(msg)
            }
            exit(0)
        }

        dispatchMain()
    }

    private static func handleInitialize(_ msg: [String: Any]) {
        if let config = (msg["params"] as? [String: Any])?["config"] as? [String: Any] {
            applyConfig(config)
        }

        let id = msg["id"] ?? 1
        sendJSON(["jsonrpc": "2.0", "id": id,
                  "result": ["name": "AI Monitor", "ready": true]])
    }

    private static func handleMessage(_ msg: [String: Any]) {
        switch msg["method"] as? String {
        case "shutdown":
            refreshTimer?.cancel()
            exit(0)
        case "action":
            let actionId = (msg["params"] as? [String: Any])?["actionId"] as? String
            if actionId == "refresh" { scheduleRefresh(immediate: true) }
        case "config/update":
            if let params = msg["params"] as? [String: Any],
               let key = params["key"] as? String {
                applyConfig([key: params["value"] as Any])
                if key == "refreshInterval" || key == "claudeSessionKey" {
                    scheduleRefresh(immediate: true)
                }
            }
        default:
            break
        }
    }

    private static func applyConfig(_ config: [String: Any]) {
        if let interval = timeInterval(config["refreshInterval"]) {
            refreshInterval = min(max(interval, 60), 3600)
        }

        if config.keys.contains("claudeSessionKey") {
            let sessionKey = ((config["claudeSessionKey"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            claudeSessionKeyFromConfig = sessionKey.isEmpty ? nil : sessionKey
        }
    }

    private static func timeInterval(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func scheduleRefresh(immediate: Bool) {
        DispatchQueue.main.async {
            refreshTimer?.cancel()

            if immediate {
                refreshQueue.async { refresh() }
            }

            let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
            timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
            timer.setEventHandler { refresh() }
            refreshTimer = timer
            timer.resume()
        }
    }

    private static func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let group = DispatchGroup()
        var claude = ProviderResult<UsageData>()
        var codex = ProviderResult<CodexUsageData>()

        // Keep svc alive until group.wait() completes — URLSession callbacks use [weak self]
        var claudeSvc: ClaudeAPIService?
        if provider.showsClaude {
            let svc = ClaudeAPIService()
            claudeSvc = svc
            svc.sessionKeyOverride = claudeSessionKeyFromConfig  // bypass keychain in subprocess
            if svc.sessionKey == nil {
                claude.needsLogin = true
            } else {
                group.enter()
                let finish = Once()
                svc.onUsageUpdated = { data in
                    claude.data = data; claude.needsLogin = false; claude.errorMessage = nil
                    finish.run { group.leave() }
                }
                svc.onError = { msg in claude.errorMessage = msg; finish.run { group.leave() } }
                svc.onNeedsLogin = { claude.needsLogin = true; finish.run { group.leave() } }
                svc.refresh()
            }
        }

        if provider.showsCodex {
            group.enter()
            let finish = Once()
            let svc = CodexAPIService()
            svc.onUsageUpdated = { data in
                codex.data = data; codex.needsLogin = false; codex.errorMessage = nil
                finish.run { group.leave() }
            }
            svc.onError = { msg in codex.errorMessage = msg; finish.run { group.leave() } }
            svc.onNeedsLogin = { codex.needsLogin = true; finish.run { group.leave() } }
            svc.refresh()
        }

        _ = group.wait(timeout: .now() + 20)
        let snapshot = RefreshSnapshot(
            claude: claude,
            codex: codex,
            todayTokens: provider.showsClaude ? loadTodayTokens() : 0,
            lastUpdated: Date()
        )
        pushUpdates(snapshot)
    }

    private static func loadTodayTokens() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Claude/buddy-tokens.json"),
            home.appendingPathComponent(".claude/buddy-tokens.json"),
            home.appendingPathComponent(".config/claude/buddy-tokens.json"),
        ]

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return 0
        }

        let maxSize: UInt64 = 1_000_000
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > maxSize {
            return 0
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let today = json["tokens-today"] as? [String: Any],
              let tokens = today["tokens"] as? Int else { return 0 }
        return tokens
    }

    // MARK: - Push updates

    private static func pushUpdates(_ snapshot: RefreshSnapshot) {
        sendCompact(snapshot)
        sendExpanded(snapshot)
    }

    private static func sendLoadingState() {
        let loadingText: String
        switch provider {
        case .claude: loadingText = "正在获取 Claude 用量…"
        case .codex:  loadingText = "正在获取 Codex 用量…"
        case .all:    loadingText = "正在获取 Claude / Codex 用量…"
        }
        let icon = provider.showsClaude && !provider.showsCodex
            ? "brain.head.profile"
            : "chart.pie.fill"

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "content": ["icon": ["type": "sf", "name": icon], "label": "--", "tint": "default"]
            ]
        ])

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": [
                "sections": [
                    ["type": "text", "content": headingTitle(), "style": "heading"],
                    ["type": "text", "content": loadingText, "style": "caption"]
                ]
            ]
        ])
    }

    private static func headingTitle() -> String {
        switch provider {
        case .claude: return "Claude 用量"
        case .codex:  return "Codex 用量"
        case .all:    return "AI Monitor"
        }
    }

    // MARK: - island/compact

    private static func sendCompact(_ snapshot: RefreshSnapshot) {
        let content: [String: Any]

        switch provider {
        case .claude:
            content = claudeCompactContent(snapshot)
        case .codex:
            content = codexCompactContent(snapshot)
        case .all:
            // Combined: prefer Claude if connected, fall back to Codex
            let c = claudeCompactContent(snapshot)
            let cx = codexCompactContent(snapshot)
            content = snapshot.claude.isConnected ? c : cx
        }

        sendJSON(["jsonrpc": "2.0", "method": "island/compact",
                  "params": ["content": content]])
    }

    private static func claudeCompactContent(_ snapshot: RefreshSnapshot) -> [String: Any] {
        if let c = snapshot.claude.data, c.hasSessionData {
            return [
                "icon": ["type": "sf", "name": "brain.head.profile"],
                "label": "\(min(max(Int(c.sessionPercentage * 100), 0), 999))%",
                "tint": tint(c.sessionPercentage)
            ]
        } else if snapshot.claude.errorMessage != nil {
            return ["icon": ["type": "sf", "name": "exclamationmark.triangle.fill"], "tint": "red"]
        } else if snapshot.claude.needsLogin {
            return ["icon": ["type": "sf", "name": "person.crop.circle.badge.exclamationmark"], "tint": "orange"]
        }
        return ["icon": ["type": "sf", "name": "brain.head.profile"], "label": "--", "tint": "default"]
    }

    private static func codexCompactContent(_ snapshot: RefreshSnapshot) -> [String: Any] {
        if let cx = snapshot.codex.data, cx.hasPrimaryData {
            return [
                "icon": ["type": "sf", "name": "chart.pie.fill"],
                "label": "\(min(max(cx.primaryUsedPercent, 0), 999))%",
                "tint": tint(cx.primaryFraction)
            ]
        } else if snapshot.codex.errorMessage != nil {
            return ["icon": ["type": "sf", "name": "exclamationmark.triangle.fill"], "tint": "red"]
        } else if snapshot.codex.needsLogin {
            return ["icon": ["type": "sf", "name": "person.crop.circle.badge.exclamationmark"], "tint": "orange"]
        }
        return ["icon": ["type": "sf", "name": "chart.pie.fill"], "label": "--", "tint": "default"]
    }

    // MARK: - island/expanded

    private static func sendExpanded(_ snapshot: RefreshSnapshot) {
        var sections: [[String: Any]] = []

        sections.append(["type": "text", "content": headingTitle(), "style": "heading"])
        if provider.showsClaude {
            appendClaudeSections(to: &sections, result: snapshot.claude, todayTokens: snapshot.todayTokens)
        }
        if provider.showsClaude && provider.showsCodex {
            sections.append(["type": "divider"])
        }
        if provider.showsCodex {
            appendCodexSections(to: &sections, result: snapshot.codex)
        }
        sections.append(["type": "divider"])
        sections.append([
            "type": "text",
            "content": "更新于 \(timeString(snapshot.lastUpdated))",
            "style": "caption"
        ])
        sections.append([
            "type": "button",
            "label": "刷新",
            "actionId": "refresh"
        ])

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func appendClaudeSections(
        to sections: inout [[String: Any]],
        result: ProviderResult<UsageData>,
        todayTokens: Int
    ) {
        sections.append([
            "type": "stat",
            "label": "Claude 状态",
            "value": statusText(result, connectedLabel: result.data?.planType),
            "icon": ["type": "sf", "name": "brain.head.profile"],
            "tint": statusTint(result)
        ])

        if let c = result.data {
            appendProgress(&sections, label: "Claude 5小时", value: c.sessionPercentage, available: c.hasSessionData)
            appendProgress(&sections, label: "Claude 7日", value: c.weeklyPercentage, available: c.messagesLimit > 0)
            sections.append([
                "type": "stat",
                "label": "今日 Tokens",
                "value": formatTokens(todayTokens),
                "icon": ["type": "sf", "name": "number"],
                "tint": "blue"
            ])
            if let reset = c.sessionResetLabel {
                sections.append(["type": "text", "content": "Claude 5小时 \(reset)", "style": "caption"])
            }
            if let reset = c.weeklyResetLabel {
                sections.append(["type": "text", "content": "Claude 7日 \(reset)", "style": "caption"])
            }
        } else if let message = result.errorMessage {
            sections.append(["type": "text", "content": "Claude 错误：\(message)", "style": "caption"])
        } else if result.needsLogin {
            sections.append([
                "type": "text",
                "content": "Claude 未登录：请输入 Claude Session Key",
                "style": "caption"
            ])
        }
    }

    private static func appendCodexSections(
        to sections: inout [[String: Any]],
        result: ProviderResult<CodexUsageData>
    ) {
        sections.append([
            "type": "stat",
            "label": "Codex 状态",
            "value": statusText(result, connectedLabel: result.data?.planType),
            "icon": ["type": "sf", "name": "terminal.fill"],
            "tint": statusTint(result)
        ])

        if let cx = result.data {
            appendProgress(&sections, label: "Codex 5小时", value: cx.primaryFraction, available: cx.hasPrimaryData)
            appendProgress(&sections, label: "Codex 7日", value: cx.secondaryFraction, available: cx.hasSecondaryData)
            sections.append([
                "type": "stat",
                "label": "Credits",
                "value": cx.creditBalance.map { String(format: "$%.2f", $0) } ?? "--",
                "icon": ["type": "sf", "name": "dollarsign.circle"],
                "tint": "orange"
            ])
            if let reset = cx.primaryResetLabel {
                sections.append(["type": "text", "content": "Codex 5小时 \(reset) 后重置", "style": "caption"])
            }
            if let reset = cx.secondaryResetLabel {
                sections.append(["type": "text", "content": "Codex 7日 \(reset) 后重置", "style": "caption"])
            }
            if cx.limitReached || !cx.allowed {
                sections.append(["type": "text", "content": "Codex 当前已到达限额", "style": "caption"])
            }
        } else if let message = result.errorMessage {
            sections.append(["type": "text", "content": "Codex 错误：\(message)", "style": "caption"])
        } else if result.needsLogin {
            sections.append([
                "type": "text",
                "content": "Codex 未登录：请先在终端运行 codex 完成 ChatGPT 登录",
                "style": "caption"
            ])
        }
    }

    private static func appendProgress(
        _ sections: inout [[String: Any]],
        label: String,
        value: Double,
        available: Bool
    ) {
        guard available else {
            sections.append([
                "type": "stat",
                "label": label,
                "value": "--",
                "icon": ["type": "sf", "name": "chart.bar"],
                "tint": "default"
            ])
            return
        }

        sections.append([
            "type": "progress",
            "label": label,
            "value": min(max(value, 0), 1),
            "tint": tint(value)
        ])
    }

    private static func statusText<T>(_ result: ProviderResult<T>, connectedLabel: String?) -> String {
        if result.isConnected {
            let label = connectedLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return label.isEmpty || label.lowercased() == "unknown" ? "已连接" : label
        }
        if result.errorMessage != nil { return "错误" }
        if result.needsLogin { return "未登录" }
        return "加载中"
    }

    private static func statusTint<T>(_ result: ProviderResult<T>) -> String {
        if result.isConnected { return "green" }
        if result.errorMessage != nil { return "red" }
        if result.needsLogin { return "orange" }
        return "default"
    }

    private static func tint(_ pct: Double) -> String {
        switch pct {
        case ..<0.6: return "green"
        case ..<0.9: return "yellow"
        default:     return "red"
        }
    }

    private static func formatTokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
