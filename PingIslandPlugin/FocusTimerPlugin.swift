// FocusTimerPlugin — built-in focus timer / task progress island tool.
// Keeps all timer state in-process and communicates over Island Plugin Protocol.

import Foundation

enum FocusTimerPlugin {
    private static let tickInterval: TimeInterval = 1
    private static let focusSeconds = 25 * 60
    private static let breakSeconds = 5 * 60

    private enum ActionID {
        static let startPause = "startPause"
        static let reset = "reset"
        static let switchMode = "switchMode"
    }

    private enum Mode {
        case focus
        case shortBreak

        var title: String {
            switch self {
            case .focus: return "专注"
            case .shortBreak: return "休息"
            }
        }

        var duration: Int {
            switch self {
            case .focus: return focusSeconds
            case .shortBreak: return breakSeconds
            }
        }

        var next: Mode {
            switch self {
            case .focus: return .shortBreak
            case .shortBreak: return .focus
            }
        }
    }

    private struct TimerState {
        var mode: Mode = .focus
        var remaining: Int = focusSeconds
        var isRunning = false
        var hasStarted = false
        var isFinished = false
        var lastTickAt: Date?

        var elapsed: Int {
            max(0, mode.duration - remaining)
        }

        var progress: Double {
            guard mode.duration > 0 else { return 0 }
            return Double(elapsed) / Double(mode.duration)
        }

        var statusText: String {
            if isFinished { return "已完成" }
            if isRunning { return "进行中" }
            if hasStarted { return "已暂停" }
            return "待开始"
        }

        var tint: String {
            if isFinished { return "purple" }
            if isRunning { return "green" }
            if hasStarted { return "orange" }
            return "blue"
        }

        var compactLabel: String {
            if isFinished { return "00m" }
            if hasStarted && !isRunning { return "PAU" }
            return Self.minuteLabel(seconds: remaining)
        }

        var compactIconName: String {
            isRunning ? "timer" : "hourglass"
        }

        mutating func startPause(now: Date = Date()) {
            if isFinished {
                reset()
            }

            if isRunning {
                tick(now: now)
                isRunning = false
                lastTickAt = nil
            } else {
                isRunning = true
                hasStarted = true
                lastTickAt = now
            }
        }

        mutating func reset() {
            remaining = mode.duration
            isRunning = false
            hasStarted = false
            isFinished = false
            lastTickAt = nil
        }

        mutating func switchMode() {
            mode = mode.next
            reset()
        }

        mutating func tick(now: Date = Date()) {
            guard isRunning else { return }
            guard let lastTickAt else {
                self.lastTickAt = now
                return
            }

            let elapsedSeconds = Int(now.timeIntervalSince(lastTickAt))
            guard elapsedSeconds > 0 else { return }

            remaining = max(0, remaining - elapsedSeconds)
            self.lastTickAt = lastTickAt.addingTimeInterval(TimeInterval(elapsedSeconds))

            if remaining == 0 {
                isRunning = false
                hasStarted = true
                isFinished = true
                self.lastTickAt = nil
            }
        }

        static func minuteLabel(seconds: Int) -> String {
            let minutes = Int(ceil(Double(max(0, seconds)) / 60.0))
            return minutes < 10 ? String(format: "%02dm", minutes) : "\(minutes)m"
        }

        static func clockLabel(seconds: Int) -> String {
            let clamped = max(0, seconds)
            return String(format: "%02d:%02d", clamped / 60, clamped % 60)
        }
    }

    static func run() {
        guard let initialMessage = readLine() else { return }
        let id = initialMessage["id"] ?? 1
        sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": ["name": "Focus Timer / 专注计时", "ready": true]
        ])

        let queue = DispatchQueue(label: "focus-timer-plugin", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var state = TimerState()

        queue.async {
            pushUpdates(state)
        }

        timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
        timer.setEventHandler {
            state.tick()
            pushUpdates(state)
        }
        timer.resume()

        while let msg = readLine() {
            switch msg["method"] as? String {
            case "shutdown":
                timer.cancel()
                exit(0)
            case "action":
                let actionId = (msg["params"] as? [String: Any])?["actionId"] as? String
                queue.async {
                    handleAction(actionId, state: &state)
                    pushUpdates(state)
                }
            default:
                break
            }
        }

        timer.cancel()
        exit(0)
    }

    private static func handleAction(_ actionId: String?, state: inout TimerState) {
        switch actionId {
        case ActionID.startPause:
            state.startPause()
        case ActionID.reset:
            state.reset()
        case ActionID.switchMode:
            state.switchMode()
        default:
            break
        }
    }

    private static func pushUpdates(_ state: TimerState) {
        sendCompact(state)
        sendExpanded(state)
    }

    private static func sendCompact(_ state: TimerState) {
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

    private static func sendExpanded(_ state: TimerState) {
        let actionLabel: String
        if state.isFinished {
            actionLabel = "重新开始"
        } else if state.isRunning {
            actionLabel = "暂停"
        } else {
            actionLabel = "开始"
        }

        let sections: [[String: Any]] = [
            ["type": "text", "content": "专注计时", "style": "heading"],
            [
                "type": "stat",
                "label": "模式",
                "value": "\(state.mode.title) \(state.mode.duration / 60)m",
                "icon": ["type": "sf", "name": state.compactIconName],
                "tint": state.tint
            ],
            [
                "type": "stat",
                "label": "状态",
                "value": state.statusText,
                "icon": ["type": "sf", "name": state.isRunning ? "play.fill" : "pause.fill"],
                "tint": state.tint
            ],
            [
                "type": "progress",
                "label": "进度 \(TimerState.clockLabel(seconds: state.remaining))",
                "value": state.progress,
                "tint": state.tint
            ],
            [
                "type": "list",
                "items": [
                    ["label": "剩余", "value": TimerState.clockLabel(seconds: state.remaining)],
                    ["label": "已用", "value": TimerState.clockLabel(seconds: state.elapsed)],
                    ["label": "周期", "value": "25 / 5"]
                ]
            ],
            ["type": "divider"],
            ["type": "button", "label": actionLabel, "actionId": ActionID.startPause],
            ["type": "button", "label": "重置", "actionId": ActionID.reset],
            [
                "type": "button",
                "label": state.mode == .focus ? "切换到 5m" : "切换到 25m",
                "actionId": ActionID.switchMode
            ]
        ]

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }
}
