// LocalServicesPlugin — read-only local service port monitor.
// Detects common loopback development/database services and renders compact/expanded IPP.

import Darwin
import Foundation

enum LocalServicesPlugin {
    private static let refreshInterval: TimeInterval = 15
    private static let connectTimeoutMilliseconds: Int32 = 120

    private enum ActionID {
        static let refresh = "refresh"
    }

    private static let services: [LocalServiceDefinition] = [
        LocalServiceDefinition(port: 3000, name: "Web", icon: "globe"),
        LocalServiceDefinition(port: 5173, name: "Vite", icon: "bolt.fill"),
        LocalServiceDefinition(port: 8000, name: "API", icon: "curlybraces"),
        LocalServiceDefinition(port: 8080, name: "Web", icon: "network"),
        LocalServiceDefinition(port: 5432, name: "Postgres", icon: "cylinder.split.1x2"),
        LocalServiceDefinition(port: 6379, name: "Redis", icon: "memorychip")
    ]

    static func run() {
        guard let initialMessage = readLine() else { return }
        let id = initialMessage["id"] ?? 1
        sendJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": ["name": "Local Services / 本地服务", "ready": true]
        ])

        sendLoadingState()

        let queue = DispatchQueue(label: "local-services-plugin", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var isRefreshing = false

        func refresh() {
            guard !isRefreshing else { return }
            isRefreshing = true
            let snapshot = LocalServiceScanner.scan(
                services: services,
                timeoutMilliseconds: connectTimeoutMilliseconds
            )
            isRefreshing = false
            pushUpdates(snapshot)
        }

        queue.async {
            refresh()
        }

        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler {
            refresh()
        }
        timer.resume()

        while let msg = readLine() {
            switch msg["method"] as? String {
            case "shutdown":
                timer.cancel()
                exit(0)
            case "action":
                let actionId = (msg["params"] as? [String: Any])?["actionId"] as? String
                if actionId == ActionID.refresh {
                    queue.async {
                        refresh()
                    }
                }
            default:
                break
            }
        }

        timer.cancel()
        exit(0)
    }

    private static func sendLoadingState() {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": "network"],
                    "label": "--",
                    "tint": "default"
                ]
            ]
        ])

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": [
                "sections": [
                    ["type": "text", "content": "本地服务", "style": "heading"],
                    ["type": "text", "content": "正在检测常见本地端口…", "style": "caption"]
                ]
            ]
        ])
    }

    private static func pushUpdates(_ snapshot: LocalServicesSnapshot) {
        sendCompact(snapshot)
        sendExpanded(snapshot)
    }

    private static func sendCompact(_ snapshot: LocalServicesSnapshot) {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "icon": ["type": "sf", "name": "network"],
                    "label": "\(snapshot.onlineCount)",
                    "tint": compactTint(onlineCount: snapshot.onlineCount)
                ]
            ]
        ])
    }

    private static func sendExpanded(_ snapshot: LocalServicesSnapshot) {
        let sections: [[String: Any]] = [
            ["type": "text", "content": "本地服务", "style": "heading"],
            [
                "type": "stat",
                "label": "Online",
                "value": "\(snapshot.onlineCount) / \(snapshot.results.count)",
                "icon": ["type": "sf", "name": "server.rack"],
                "tint": compactTint(onlineCount: snapshot.onlineCount)
            ],
            [
                "type": "list",
                "items": snapshot.results.map { result in
                    [
                        "icon": ["type": "sf", "name": result.definition.icon],
                        "label": "\(result.definition.port) \(result.definition.name)",
                        "value": result.isOnline ? "Online" : "Idle"
                    ]
                }
            ],
            ["type": "divider"],
            [
                "type": "text",
                "content": "更新于 \(timeString(snapshot.lastUpdated))",
                "style": "caption"
            ],
            ["type": "button", "label": "刷新", "actionId": ActionID.refresh]
        ]

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func compactTint(onlineCount: Int) -> String {
        switch onlineCount {
        case 0:
            return "default"
        case 1...2:
            return "yellow"
        default:
            return "green"
        }
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct LocalServiceDefinition {
    let port: UInt16
    let name: String
    let icon: String
}

private struct LocalServiceResult {
    let definition: LocalServiceDefinition
    let isOnline: Bool
}

private struct LocalServicesSnapshot {
    let results: [LocalServiceResult]
    let lastUpdated: Date

    var onlineCount: Int {
        results.filter(\.isOnline).count
    }
}

private enum LocalServiceScanner {
    static func scan(
        services: [LocalServiceDefinition],
        timeoutMilliseconds: Int32
    ) -> LocalServicesSnapshot {
        let results = services.map { service in
            LocalServiceResult(
                definition: service,
                isOnline: isPortOpen(service.port, timeoutMilliseconds: timeoutMilliseconds)
            )
        }
        return LocalServicesSnapshot(results: results, lastUpdated: Date())
    }

    private static func isPortOpen(_ port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        isIPv4PortOpen(port, timeoutMilliseconds: timeoutMilliseconds)
            || isIPv6PortOpen(port, timeoutMilliseconds: timeoutMilliseconds)
    }

    private static func isIPv4PortOpen(_ port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                isSocketAddressOpen(
                    family: AF_INET,
                    address: socketAddress,
                    length: socklen_t(MemoryLayout<sockaddr_in>.size),
                    timeoutMilliseconds: timeoutMilliseconds
                )
            }
        }
    }

    private static func isIPv6PortOpen(_ port: UInt16, timeoutMilliseconds: Int32) -> Bool {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
            return false
        }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                isSocketAddressOpen(
                    family: AF_INET6,
                    address: socketAddress,
                    length: socklen_t(MemoryLayout<sockaddr_in6>.size),
                    timeoutMilliseconds: timeoutMilliseconds
                )
            }
        }
    }

    private static func isSocketAddressOpen(
        family: Int32,
        address: UnsafePointer<sockaddr>,
        length: socklen_t,
        timeoutMilliseconds: Int32
    ) -> Bool {
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return false
        }

        let connectResult = connect(descriptor, address, length)
        if connectResult == 0 {
            return true
        }

        guard errno == EINPROGRESS else {
            return false
        }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, timeoutMilliseconds) > 0 else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &socketError) { errorPointer in
            getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                errorPointer,
                &socketErrorLength
            )
        }
        return optionResult == 0 && socketError == 0
    }
}
