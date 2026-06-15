import Foundation
import AppKit
import Combine
import Darwin
import SwiftUI

enum IslandExpandedSurface: Equatable {
    case docked
    case floating
}

enum IslandExpandedTrigger: Equatable {
    case click
    case hover
    case notification
    case pinnedList
}

enum IslandExpandedRoute: Equatable {
    case sessionList
    case hoverDashboard
    case attentionNotification(SessionState)
    case completionNotification(SessionCompletionNotification)
    case pluginNotification(PluginNotifyUpdate)
    case chat(SessionState)
    case plugin(pluginId: String)
}

enum IslandExpandedRouteResolver {
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType,
        sessions: [SessionState],
        activeCompletionNotification: SessionCompletionNotification? = nil,
        activePluginNotification: PluginNotifyUpdate? = nil
    ) -> IslandExpandedRoute {
        switch trigger {
        case .notification:
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
        case .click, .hover, .pinnedList:
            break
        }

        if case .plugin(let id) = contentType {
            return .plugin(pluginId: id)
        }

        if case .chat(let session) = contentType {
            return .chat(session)
        }

        switch (surface, trigger) {
        case (.docked, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
            return .sessionList
        case (.docked, .hover), (.floating, .hover):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .hoverDashboard
        case (.floating, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
            return .hoverDashboard
        case (_, .click):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .sessionList
        case (_, .pinnedList):
            return .sessionList
        }
    }

    nonisolated static func orderedSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    nonisolated static func activePreviewSessions(from sessions: [SessionState]) -> [SessionState] {
        orderedSessions(from: sessions).filter(\.phase.isActive)
    }

    nonisolated static func highestPriorityAttentionSession(from sessions: [SessionState]) -> SessionState? {
        orderedSessions(from: sessions)
            .filter { $0.needsApprovalResponse || $0.needsQuestionResponse }
            .sorted(by: attentionSort)
            .first
    }

    nonisolated private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}

struct PluginExpandedPanelView: View {
    private static let procMonitorPluginId = "com.wudanwu.pingisland.procmonitor"

    let pluginId: String
    @ObservedObject private var arbiter = PluginSlotArbiter.shared
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        Group {
            if pluginId == Self.procMonitorPluginId {
                ProcMonitorIslandPanelView()
            } else {
                genericPanel
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
        .onAppear { arbiter.currentlyDisplayedExpandedPluginId = pluginId }
        .onDisappear {
            if arbiter.currentlyDisplayedExpandedPluginId == pluginId {
                arbiter.currentlyDisplayedExpandedPluginId = nil
            }
        }
    }

    private var genericPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let sections = arbiter.expandedContent[pluginId] {
                IslandPluginRenderer.expandedView(sections: sections, pluginId: pluginId)
            } else {
                loadingDetail
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            pluginIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin?.manifest.name ?? "插件详情")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                if let description = plugin?.manifest.description {
                    Text(description)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var loadingDetail: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.75))
            Text("等待插件详情…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var pluginIcon: some View {
        if let plugin,
           let iconPath = plugin.manifest.iconPath,
           let image = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if let icon = plugin?.manifest.icon {
            Image(systemName: icon.sfSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(hex: icon.color) ?? .white.opacity(0.88))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var plugin: InstalledPlugin? {
        registry.installedPlugins.first { $0.id == pluginId }
    }
}

private struct ProcMonitorIslandPanelView: View {
    @StateObject private var monitor = ProcMonitorIslandModel()
    @State private var showMemory = true
    @State private var showSystem = false
    @State private var expandedPids: Set<Int> = []

    private let rowLimit = 10
    private let cardRadius: CGFloat = 14

    private var groups: [ProcMonitorIslandGroup] {
        monitor.groups(showSystem: showSystem, sortByMemory: showMemory)
    }

    private var visibleGroups: [ProcMonitorIslandGroup] {
        Array(groups.prefix(rowLimit))
    }

    private var totalCPU: Double {
        groups.reduce(0) { $0 + $1.totalCPU }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            columnHeader
            Divider().opacity(0.08)
            processRows
            footer
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 14)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.82))
                .frame(width: 32, height: 30, alignment: .leading)

            metricButton(
                title: "内存",
                value: String(format: "%.1f/%.0fG", monitor.memoryUsedGB, monitor.memoryTotalGB),
                active: showMemory,
                accent: ProcMonitorIslandStyle.amber
            ) {
                showMemory = true
            }

            Rectangle()
                .fill(ProcMonitorIslandStyle.hairline)
                .frame(width: 1, height: 30)

            metricButton(
                title: "CPU",
                value: String(format: "%.1f%%", totalCPU),
                active: !showMemory,
                accent: ProcMonitorIslandStyle.green
            ) {
                showMemory = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("应用进程")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.42))
                .padding(.leading, 42)
            Spacer()
            Text(showMemory ? "内存占用" : "CPU 占用")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.42))
                .frame(width: 112, alignment: .trailing)
        }
        .frame(height: 24)
        .background(ProcMonitorIslandStyle.band.opacity(0.32))
    }

    private var processRows: some View {
        LazyVStack(spacing: 0) {
            if monitor.processes.isEmpty {
                Text("正在加载...")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ProcMonitorIslandStyle.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 42)
            } else {
                ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { index, group in
                    ProcMonitorIslandRow(
                        process: group.parent,
                        memoryBytes: group.totalResidentBytes,
                        cpu: group.totalCPU,
                        totalMemoryBytes: monitor.totalMemoryBytes,
                        showMemory: showMemory,
                        childCount: group.children.count,
                        isExpanded: expandedPids.contains(group.parent.pid),
                        isChild: false,
                        onToggle: { toggle(group.parent.pid, hasChildren: !group.children.isEmpty) }
                    )

                    if expandedPids.contains(group.parent.pid) {
                        ForEach(group.children.prefix(5)) { child in
                            Divider().opacity(0.08).padding(.leading, 40)
                            ProcMonitorIslandRow(
                                process: child,
                                memoryBytes: child.residentBytes,
                                cpu: child.cpu,
                                totalMemoryBytes: monitor.totalMemoryBytes,
                                showMemory: showMemory,
                                childCount: 0,
                                isExpanded: false,
                                isChild: true,
                                onToggle: {}
                            )
                        }
                    }

                    if index < visibleGroups.count - 1 {
                        Divider().opacity(0.08).padding(.leading, 40)
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: showSystem ? "lock.fill" : "person.fill")
                    .font(.system(size: 10, weight: .medium))
                Text("\(showSystem ? "系统" : "用户") · \(showMemory ? "内存" : "CPU")")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.48))

            Spacer()

            Button {
                showSystem.toggle()
                expandedPids.removeAll()
            } label: {
                HStack(spacing: 4) {
                    if showSystem {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("用户 · \(showMemory ? "内存" : "CPU")")
                    } else {
                        Text("系统 · \(showMemory ? "内存" : "CPU")")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.62))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ProcMonitorIslandStyle.band.opacity(0.28))
    }

    private func metricButton(
        title: String,
        value: String,
        active: Bool,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                Text(value)
                    .font(.system(size: 11, weight: active ? .semibold : .medium).monospacedDigit())
                    .opacity(active ? 0.76 : 0.66)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .foregroundStyle(active ? ProcMonitorIslandStyle.text : ProcMonitorIslandStyle.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? accent.opacity(0.16) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            .fill(ProcMonitorIslandStyle.background)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.36), lineWidth: 0.8)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
    }

    private func toggle(_ pid: Int, hasChildren: Bool) {
        guard hasChildren else { return }
        if expandedPids.contains(pid) {
            expandedPids.remove(pid)
        } else {
            expandedPids.insert(pid)
        }
    }
}

private struct ProcMonitorIslandRow: View {
    let process: ProcMonitorIslandProcess
    let memoryBytes: Int64
    let cpu: Double
    let totalMemoryBytes: Int64
    let showMemory: Bool
    let childCount: Int
    let isExpanded: Bool
    let isChild: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    private var memoryPercent: CGFloat {
        totalMemoryBytes > 0 ? CGFloat(Double(memoryBytes) / Double(totalMemoryBytes)) : 0
    }

    private var cpuPercent: CGFloat {
        CGFloat(min(cpu / 100, 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            icon
                .padding(.leading, isChild ? 28 : 12)
                .opacity(isChild ? 0.7 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(process.displayName)
                        .font(.system(size: isChild ? 12 : 13, weight: isChild ? .regular : .medium))
                        .foregroundStyle(isChild ? ProcMonitorIslandStyle.text.opacity(0.7) : ProcMonitorIslandStyle.text)
                        .lineLimit(1)

                    if childCount > 0 {
                        HStack(spacing: 2) {
                            Text("\(childCount)")
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ProcMonitorIslandStyle.muted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(ProcMonitorIslandStyle.tagBackground, in: RoundedRectangle(cornerRadius: 6))
                    }
                }

                Text(process.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(ProcMonitorIslandStyle.muted.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(.leading, 7)
            .frame(width: 166, alignment: .leading)

            Spacer(minLength: 8)

            metric
                .frame(width: 116)
        }
        .frame(height: isChild ? 32 : 39)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.48))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.68), lineWidth: 0.8)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .help(process.description)
    }

    private var icon: some View {
        Group {
            if let image = process.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                    .cornerRadius(7)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(ProcMonitorIslandStyle.tagBackground)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ProcMonitorIslandStyle.muted)
                }
                .frame(width: 26, height: 26)
            }
        }
    }

    private var metric: some View {
        HStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(ProcMonitorIslandStyle.tagBackground).frame(height: 3)
                    Capsule()
                        .fill(ProcMonitorIslandStyle.barColor(showMemory ? Double(memoryPercent) * 100 : cpu))
                        .frame(
                            width: geometry.size.width * (showMemory ? memoryPercent : cpuPercent),
                            height: 3
                        )
                }
            }
            .frame(width: 58, height: 3)

            Text(showMemory ? ProcMonitorIslandStyle.formatBytes(memoryBytes) : String(format: "%.1f%%", cpu))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isChild ? ProcMonitorIslandStyle.muted : ProcMonitorIslandStyle.text)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private final class ProcMonitorIslandModel: ObservableObject {
    @Published var processes: [ProcMonitorIslandProcess] = []
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 1
    @Published var memoryPercent: Double = 0

    private var timer: Timer?

    var totalMemoryBytes: Int64 {
        Int64(memoryTotalGB * 1_073_741_824)
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func groups(showSystem: Bool, sortByMemory: Bool) -> [ProcMonitorIslandGroup] {
        let filtered = processes.filter { showSystem ? $0.isSystem : !$0.isSystem }
        let ids = Set(filtered.map(\.pid))
        let byPid = Dictionary(uniqueKeysWithValues: filtered.map { ($0.pid, $0) })
        var childrenByParent: [Int: [ProcMonitorIslandProcess]] = [:]
        var topLevel: [Int] = []

        for process in filtered {
            if process.parentPid != process.pid, ids.contains(process.parentPid) {
                childrenByParent[process.parentPid, default: []].append(process)
            } else {
                topLevel.append(process.pid)
            }
        }

        var groups = topLevel.compactMap { pid -> ProcMonitorIslandGroup? in
            guard let parent = byPid[pid] else { return nil }
            let children = (childrenByParent[pid] ?? []).sorted {
                sortByMemory ? $0.residentBytes > $1.residentBytes : $0.cpu > $1.cpu
            }
            return ProcMonitorIslandGroup(parent: parent, children: children)
        }

        groups.sort {
            sortByMemory ? $0.totalResidentBytes > $1.totalResidentBytes : $0.totalCPU > $1.totalCPU
        }
        return groups
    }

    private func refresh() {
        let icons = Self.runningApplicationIcons()
        DispatchQueue.global(qos: .utility).async {
            let processes = Self.fetchProcesses(icons: icons)
            let memory = Self.fetchMemory()
            DispatchQueue.main.async {
                self.processes = processes
                self.memoryUsedGB = memory.used
                self.memoryTotalGB = memory.total
                self.memoryPercent = memory.percent
            }
        }
    }

    private static func runningApplicationIcons() -> [Int: (name: String, icon: NSImage)] {
        var icons: [Int: (String, NSImage)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = Int(app.processIdentifier)
            guard pid > 0, let icon = app.icon else { continue }
            icons[pid] = (app.localizedName ?? app.bundleIdentifier ?? "", icon)
        }
        return icons
    }

    private static func fetchProcesses(
        icons: [Int: (name: String, icon: NSImage)]
    ) -> [ProcMonitorIslandProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,rss=,%cpu=,user=,comm="]

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
        return raw.components(separatedBy: "\n").compactMap { parseProcessLine($0, icons: icons) }
    }

    private static func parseProcessLine(
        _ line: String,
        icons: [Int: (name: String, icon: NSImage)]
    ) -> ProcMonitorIslandProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(maxSplits: 5, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 6,
              let pid = Int(parts[0]),
              let parentPid = Int(parts[1]),
              let rssKB = Int64(parts[2]),
              let cpu = Double(parts[3])
        else { return nil }

        let user = String(parts[4])
        let rawPath = String(parts[5])
        let name = rawPath.split(separator: "/").last.map(String.init) ?? rawPath
        let safeName = name.isEmpty ? "proc-\(pid)" : String(name.prefix(40))
        let app = icons[pid]

        return ProcMonitorIslandProcess(
            pid: pid,
            parentPid: parentPid,
            name: safeName,
            user: user,
            residentBytes: rssKB * 1024,
            cpu: cpu,
            path: rawPath,
            icon: app?.icon,
            appName: app?.name
        )
    }

    private static func fetchMemory() -> (used: Double, total: Double, percent: Double) {
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
        let total = Double(max(totalBytes, 1)) / gb
        let used = Double(max(usedBytes, 0)) / gb
        return (used, total, min(100, max(0, Double(usedBytes) / Double(max(totalBytes, 1)) * 100)))
    }
}

private struct ProcMonitorIslandProcess: Identifiable {
    let id = UUID()
    let pid: Int
    let parentPid: Int
    let name: String
    let user: String
    let residentBytes: Int64
    let cpu: Double
    let path: String
    let icon: NSImage?
    let appName: String?

    var displayName: String {
        appName?.isEmpty == false ? appName! : name
    }

    var subtitle: String {
        "PID \(pid)"
    }

    var description: String {
        ProcMonitorIslandStyle.description(for: name)
    }

    var isSystem: Bool {
        if user == "root" || user.hasPrefix("_") || user == "daemon" {
            return true
        }
        if path.hasPrefix("/System/Library/")
            || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/private/var/") {
            return true
        }
        return ProcMonitorIslandStyle.systemNames.contains(name)
    }
}

private struct ProcMonitorIslandGroup: Identifiable {
    let id = UUID()
    let parent: ProcMonitorIslandProcess
    let children: [ProcMonitorIslandProcess]

    var totalResidentBytes: Int64 {
        parent.residentBytes + children.reduce(Int64(0)) { $0 + $1.residentBytes }
    }

    var totalCPU: Double {
        parent.cpu + children.reduce(0) { $0 + $1.cpu }
    }
}

private enum ProcMonitorIslandStyle {
    static let background = Color(red: 0.961, green: 0.965, blue: 0.980)
    static let text = Color(red: 0.102, green: 0.102, blue: 0.180)
    static let muted = Color(red: 0.600, green: 0.600, blue: 0.667)
    static let tagBackground = Color(red: 0.918, green: 0.918, blue: 0.937)
    static let green = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let amber = Color(red: 0.980, green: 0.620, blue: 0.020)
    static let red = Color(red: 0.871, green: 0.161, blue: 0.063)
    static let hairline = Color.white.opacity(0.18)
    static let band = Color.white.opacity(0.035)

    static let systemNames: Set<String> = [
        "loginwindow", "WindowServer", "kernel_task", "launchd", "UserEventAgent",
        "warmd", "diskarbitrationd", "notifyd", "powerd", "configd", "opendirectoryd",
        "cfprefsd", "syslogd", "coreauthd", "bluetoothd", "BTLEServer", "corespotlightd",
        "hidd", "coreduetd", "apsd", "locationd", "tccd", "trustd"
    ]

    private static let descriptions: [String: String] = [
        "kernel_task": "macOS 内核，管理 CPU 调度、内存和设备驱动",
        "launchd": "系统和用户进程的总管家",
        "WindowServer": "负责所有窗口绘制和屏幕合成",
        "Finder": "macOS 文件管理器，桌面和访达界面",
        "Dock": "程序坞，管理应用图标和快速启动",
        "node": "Node.js JavaScript 运行时",
        "python3": "Python 3 解释器",
        "xcodebuild": "Xcode 命令行构建工具",
        "Ping Island": "当前应用：Ping Island",
        "PingIslandPlugin": "Ping Island 插件运行进程"
    ]

    static func barColor(_ percent: Double) -> Color {
        if percent < 60 { return green }
        if percent < 90 { return amber }
        return red
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.2fGB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fMB", mb)
    }

    static func description(for name: String) -> String {
        if let description = descriptions[name] {
            return description
        }
        for (key, value) in descriptions where name.hasPrefix(key) || key.hasPrefix(name) {
            return value
        }
        return "进程：\(name)"
    }
}

struct PluginNotificationPanelView: View {
    let notification: PluginNotifyUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                IslandPluginRenderer.iconView(notification.content.icon, size: 18)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.content.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = notification.content.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            if let actionLabel = notification.content.actionLabel,
               let actionId = notification.content.actionId {
                Button {
                    NotificationCenter.default.post(
                        name: .pluginButtonTapped,
                        object: nil,
                        userInfo: [
                            "pluginId": notification.pluginId,
                            "actionId": actionId
                        ]
                    )
                } label: {
                    Text(actionLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}
