// TaskBoardPlugin - in-memory manual task progress island tool.
// Keeps a single task in process only and never scans or reads user files.

import Foundation

enum TaskBoardPlugin {
    private enum ActionID {
        static let start = "start"
        static let advance = "advance10"
        static let complete = "complete"
        static let reset = "reset"
        static let clear = "clear"
    }

    private static var state = TaskBoardState()

    static func run() {
        for msg in AnySequence({ AnyIterator { readLine() } }) {
            guard let method = msg["method"] as? String else { continue }

            switch method {
            case "initialize":
                let id = msg["id"] ?? 1
                sendJSON([
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": ["name": "Task Board", "ready": true]
                ])
                pushUpdates()
            case "action":
                handleAction(msg["params"] as? [String: Any] ?? [:])
            case "shutdown":
                exit(0)
            default:
                break
            }
        }
    }

    private static func handleAction(_ params: [String: Any]) {
        guard let actionId = params["actionId"] as? String else { return }

        switch actionId {
        case ActionID.start:
            state.start()
        case ActionID.advance:
            state.advance(by: 0.1)
        case ActionID.complete:
            state.complete()
        case ActionID.reset:
            state.reset()
        case ActionID.clear:
            state.clear()
        default:
            return
        }

        pushUpdates()
    }

    private static func pushUpdates() {
        sendCompact()
        sendExpanded()
    }

    private static func sendCompact() {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": state.compactIconName],
                    "label": state.compactLabel,
                    "tint": state.tint
                ]
            ]
        ])
    }

    private static func sendExpanded() {
        let sections: [[String: Any]] = [
            ["type": "text", "content": "任务进度", "style": "heading"],
            [
                "type": "stat",
                "label": "任务",
                "value": state.displayName,
                "icon": ["type": "sf", "name": state.compactIconName],
                "tint": state.tint
            ],
            [
                "type": "progress",
                "label": "进度",
                "value": state.progress,
                "tint": state.tint
            ],
            [
                "type": "stat",
                "label": "状态",
                "value": state.statusText,
                "icon": ["type": "sf", "name": state.statusIconName],
                "tint": state.tint
            ],
            ["type": "divider"],
            ["type": "button", "label": "开始", "actionId": ActionID.start],
            ["type": "button", "label": "推进 10%", "actionId": ActionID.advance],
            ["type": "button", "label": "完成", "actionId": ActionID.complete],
            ["type": "button", "label": "重置", "actionId": ActionID.reset],
            [
                "type": "button",
                "label": "清空",
                "actionId": ActionID.clear,
                "style": "destructive"
            ]
        ]

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }
}

private struct TaskBoardState {
    private static let defaultTaskName = "当前任务"

    private(set) var taskName: String?
    private(set) var progress: Double = 0
    private(set) var hasStarted = false

    var hasTask: Bool {
        taskName != nil
    }

    var isComplete: Bool {
        hasTask && progress >= 1
    }

    var displayName: String {
        taskName ?? Self.defaultTaskName
    }

    var compactLabel: String {
        guard hasTask else { return "OK" }
        return "\(Int((progress * 100).rounded()))%"
    }

    var compactIconName: String {
        if isComplete {
            return "checkmark.circle.fill"
        }
        if hasTask {
            return hasStarted ? "progress.indicator" : "flag.fill"
        }
        return "checkmark.circle"
    }

    var statusIconName: String {
        if isComplete {
            return "checkmark.circle.fill"
        }
        return hasStarted ? "progress.indicator" : "flag.fill"
    }

    var tint: String {
        if isComplete {
            return "green"
        }
        if hasTask {
            return hasStarted ? "blue" : "orange"
        }
        return "green"
    }

    var statusText: String {
        if isComplete {
            return "已完成"
        }
        if hasStarted {
            return "进行中"
        }
        if hasTask {
            return "未开始"
        }
        return "暂无任务"
    }

    mutating func start() {
        ensureTask()
        hasStarted = true
        if progress >= 1 {
            progress = 0
        }
    }

    mutating func advance(by delta: Double) {
        ensureTask()
        hasStarted = true
        progress = min(1, max(0, progress + delta))
    }

    mutating func complete() {
        ensureTask()
        hasStarted = true
        progress = 1
    }

    mutating func reset() {
        ensureTask()
        hasStarted = false
        progress = 0
    }

    mutating func clear() {
        taskName = nil
        hasStarted = false
        progress = 0
    }

    private mutating func ensureTask() {
        if taskName == nil {
            taskName = Self.defaultTaskName
        }
    }
}
