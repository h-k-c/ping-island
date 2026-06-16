import Foundation
import os.log

/// Forwards host-side events to plugin processes that subscribed in their manifest.
@MainActor
final class PluginEventBus {
    static let shared = PluginEventBus()
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PluginEventBus")

    init() {}

    /// Dispatch a HookEvent to all processes subscribed to "hookEvent".
    func dispatch(hookEvent event: HookEvent) {
        let json = hookEventJSON(
            sessionId: event.sessionId,
            event: event.event,
            status: event.status,
            provider: event.provider.rawValue,
            cwd: event.cwd,
            message: event.message,
            phase: resolvedPhase(from: event)
        )
        dispatchHookEventJSON(json)
    }

    /// Dispatch a normalized app-server session event to plugins that subscribe to "hookEvent".
    func dispatchSessionEvent(
        sessionId: String,
        event: String,
        status: String,
        provider: SessionProvider,
        cwd: String?,
        message: String?,
        phase: String
    ) {
        let json = hookEventJSON(
            sessionId: sessionId,
            event: event,
            status: status,
            provider: provider.rawValue,
            cwd: cwd ?? "",
            message: message,
            phase: phase
        )
        dispatchHookEventJSON(json)
    }

    private func dispatchHookEventJSON(_ json: [String: Any]) {
        let subscribed = PluginHost.shared.subscribedProcesses(for: "hookEvent")
        for process in subscribed {
            Task {
                await process.send(json)
            }
        }
    }

    /// Build the JSON-RPC notification dict. Exposed internal for testing.
    func hookEventJSON(
        sessionId: String,
        event: String,
        status: String,
        provider: String,
        cwd: String,
        message: String?,
        phase: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "sessionId": sessionId,
            "event": event,
            "status": status,
            "provider": provider,
            "cwd": cwd,
            "phase": phase
        ]
        if let message { params["message"] = message }
        return ["jsonrpc": "2.0", "method": "hookEvent", "params": params]
    }

    /// Forward a plugin-emitted event to all other plugins subscribed to it.
    /// Event name format: "pluginEvent.<sourcePluginId>.<eventName>"
    func dispatchPluginEvent(name: String, payload: [String: Any]) {
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "event",
            "params": ["type": name, "payload": payload]
        ]
        for process in PluginHost.shared.subscribedProcesses(for: name) {
            Task { await process.send(json) }
        }
    }

    private func resolvedPhase(from event: HookEvent) -> String {
        switch event.status {
        case "waiting_for_approval", "waiting_for_input", "processing", "ended":
            return event.status
        default:
            break
        }

        switch event.event {
        case "Stop", "SessionEnd", "SubagentStop":
            return "ended"
        case "PreToolUse", "PostToolUse":
            return "processing"
        default:
            return "idle"
        }
    }
}
