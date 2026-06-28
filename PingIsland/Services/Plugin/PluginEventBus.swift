import Foundation
import os.log

/// Forwards host-side events to plugin processes that subscribed in their manifest.
@MainActor
final class PluginEventBus {
    static let shared = PluginEventBus()
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PluginEventBus")

    init() {}

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
}
