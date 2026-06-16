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
        activeRealtimeNotificationSession: SessionState? = nil,
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
            if let activeRealtimeNotificationSession {
                return .chat(activeRealtimeNotificationSession)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
        case .hover:
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeRealtimeNotificationSession {
                return .chat(activeRealtimeNotificationSession)
            }
        case .click, .pinnedList:
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
            if let activeRealtimeNotificationSession {
                return .chat(activeRealtimeNotificationSession)
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
    private static let procMonitorPluginId = "com.auralink.procmonitor"
    private static let usageMonitorPluginId = "com.auralink.usage"
    private static let weatherDemoPluginId = "com.example.weatherdemo"

    let pluginId: String
    @ObservedObject private var arbiter = PluginSlotArbiter.shared
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        Group {
            if pluginId == Self.procMonitorPluginId {
                ProcMonitorIslandPanelView()
            } else if pluginId == Self.usageMonitorPluginId {
                UsageMonitorIslandPanelView(
                    pluginId: pluginId,
                    sections: arbiter.expandedContent[pluginId] ?? []
                )
            } else if pluginId == Self.weatherDemoPluginId {
                WeatherDemoIslandPanelView(
                    pluginId: pluginId,
                    sections: arbiter.expandedContent[pluginId] ?? []
                )
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
        .onAppear {
            arbiter.currentlyDisplayedExpandedPluginId = pluginId
            Task { await PluginHost.shared.ensurePluginRunning(pluginId) }
        }
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

private struct WeatherDemoIslandPanelView: View {
    let pluginId: String
    let sections: [ExpandedSection]

    private var temperature: String {
        statValue(containing: "气温") ?? "23°C"
    }

    private var humidity: Double {
        progressValue(containing: "湿度") ?? 0.65
    }

    private var wind: String {
        statValue(containing: "风速") ?? "12 km/h"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.72, blue: 0.24),
                                    Color(red: 1.00, green: 0.42, blue: 0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 58, height: 58)
                .shadow(color: Color.orange.opacity(0.28), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("天气 Demo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                    Text(temperature)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                    Text("晴朗 · 体感舒适")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                weatherMetric(
                    icon: "humidity.fill",
                    title: "湿度",
                    value: "\(Int((humidity * 100).rounded()))%"
                )
                weatherMetric(
                    icon: "wind",
                    title: "风速",
                    value: wind
                )
            }

            Button {
                NotificationCenter.default.post(
                    name: .pluginButtonTapped,
                    object: nil,
                    userInfo: [
                        "pluginId": pluginId,
                        "actionId": "refresh"
                    ]
                )
            } label: {
                Label("刷新天气", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.16, blue: 0.23).opacity(0.96),
                            Color.black.opacity(0.92)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
        )
    }

    private func weatherMetric(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.76))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func statValue(containing text: String) -> String? {
        for section in sections {
            if case .stat(let stat) = section, stat.label.contains(text) {
                return stat.value
            }
        }
        return nil
    }

    private func progressValue(containing text: String) -> Double? {
        for section in sections {
            if case .progress(let progress) = section, progress.label?.contains(text) == true {
                return progress.value
            }
        }
        return nil
    }
}

private struct UsageMonitorIslandPanelView: View {
    let pluginId: String
    let sections: [ExpandedSection]

    private var claudeStatus: StatSection? {
        stat(containing: "Claude 状态")
    }

    private var codexStatus: StatSection? {
        stat(containing: "Codex 状态")
    }

    private var claudeSession: ProgressSection? {
        progress(containing: "Claude 5小时")
    }

    private var claudeWeekly: ProgressSection? {
        progress(containing: "Claude 7日")
    }

    private var codexPrimary: ProgressSection? {
        progress(containing: "Codex 5小时")
    }

    private var codexSecondary: ProgressSection? {
        progress(containing: "Codex 7日")
    }

    private var todayTokens: StatSection? {
        stat(containing: "今日 Tokens")
    }

    private var credits: StatSection? {
        stat(containing: "Credits")
    }

    private var updateText: String {
        text(containing: "更新于") ?? "等待首次刷新"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                providerCard(
                    title: "Claude",
                    subtitle: claudeStatus?.value ?? "加载中",
                    assetName: "ClaudeLogo",
                    tint: usageColor(.claude),
                    rows: [
                        usageRow("5小时", claudeSession, tint: usageColor(.session)),
                        usageRow("7日", claudeWeekly, tint: usageColor(.weekly))
                    ],
                    footer: todayTokens.map { ("今日 Tokens", $0.value, usageColor(.tokens)) }
                )

                providerCard(
                    title: "Codex",
                    subtitle: codexStatus?.value ?? "加载中",
                    assetName: "CodexLogo",
                    tint: usageColor(.codex),
                    rows: [
                        usageRow("5小时", codexPrimary, tint: usageColor(.sessionAlt)),
                        usageRow("7日", codexSecondary, tint: usageColor(.weeklyAlt))
                    ],
                    footer: credits.map { ("Credits", $0.value, usageColor(.credits)) }
                )
            }

            if !extraMessages.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(extraMessages, id: \.self) { message in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.34))
                            Text(message)
                                .font(.system(size: 9.8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.50))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                Text(updateText)
                    .font(.system(size: 9.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))

                Spacer(minLength: 0)

                Button {
                    NotificationCenter.default.post(
                        name: .pluginButtonTapped,
                        object: nil,
                        userInfo: [
                            "pluginId": pluginId,
                            "actionId": "refresh"
                        ]
                    )
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.74))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .help("刷新")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
    }

    private func providerCard(
        title: String,
        subtitle: String,
        assetName: String,
        tint: Color,
        rows: [UsageMonitorRow],
        footer: (String, String, Color)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 17, height: 17)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tint.opacity(0.24), lineWidth: 0.6)
                    )

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))

                Spacer(minLength: 0)

                Text(subtitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(tint.opacity(0.14))
                    )
            }

            VStack(spacing: 6) {
                ForEach(rows) { row in
                    usageMeter(row)
                }
            }

            if let footer {
                Divider().overlay(.white.opacity(0.065))
                HStack {
                    Text(footer.0)
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer(minLength: 0)
                    Text(footer.1)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(footer.2.opacity(0.86))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.12), .black.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.16), lineWidth: 0.6)
                )
        )
    }

    private func usageMeter(_ row: UsageMonitorRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.label)
                    .font(.system(size: 9.6, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer(minLength: 0)
                Text(row.valueText)
                    .font(.system(size: 9.8, weight: .semibold, design: .rounded))
                    .foregroundStyle(row.tint.opacity(0.82))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.10))
                    Capsule()
                        .fill(row.tint.opacity(0.82))
                        .frame(width: geometry.size.width * row.value)
                }
            }
            .frame(height: 4)
        }
    }

    private func usageRow(_ label: String, _ section: ProgressSection?, tint: Color) -> UsageMonitorRow {
        guard let section else {
            return UsageMonitorRow(label: label, value: 0, valueText: "--", tint: tint.opacity(0.35))
        }
        let value = min(max(section.value, 0), 1)
        return UsageMonitorRow(
            label: label,
            value: value,
            valueText: "\(Int((value * 100).rounded()))%",
            tint: tint
        )
    }

    private var extraMessages: [String] {
        sections.compactMap { section in
            guard case .text(let text) = section else { return nil }
            if text.style == .heading || text.content.contains("更新于") {
                return nil
            }
            return text.content
        }
    }

    private func stat(containing needle: String) -> StatSection? {
        sections.compactMap { section -> StatSection? in
            guard case .stat(let stat) = section else { return nil }
            return stat.label.contains(needle) ? stat : nil
        }.first
    }

    private func progress(containing needle: String) -> ProgressSection? {
        sections.compactMap { section -> ProgressSection? in
            guard case .progress(let progress) = section,
                  progress.label?.contains(needle) == true else { return nil }
            return progress
        }.first
    }

    private func text(containing needle: String) -> String? {
        sections.compactMap { section -> String? in
            guard case .text(let text) = section,
                  text.content.contains(needle) else { return nil }
            return text.content
        }.first
    }

    private func color(for tint: PluginTint?) -> Color {
        switch tint {
        case .green:
            return Color(red: 0.22, green: 0.78, blue: 0.45)
        case .yellow:
            return Color(red: 0.95, green: 0.72, blue: 0.24)
        case .orange:
            return Color(red: 0.95, green: 0.50, blue: 0.22)
        case .red:
            return Color(red: 0.94, green: 0.28, blue: 0.28)
        case .blue:
            return Color(red: 0.30, green: 0.60, blue: 0.90)
        case .purple:
            return Color(red: 0.58, green: 0.44, blue: 0.92)
        case .default, .none:
            return Color(red: 0.50, green: 0.62, blue: 0.78)
        }
    }

    private func usageColor(_ role: UsageMonitorColorRole) -> Color {
        switch role {
        case .claude:
            return Color(red: 0.92, green: 0.47, blue: 0.28)
        case .codex:
            return Color(red: 0.32, green: 0.58, blue: 0.96)
        case .session:
            return Color(red: 0.98, green: 0.63, blue: 0.30)
        case .weekly:
            return Color(red: 0.28, green: 0.82, blue: 0.48)
        case .sessionAlt:
            return Color(red: 0.25, green: 0.72, blue: 0.95)
        case .weeklyAlt:
            return Color(red: 0.62, green: 0.48, blue: 0.96)
        case .tokens:
            return Color(red: 0.98, green: 0.78, blue: 0.32)
        case .credits:
            return Color(red: 0.42, green: 0.84, blue: 0.94)
        }
    }
}

private enum UsageMonitorColorRole {
    case claude
    case codex
    case session
    case weekly
    case sessionAlt
    case weeklyAlt
    case tokens
    case credits
}

private struct UsageMonitorRow: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let valueText: String
    let tint: Color
}

private struct ProcMonitorIslandPanelView: View {
    @StateObject private var monitor = ProcMonitorIslandModel()
    @State private var showMemory = true
    @State private var showSystem = false
    @State private var expandedPids: Set<Int> = []

    private let rowViewportHeight: CGFloat = 288
    private let cardRadius: CGFloat = 13

    private var groups: [ProcMonitorIslandGroup] {
        monitor.groups(showSystem: showSystem, sortByMemory: showMemory)
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
                .stroke(ProcMonitorIslandStyle.edge, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 12)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.82))
                .frame(width: 30, height: 28, alignment: .leading)

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
                .frame(width: 1, height: 26)

            metricButton(
                title: "CPU",
                value: String(format: "%.1f%%", totalCPU),
                active: !showMemory,
                accent: ProcMonitorIslandStyle.green
            ) {
                showMemory = false
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("应用进程")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.42))
                .padding(.leading, 39)
            Spacer()
            Text(showMemory ? "内存占用" : "CPU 占用")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.42))
                .frame(width: 108, alignment: .trailing)
            Text("")
                .frame(width: 30)
        }
        .frame(height: 22)
        .background(ProcMonitorIslandStyle.band.opacity(0.32))
    }

    private var processRows: some View {
        let displayedGroups = groups

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                if monitor.processes.isEmpty {
                    Text("正在加载...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ProcMonitorIslandStyle.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 42)
                } else {
                    ForEach(Array(displayedGroups.enumerated()), id: \.element.id) { index, group in
                        ProcMonitorIslandRow(
                            process: group.parent,
                            memoryBytes: group.totalResidentBytes,
                            cpu: group.totalCPU,
                            totalMemoryBytes: monitor.totalMemoryBytes,
                            showMemory: showMemory,
                            childCount: group.children.count,
                            isExpanded: expandedPids.contains(group.parent.pid),
                            isChild: false,
                            onToggle: { toggle(group.parent.pid, hasChildren: !group.children.isEmpty) },
                            onTerminate: { monitor.terminate(pid: group.parent.pid) }
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
                                    onToggle: {},
                                    onTerminate: { monitor.terminate(pid: child.pid) }
                                )
                            }
                        }

                        if index < displayedGroups.count - 1 {
                            Divider().opacity(0.08).padding(.leading, 40)
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(height: rowViewportHeight)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: showSystem ? "lock.fill" : "person.fill")
                    .font(.system(size: 10, weight: .medium))
                Text("\(showSystem ? "系统" : "用户") · \(showMemory ? "内存" : "CPU")")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.48))

            Spacer()

            hardwareMetricStrip

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
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(ProcMonitorIslandStyle.band.opacity(0.28))
    }

    private var hardwareMetricStrip: some View {
        HStack(spacing: 5) {
            hardwareMetricBadge(
                icon: "thermometer.medium",
                value: monitor.hardwareMetrics.enclosureTemperatureText,
                tint: ProcMonitorIslandStyle.cyan
            )
            hardwareMetricBadge(
                icon: "cpu.fill",
                value: monitor.hardwareMetrics.cpuTemperatureText,
                tint: ProcMonitorIslandStyle.amber
            )
            hardwareMetricBadge(
                icon: "fan.fill",
                value: monitor.hardwareMetrics.fanSpeedText,
                tint: ProcMonitorIslandStyle.green
            )
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hardwareMetricBadge(icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.84))
            Text(value)
                .font(.system(size: 9.3, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(ProcMonitorIslandStyle.text.opacity(0.66))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint.opacity(0.10))
                .overlay(Capsule().strokeBorder(tint.opacity(0.17), lineWidth: 0.5))
        )
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
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                Text(value)
                    .font(.system(size: 10, weight: active ? .semibold : .medium).monospacedDigit())
                    .opacity(active ? 0.76 : 0.66)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .foregroundStyle(active ? ProcMonitorIslandStyle.text : ProcMonitorIslandStyle.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 28)
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
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
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
    let onTerminate: () -> Void

    @State private var hovering = false
    @State private var terminateHovering = false

    private var memoryPercent: CGFloat {
        totalMemoryBytes > 0 ? CGFloat(Double(memoryBytes) / Double(totalMemoryBytes)) : 0
    }

    private var cpuPercent: CGFloat {
        CGFloat(min(cpu / 100, 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            icon
                .padding(.leading, isChild ? 24 : 10)
                .opacity(isChild ? 0.7 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(process.displayName)
                        .font(.system(size: isChild ? 11 : 12, weight: isChild ? .regular : .medium))
                        .foregroundStyle(isChild ? ProcMonitorIslandStyle.text.opacity(0.7) : ProcMonitorIslandStyle.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

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
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(process.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(ProcMonitorIslandStyle.muted.opacity(0.58))
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .frame(width: 144, alignment: .leading)

            Spacer(minLength: 6)

            metric
                .frame(width: 106)

            terminateButton
                .frame(width: 28)
                .padding(.trailing, 4)
        }
        .frame(height: isChild ? 28 : 34)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 0.8)
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
                    .frame(width: 23, height: 23)
                    .cornerRadius(6)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(ProcMonitorIslandStyle.tagBackground)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ProcMonitorIslandStyle.muted)
                }
                .frame(width: 23, height: 23)
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
            .frame(width: 52, height: 3)

            Text(showMemory ? ProcMonitorIslandStyle.formatBytes(memoryBytes) : String(format: "%.1f%%", cpu))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(isChild ? ProcMonitorIslandStyle.muted : ProcMonitorIslandStyle.text)
                .frame(width: 48, alignment: .trailing)
        }
    }

    private var terminateButton: some View {
        Button {
            if process.isSystem {
                let alert = NSAlert()
                alert.messageText = "结束系统进程「\(process.displayName)」？"
                alert.informativeText = "\(process.description)\n\n结束系统进程可能导致系统不稳定、应用崩溃，甚至需要重启。"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "取消")
                let terminate = alert.addButton(withTitle: "强制结束")
                terminate.hasDestructiveAction = true
                if alert.runModal() == .alertSecondButtonReturn {
                    onTerminate()
                }
            } else {
                onTerminate()
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    terminateHovering
                        ? (process.isSystem ? ProcMonitorIslandStyle.amber : ProcMonitorIslandStyle.red)
                        : ProcMonitorIslandStyle.muted.opacity(0.32)
                )
        }
        .buttonStyle(.plain)
        .onHover { terminateHovering = $0 }
        .help(process.isSystem ? "警告：结束系统进程可能导致系统不稳定" : "结束进程")
    }
}

private final class ProcMonitorIslandModel: ObservableObject {
    @Published var processes: [ProcMonitorIslandProcess] = []
    @Published var memoryUsedGB: Double = 0
    @Published var memoryTotalGB: Double = 1
    @Published var memoryPercent: Double = 0
    @Published var hardwareMetrics = ProcMonitorHardwareMetrics()

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
        processes.removeAll(keepingCapacity: false)
        Self.expandedIconCache.removeAll(keepingCapacity: true)
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

    func terminate(pid: Int) {
        Darwin.kill(pid_t(pid), SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if Darwin.kill(pid_t(pid), 0) == 0 {
                Darwin.kill(pid_t(pid), SIGKILL)
            }
            self.refresh()
        }
    }

    private func refresh() {
        let icons = Self.runningApplicationIcons()
        DispatchQueue.global(qos: .utility).async {
            let processes = Self.fetchProcesses(icons: icons)
            let memory = Self.fetchMemory()
            let hardwareMetrics = Self.fetchHardwareMetrics()
            DispatchQueue.main.async {
                self.processes = processes
                self.memoryUsedGB = memory.used
                self.memoryTotalGB = memory.total
                self.memoryPercent = memory.percent
                self.hardwareMetrics = hardwareMetrics
            }
        }
    }

    private static func runningApplicationIcons() -> [Int: (name: String, icon: NSImage)] {
        var icons: [Int: (String, NSImage)] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = Int(app.processIdentifier)
            guard pid > 0 else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            guard let icon = cachedThumbnailIcon(for: app) else { continue }
            icons[pid] = (name, icon)
        }
        return icons
    }

    private static var expandedIconCache: [String: NSImage] = [:]

    private static func cachedThumbnailIcon(for app: NSRunningApplication) -> NSImage? {
        let key = app.bundleIdentifier ?? app.bundleURL?.path ?? "\(app.processIdentifier)"
        if let cached = expandedIconCache[key] {
            return cached
        }
        guard let icon = app.icon else { return nil }
        let thumbnail = thumbnailIcon(from: icon)
        if expandedIconCache.count > 80 {
            expandedIconCache.removeAll(keepingCapacity: true)
        }
        expandedIconCache[key] = thumbnail
        return thumbnail
    }

    private static func thumbnailIcon(from icon: NSImage) -> NSImage {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = icon.isTemplate
        return image
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

    private static func fetchHardwareMetrics() -> ProcMonitorHardwareMetrics {
        ProcMonitorHardwareMetrics(
            enclosureTemperatureCelsius: fetchBatteryTemperature(),
            cpuTemperatureCelsius: fetchExternalCPUTemperature(),
            fanRPM: fetchExternalFanRPM()
        )
    }

    private static func fetchBatteryTemperature() -> Double? {
        guard let output = runCommand(
            executable: "/usr/sbin/ioreg",
            arguments: ["-r", "-n", "AppleSmartBattery", "-w0"]
        ) else { return nil }

        let pattern = #""Temperature"\s*=\s*(\d+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..<output.endIndex, in: output)
            ),
            let range = Range(match.range(at: 1), in: output),
            let rawValue = Double(output[range])
        else { return nil }

        let celsius = rawValue > 200 ? rawValue / 100 : rawValue
        guard celsius > -20, celsius < 120 else { return nil }
        return celsius
    }

    private static func fetchExternalCPUTemperature() -> Double? {
        for executable in [
            "/opt/homebrew/bin/osx-cpu-temp",
            "/usr/local/bin/osx-cpu-temp"
        ] {
            guard FileManager.default.isExecutableFile(atPath: executable),
                  let output = runCommand(executable: executable, arguments: [])
            else { continue }

            if let value = firstDouble(in: output), value > -20, value < 130 {
                return value
            }
        }
        return nil
    }

    private static func fetchExternalFanRPM() -> Int? {
        for executable in [
            "/opt/homebrew/bin/istats",
            "/usr/local/bin/istats"
        ] {
            guard FileManager.default.isExecutableFile(atPath: executable),
                  let output = runCommand(executable: executable, arguments: ["fan"])
            else { continue }

            let pattern = #"(\d+(?:\.\d+)?)\s*RPM"#
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: output,
                    range: NSRange(output.startIndex..<output.endIndex, in: output)
                ),
                let range = Range(match.range(at: 1), in: output),
                let rpm = Double(output[range])
            else { continue }
            return Int(rpm.rounded())
        }
        return nil
    }

    private static func firstDouble(in text: String) -> Double? {
        let pattern = #"(-?\d+(?:\.\d+)?)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }

    private static func runCommand(executable: String, arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct ProcMonitorHardwareMetrics {
    let enclosureTemperatureCelsius: Double?
    let cpuTemperatureCelsius: Double?
    let fanRPM: Int?

    init(
        enclosureTemperatureCelsius: Double? = nil,
        cpuTemperatureCelsius: Double? = nil,
        fanRPM: Int? = nil
    ) {
        self.enclosureTemperatureCelsius = enclosureTemperatureCelsius
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.fanRPM = fanRPM
    }

    var enclosureTemperatureText: String {
        temperatureText(enclosureTemperatureCelsius)
    }

    var cpuTemperatureText: String {
        temperatureText(cpuTemperatureCelsius)
    }

    var fanSpeedText: String {
        guard let fanRPM else { return "--" }
        return "\(fanRPM)"
    }

    private func temperatureText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))°"
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
    static let background = Color.black.opacity(0.94)
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.50)
    static let tagBackground = Color.white.opacity(0.11)
    static let green = Color(red: 0.23, green: 0.86, blue: 0.48)
    static let amber = Color(red: 1.00, green: 0.66, blue: 0.17)
    static let cyan = Color(red: 0.25, green: 0.78, blue: 0.95)
    static let red = Color(red: 1.00, green: 0.31, blue: 0.25)
    static let edge = Color.white.opacity(0.18)
    static let hairline = Color.white.opacity(0.13)
    static let band = Color.white.opacity(0.07)

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
        "Auralink": "当前应用：Auralink",
        "PingIslandPlugin": "Auralink 插件运行进程"
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
    let onDismiss: () -> Void

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

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("关闭通知")
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
