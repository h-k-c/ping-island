// QuickLauncherPlugin - safe built-in shortcut launcher island tool.
// Exposes callback action IDs for the host to wire; never executes shell commands.

import Foundation

enum QuickLauncherPlugin {
    private enum ActionID {
        static let openPluginsFolder = "quickLauncher.openPluginsFolder"
        static let openPluginSettings = "quickLauncher.openPluginSettings"
        static let openAppSettings = "quickLauncher.openAppSettings"
        static let refreshPlugins = "quickLauncher.refreshPlugins"
        static let copyPluginsPath = "quickLauncher.copyPluginsPath"
    }

    private struct LauncherAction {
        let label: String
        let actionId: String
        let actionValue: String?
        let actionType: String?
        let acknowledgement: String
    }

    private static var lastStatus: String?

    private static var homeDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static var applicationSupportPath: String {
        "\(homeDirectoryPath)/Library/Application Support/Auralink"
    }

    private static var pluginsPath: String {
        "\(applicationSupportPath)/Plugins"
    }

    private static var pluginLogsPath: String {
        "\(homeDirectoryPath)/.ping-island-debug/plugins"
    }

    private static var actions: [LauncherAction] {
        [
            LauncherAction(
                label: "打开插件文件夹",
                actionId: ActionID.openPluginsFolder,
                actionValue: fileURLString(forPath: pluginsPath),
                actionType: "openURL",
                acknowledgement: "已请求打开插件文件夹"
            ),
            LauncherAction(
                label: "插件设置",
                actionId: ActionID.openPluginSettings,
                actionValue: "pingisland://settings/plugins",
                actionType: nil,
                acknowledgement: "已请求打开插件设置"
            ),
            LauncherAction(
                label: "应用设置",
                actionId: ActionID.openAppSettings,
                actionValue: "pingisland://settings/general",
                actionType: nil,
                acknowledgement: "已请求打开应用设置"
            ),
            LauncherAction(
                label: "刷新插件",
                actionId: ActionID.refreshPlugins,
                actionValue: "plugins.reload",
                actionType: nil,
                acknowledgement: "已请求刷新插件"
            ),
            LauncherAction(
                label: "复制插件路径",
                actionId: ActionID.copyPluginsPath,
                actionValue: pluginsPath,
                actionType: "writeClipboard",
                acknowledgement: "已请求复制插件路径"
            )
        ]
    }

    static func run() {
        guard let initialMessage = readLine() else { return }
        handleInitialize(initialMessage)
        pushUpdates()

        while let msg = readLine() {
            switch msg["method"] as? String {
            case "shutdown":
                exit(0)
            case "action":
                let params = msg["params"] as? [String: Any]
                handleAction(
                    actionId: params?["actionId"] as? String,
                    value: params?["value"]
                )
            default:
                break
            }
        }

        exit(0)
    }

    private static func handleInitialize(_ msg: [String: Any]) {
        let id = msg["id"] ?? 1
        sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": ["name": "Quick Launcher / 快捷入口", "ready": true]
        ])
    }

    private static func handleAction(actionId: String?, value: Any?) {
        guard let actionId else { return }
        let action = actions.first { $0.actionId == actionId }
        let acknowledgement = action?.acknowledgement ?? "已收到快捷入口动作"
        let valueText = (value as? String).flatMap { $0.isEmpty ? nil : $0 }

        lastStatus = valueText.map { "\(acknowledgement): \($0)" } ?? acknowledgement
        sendNotify(title: acknowledgement, subtitle: actionId)
        sendExpanded()
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
                    "icon": ["type": "sf", "name": "command.square.fill"],
                    "label": "GO",
                    "tint": "purple"
                ]
            ]
        ])
    }

    private static func sendExpanded() {
        var sections: [[String: Any]] = [
            ["type": "text", "content": "快捷入口", "style": "heading"],
            [
                "type": "text",
                "content": "安全入口，不执行 shell；文件夹和复制动作可直接执行，设置/刷新等待宿主接线。",
                "style": "caption"
            ],
            [
                "type": "list",
                "items": [
                    [
                        "icon": ["type": "sf", "name": "folder"],
                        "label": "Plugins",
                        "value": pluginsPath
                    ],
                    [
                        "icon": ["type": "sf", "name": "gearshape"],
                        "label": "App Support",
                        "value": applicationSupportPath
                    ],
                    [
                        "icon": ["type": "sf", "name": "doc.text.magnifyingglass"],
                        "label": "Plugin Logs",
                        "value": pluginLogsPath
                    ]
                ]
            ],
            ["type": "divider"]
        ]

        if let lastStatus {
            sections.append([
                "type": "text",
                "content": "\(lastStatus) · \(timeString(Date()))",
                "style": "caption"
            ])
        }

        sections.append(contentsOf: actions.map { action in
            var section: [String: Any] = [
                "type": "button",
                "label": action.label,
                "actionId": action.actionId,
                "actionType": action.actionType ?? "callback"
            ]
            if let actionValue = action.actionValue {
                section["actionValue"] = actionValue
            }
            return section
        })

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func sendNotify(title: String, subtitle: String?) {
        var content: [String: Any] = [
            "icon": ["type": "sf", "name": "command.square.fill"],
            "title": title,
            "duration": 2.5,
            "actionLabel": "查看",
            "actionId": ActionID.openPluginSettings
        ]
        if let subtitle {
            content["subtitle"] = subtitle
        }

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/notify",
            "params": content
        ])
    }

    private static func fileURLString(forPath path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).absoluteString
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
