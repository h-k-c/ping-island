// PingIslandPlugin — Swift CLI executable for built-in island plugins.
// Reads PING_ISLAND_PLUGIN_ID to determine which plugin logic to run.
// Communicates via JSON-RPC over stdin/stdout per Island Plugin Protocol.

import Foundation

// MARK: - JSON-RPC helpers

func sendJSON(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
    var line = data
    line.append(UInt8(ascii: "\n"))
    FileHandle.standardOutput.write(line)
}

func readLine() -> [String: Any]? {
    guard let line = Swift.readLine(strippingNewline: true),
          !line.isEmpty,
          let data = line.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
}

// MARK: - Plugin runner selection

let pluginId = ProcessInfo.processInfo.environment["PING_ISLAND_PLUGIN_ID"] ?? ""

switch pluginId {
case "com.auralink.claude", "com.wudanwu.pingisland.claude":
    ClaudeSessionPlugin.run()
case "com.auralink.codex", "com.wudanwu.pingisland.codex":
    CodexSessionPlugin.run()
case "com.auralink.usage", "com.wudanwu.pingisland.usage":
    UsageMonitorPlugin.run()
case "com.auralink.procmonitor", "com.wudanwu.pingisland.procmonitor":
    ProcMonitorPlugin.run()
case "com.auralink.clipboard":
    ClipboardShelfPlugin.run()
case "com.auralink.focusTimer":
    FocusTimerPlugin.run()
case "com.auralink.localServices":
    LocalServicesPlugin.run()
case "com.auralink.taskBoard":
    TaskBoardPlugin.run()
case "com.auralink.quickLauncher":
    QuickLauncherPlugin.run()
default:
    // Unknown plugin — respond to initialize and stay alive
    for msg in AnySequence({ AnyIterator { readLine() } }) {
        guard let method = msg["method"] as? String else { continue }
        if method == "initialize" {
            let id = msg["id"] ?? 1
            sendJSON(["jsonrpc": "2.0", "id": id, "result": ["name": pluginId, "ready": true]])
        } else if method == "shutdown" {
            exit(0)
        }
    }
}

// MARK: - Claude Plugin

enum ClaudeSessionPlugin {
    private static var activeSessions: [String: String] = [:]  // sessionId → cwd
    private static var notifiedAttentionKeys: Set<String> = []

    static func run() {
        for msg in AnySequence({ AnyIterator { readLine() } }) {
            guard let method = msg["method"] as? String else { continue }
            switch method {
            case "initialize":
                let id = msg["id"] ?? 1
                sendJSON(["jsonrpc": "2.0", "id": id,
                          "result": ["name": "Claude 会话", "ready": true]])
                sendCompact()
            case "hookEvent":
                handleHookEvent(msg["params"] as? [String: Any] ?? [:])
            case "shutdown":
                exit(0)
            default:
                break
            }
        }
    }

    private static func handleHookEvent(_ params: [String: Any]) {
        let sessionId = params["sessionId"] as? String ?? ""
        let phase     = params["phase"]     as? String ?? "idle"
        let provider  = params["provider"]  as? String ?? ""
        let cwd       = params["cwd"]       as? String ?? ""
        let message   = params["message"]   as? String

        guard provider == "claude" else { return }

        let wasActive = activeSessions[sessionId] != nil

        if phase == "ended" {
            guard wasActive else { return }
            activeSessions.removeValue(forKey: sessionId)
            notifiedAttentionKeys = notifiedAttentionKeys.filter { !$0.hasPrefix("\(sessionId):") }
            sendCompact()
            sendNotify(
                title: "Claude 会话完成",
                subtitle: cwd.isEmpty ? nil : cwd
            )
        } else if phase == "waiting_for_approval" || phase == "waiting_for_input" {
            activeSessions[sessionId] = cwd
            sendCompact()
            sendAttentionNotify(
                sessionId: sessionId,
                phase: phase,
                message: message,
                cwd: cwd
            )
        } else if phase == "processing" {
            activeSessions[sessionId] = cwd
            notifiedAttentionKeys = notifiedAttentionKeys.filter { !$0.hasPrefix("\(sessionId):") }
            sendCompact()
        } else if !wasActive {
            activeSessions[sessionId] = cwd
            sendCompact()
        }
    }

    private static func sendCompact() {
        let count = activeSessions.count
        let content: Any = count > 0 ? [
            "icon": ["type": "sf", "name": count == 1 ? "brain.head.profile" : "cpu"],
            "label": "\(count)",
            "tint": "default"
        ] as [String: Any] : NSNull()

        sendJSON([
            "jsonrpc": "2.0", "method": "island/compact",
            "params": ["position": "right", "content": content]
        ])
    }

    private static func sendNotify(title: String, subtitle: String?) {
        var content: [String: Any] = [
            "icon": ["type": "sf", "name": "brain.head.profile"],
            "title": title,
            "duration": 4.5
        ]
        if let subtitle {
            content["subtitle"] = subtitle
        }
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/notify",
            "params": ["content": content]
        ])
    }

    private static func sendAttentionNotify(sessionId: String, phase: String, message: String?, cwd: String) {
        let key = "\(sessionId):\(phase)"
        guard !notifiedAttentionKeys.contains(key) else { return }
        notifiedAttentionKeys.insert(key)
        sendNotify(
            title: phase == "waiting_for_approval" ? "Claude 等待审批" : "Claude 等待输入",
            subtitle: message ?? (cwd.isEmpty ? nil : cwd)
        )
    }
}

// MARK: - Codex Plugin

enum CodexSessionPlugin {
    private static var activeSessions: [String: String] = [:]  // sessionId → cwd
    private static var notifiedAttentionKeys: Set<String> = []

    static func run() {
        for msg in AnySequence({ AnyIterator { readLine() } }) {
            guard let method = msg["method"] as? String else { continue }
            switch method {
            case "initialize":
                let id = msg["id"] ?? 1
                sendJSON(["jsonrpc": "2.0", "id": id,
                          "result": ["name": "Codex 会话", "ready": true]])
                sendCompact()
            case "hookEvent":
                handleHookEvent(msg["params"] as? [String: Any] ?? [:])
            case "shutdown":
                exit(0)
            default:
                break
            }
        }
    }

    private static func handleHookEvent(_ params: [String: Any]) {
        let sessionId = params["sessionId"] as? String ?? ""
        let phase     = params["phase"]     as? String ?? "idle"
        let provider  = params["provider"]  as? String ?? ""
        let cwd       = params["cwd"]       as? String ?? ""
        let message   = params["message"]   as? String

        guard provider == "codex" else { return }

        let wasActive = activeSessions[sessionId] != nil

        if phase == "ended" {
            guard wasActive else { return }
            activeSessions.removeValue(forKey: sessionId)
            notifiedAttentionKeys = notifiedAttentionKeys.filter { !$0.hasPrefix("\(sessionId):") }
            sendCompact()
            sendNotify(
                title: "Codex 会话完成",
                subtitle: cwd.isEmpty ? nil : cwd
            )
        } else if phase == "waiting_for_approval" || phase == "waiting_for_input" {
            activeSessions[sessionId] = cwd
            sendCompact()
            sendAttentionNotify(
                sessionId: sessionId,
                phase: phase,
                message: message,
                cwd: cwd
            )
        } else if phase == "processing" {
            activeSessions[sessionId] = cwd
            notifiedAttentionKeys = notifiedAttentionKeys.filter { !$0.hasPrefix("\(sessionId):") }
            sendCompact()
        } else if !wasActive {
            activeSessions[sessionId] = cwd
            sendCompact()
        }
    }

    private static func sendCompact() {
        let count = activeSessions.count
        let content: Any = count > 0 ? [
            "icon": ["type": "sf", "name": count == 1 ? "terminal" : "terminal.fill"],
            "label": "\(count)",
            "tint": "green"
        ] as [String: Any] : NSNull()

        sendJSON([
            "jsonrpc": "2.0", "method": "island/compact",
            "params": ["position": "right", "content": content]
        ])
    }

    private static func sendNotify(title: String, subtitle: String?) {
        var content: [String: Any] = [
            "icon": ["type": "sf", "name": "terminal.fill"],
            "title": title,
            "duration": 4.5
        ]
        if let subtitle {
            content["subtitle"] = subtitle
        }
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/notify",
            "params": ["content": content]
        ])
    }

    private static func sendAttentionNotify(sessionId: String, phase: String, message: String?, cwd: String) {
        let key = "\(sessionId):\(phase)"
        guard !notifiedAttentionKeys.contains(key) else { return }
        notifiedAttentionKeys.insert(key)
        sendNotify(
            title: phase == "waiting_for_approval" ? "Codex 等待审批" : "Codex 等待输入",
            subtitle: message ?? (cwd.isEmpty ? nil : cwd)
        )
    }
}
