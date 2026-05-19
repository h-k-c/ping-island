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
case "com.wudanwu.pingisland.claude":
    ClaudeSessionPlugin.run()
case "com.wudanwu.pingisland.codex":
    CodexSessionPlugin.run()
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

        guard provider == "claude" else { return }

        let wasActive = activeSessions[sessionId] != nil

        if phase == "ended" {
            guard wasActive else { return }
            let sessionCwd = activeSessions.removeValue(forKey: sessionId) ?? cwd
            sendCompact()
            let project = sessionCwd.split(separator: "/").last.map(String.init) ?? "项目"
            sendJSON([
                "jsonrpc": "2.0", "method": "island/notify",
                "params": [
                    "icon": ["type": "sf", "name": "checkmark.circle.fill"],
                    "title": "会话已完成",
                    "subtitle": project,
                    "duration": 4.0
                ]
            ])
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
}

// MARK: - Codex Plugin

enum CodexSessionPlugin {
    private static var activeSessions: [String: String] = [:]  // sessionId → cwd

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

        guard provider == "codex" else { return }

        let wasActive = activeSessions[sessionId] != nil

        if phase == "ended" {
            guard wasActive else { return }
            let sessionCwd = activeSessions.removeValue(forKey: sessionId) ?? cwd
            sendCompact()
            let project = sessionCwd.split(separator: "/").last.map(String.init) ?? "项目"
            sendJSON([
                "jsonrpc": "2.0", "method": "island/notify",
                "params": [
                    "icon": ["type": "sf", "name": "checkmark.circle.fill"],
                    "title": "Codex 任务完成",
                    "subtitle": project,
                    "duration": 4.0
                ]
            ])
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
}
