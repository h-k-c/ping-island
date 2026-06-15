// ProcMonitorPlugin — read-only system process and memory monitor.
// Sends island/compact with memory pressure and island/expanded with top RSS groups.

import Darwin
import Foundation

enum ProcMonitorPlugin {
    private static let compactRefreshInterval: DispatchTimeInterval = .seconds(1)
    private static let detailsRefreshInterval: TimeInterval = 10
    private static let topProcessLimit = 8

    static func run() {
        if let msg = readLine(), let id = msg["id"] {
            sendJSON(["jsonrpc": "2.0", "id": id,
                      "result": ["name": "Proc Monitor", "ready": true]])
        }

        sendLoadingState()

        let refreshQueue = DispatchQueue(label: "proc-monitor-refresh", qos: .utility)
        let stop = DispatchSemaphore(value: 0)

        refreshQueue.async {
            var previousNetworkSample = SystemSampler.fetchNetworkBytes()
            var nextDetailsRefreshAt = Date.distantPast

            while true {
                let now = Date()
                let currentNetworkSample = SystemSampler.fetchNetworkBytes()
                let network = NetworkSpeedSnapshot(
                    previous: previousNetworkSample,
                    current: currentNetworkSample
                )
                previousNetworkSample = currentNetworkSample

                if now >= nextDetailsRefreshAt {
                    refreshDetails()
                    nextDetailsRefreshAt = now.addingTimeInterval(detailsRefreshInterval)
                }

                sendCompact(network: network)

                if stop.wait(timeout: .now() + compactRefreshInterval) == .success {
                    break
                }
            }
        }

        while let msg = readLine() {
            if (msg["method"] as? String) == "shutdown" {
                stop.signal()
                exit(0)
            }
        }
    }

    private static func sendLoadingState() {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "label": "--",
                    "tint": "blue"
                ]
            ]
        ])
    }

    private static func refreshDetails() {
        let memory = SystemSampler.fetchMemory()
        let groups = SystemSampler.fetchProcessGroups()

        sendExpanded(memory: memory, groups: groups)
    }

    private static func sendCompact(network: NetworkSpeedSnapshot) {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/compact",
            "params": [
                "position": "right",
                "content": [
                    "label": network.compactLabel,
                    "tint": network.tint
                ]
            ]
        ])
    }

    private static func sendExpanded(memory: MemorySnapshot, groups: [ProcessGroupSnapshot]) {
        let topGroups = Array(groups.prefix(topProcessLimit))
        var sections: [[String: Any]] = [
            [
                "type": "stat",
                "label": "内存占用",
                "value": "\(Int(memory.percent.rounded()))%",
                "icon": ["type": "sf", "name": "cpu.fill"],
                "tint": tint(forPercent: memory.percent)
            ],
            [
                "type": "progress",
                "label": "\(formatGB(memory.usedGB)) / \(formatGB(memory.totalGB))",
                "value": max(0, min(1, memory.percent / 100)),
                "tint": tint(forPercent: memory.percent)
            ],
            [
                "type": "stat",
                "label": "可回收余量",
                "value": formatGB(max(0, memory.totalGB - memory.usedGB)),
                "icon": ["type": "sf", "name": "gauge.with.dots.needle.bottom.50percent"]
            ],
            ["type": "divider"],
            ["type": "text", "content": "Top 进程", "style": "caption"]
        ]

        if topGroups.isEmpty {
            sections.append(["type": "text", "content": "暂无进程数据", "style": "caption"])
        } else {
            sections.append([
                "type": "list",
                "items": topGroups.map { group in
                    [
                        "label": group.displayName,
                        "value": formatBytes(group.totalResidentBytes)
                    ]
                }
            ])
        }

        sendJSON([
            "jsonrpc": "2.0",
            "method": "island/expanded",
            "params": ["sections": sections]
        ])
    }

    private static func tint(forPercent percent: Double) -> String {
        switch percent {
        case ..<60: return "green"
        case ..<85: return "yellow"
        default: return "red"
        }
    }

    private static func formatGB(_ gb: Double) -> String {
        String(format: "%.1f GB", gb)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

private struct MemorySnapshot {
    let usedGB: Double
    let totalGB: Double
    let percent: Double
}

private struct NetworkByteSample {
    let date: Date
    let received: UInt64
    let sent: UInt64
}

private struct NetworkSpeedSnapshot {
    let totalBytesPerSecond: Double

    init(previous: NetworkByteSample, current: NetworkByteSample) {
        let elapsed = current.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else {
            totalBytesPerSecond = 0
            return
        }

        let receivedDelta = current.received >= previous.received
            ? current.received - previous.received
            : 0
        let sentDelta = current.sent >= previous.sent
            ? current.sent - previous.sent
            : 0
        totalBytesPerSecond = Double(receivedDelta + sentDelta) / elapsed
    }

    var compactLabel: String {
        let mbps = max(0, totalBytesPerSecond) * 8 / 1_000_000
        switch mbps {
        case 100...:
            return String(format: "%.0fM", mbps)
        case 1..<100:
            return String(format: "%.1fM", mbps)
        default:
            let kbps = max(0, totalBytesPerSecond) * 8 / 1_000
            return String(format: "%.0fK", kbps)
        }
    }

    var tint: String {
        let mbps = max(0, totalBytesPerSecond) * 8 / 1_000_000
        switch mbps {
        case 50...: return "orange"
        case 10..<50: return "green"
        default: return "blue"
        }
    }
}

private struct ProcessSnapshot {
    let pid: Int
    let parentPid: Int
    let name: String
    let residentBytes: Int64
}

private struct ProcessGroupSnapshot {
    let parent: ProcessSnapshot
    let children: [ProcessSnapshot]

    var totalResidentBytes: Int64 {
        parent.residentBytes + children.reduce(Int64(0)) { $0 + $1.residentBytes }
    }

    var displayName: String {
        if children.isEmpty {
            return parent.name
        }
        return "\(parent.name) +\(children.count)"
    }
}

private enum SystemSampler {
    static func fetchMemory() -> MemorySnapshot {
        var totalBytes: Int64 = 0
        var totalSize = MemoryLayout<Int64>.size
        sysctlbyname("hw.memsize", &totalBytes, &totalSize, nil, 0)

        let pageSize = Int64(vm_page_size)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                _ = host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let usedBytes = (Int64(stats.active_count)
            + Int64(stats.wire_count)
            + Int64(stats.compressor_page_count)) * pageSize
        let gb = 1_073_741_824.0
        let totalGB = Double(max(totalBytes, 1)) / gb
        let usedGB = Double(max(usedBytes, 0)) / gb
        return MemorySnapshot(
            usedGB: usedGB,
            totalGB: totalGB,
            percent: min(100, max(0, Double(usedBytes) / Double(max(totalBytes, 1)) * 100))
        )
    }

    static func fetchProcessGroups() -> [ProcessGroupSnapshot] {
        fetchProcesses()
            .sorted { $0.residentBytes > $1.residentBytes }
            .map { ProcessGroupSnapshot(parent: $0, children: []) }
    }

    static func fetchNetworkBytes() -> NetworkByteSample {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return NetworkByteSample(date: Date(), received: 0, sent: 0)
        }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let name = String(cString: interface.pointee.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            let flags = interface.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let dataPointer = interface.pointee.ifa_data else {
                continue
            }

            let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
            received &+= UInt64(data.ifi_ibytes)
            sent &+= UInt64(data.ifi_obytes)
        }

        return NetworkByteSample(date: Date(), received: received, sent: sent)
    }

    private static func fetchProcesses() -> [ProcessSnapshot] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,rss=,comm="]

        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        return raw.components(separatedBy: "\n").compactMap(parseProcessLine)
    }

    private static func parseProcessLine(_ line: String) -> ProcessSnapshot? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 4,
              let pid = Int(parts[0]),
              let parentPid = Int(parts[1]),
              let rssKB = Int64(parts[2])
        else { return nil }

        let rawPath = String(parts[3])
        let name = rawPath.split(separator: "/").last.map(String.init) ?? rawPath
        let displayName = name.isEmpty ? "proc-\(pid)" : String(name.prefix(40))
        return ProcessSnapshot(
            pid: pid,
            parentPid: parentPid,
            name: displayName,
            residentBytes: rssKB * 1024
        )
    }
}
