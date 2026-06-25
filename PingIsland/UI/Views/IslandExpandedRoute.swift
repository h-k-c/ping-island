import Foundation
import AppKit
import Combine
import Darwin
import IOKit
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
    case pluginNotification(PluginNotifyUpdate)
    case plugin(pluginId: String)
    case empty
}

enum IslandExpandedRouteResolver {
    /// Plugin-host routing: the island only ever surfaces plugin content or a
    /// plugin notification. Session monitoring has been removed.
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType?,
        activePluginNotification: PluginNotifyUpdate? = nil
    ) -> IslandExpandedRoute {
        if case .plugin(let id) = contentType {
            return .plugin(pluginId: id)
        }

        if let activePluginNotification {
            return .pluginNotification(activePluginNotification)
        }

        return .empty
    }
}

struct PluginExpandedPanelView: View {
    private static let procMonitorPluginId  = "com.auralink.procmonitor"
    private static let usageMonitorPluginId = "com.auralink.usage"
    private static let claudeUsagePluginId  = "com.auralink.claudeUsage"
    private static let codexUsagePluginId   = "com.auralink.codexUsage"
    private static let videoLoomPluginId    = "com.videoloom.recorder"

    let pluginId: String
    @ObservedObject private var arbiter = PluginSlotArbiter.shared
    @ObservedObject private var registry = PluginRegistry.shared

    var body: some View {
        Group {
            if pluginId == Self.procMonitorPluginId {
                ProcMonitorIslandPanelView()
            } else if pluginId == Self.usageMonitorPluginId {
                UsageMonitorIslandPanelView(pluginId: pluginId,
                    sections: arbiter.expandedContent[pluginId] ?? [], show: .all)
            } else if pluginId == Self.claudeUsagePluginId {
                UsageMonitorIslandPanelView(pluginId: pluginId,
                    sections: arbiter.expandedContent[pluginId] ?? [], show: .claude)
            } else if pluginId == Self.codexUsagePluginId {
                UsageMonitorIslandPanelView(pluginId: pluginId,
                    sections: arbiter.expandedContent[pluginId] ?? [], show: .codex)
            } else if pluginId == Self.videoLoomPluginId {
                VideoLoomIslandPanelView(
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

private struct UsageMonitorIslandPanelView: View {
    enum ShowProvider { case all, claude, codex }
    let pluginId: String
    let sections: [ExpandedSection]
    var show: ShowProvider = .all

    @State private var claudeSessionKey = ""
    @State private var didLoadClaudeSessionKey = false
    @State private var claudeCredentialMessage: String?

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
                if show != .codex {
                    providerCard(
                        title: "Claude",
                        subtitle: claudeStatus?.value ?? "加载中",
                        assetName: "ClaudeLogo",
                        tint: usageColor(.claude),
                        rows: [
                            usageRow("5小时", claudeSession, tint: usageColor(.session)),
                            usageRow("7日", claudeWeekly, tint: usageColor(.weekly))
                        ],
                        resetRows: claudeResetRows,
                        footer: todayTokens.map { ("今日 Tokens", $0.value, usageColor(.tokens)) }
                    )
                }
                if show != .claude {
                    providerCard(
                        title: "Codex",
                        subtitle: codexStatus?.value ?? "加载中",
                        assetName: "CodexLogo",
                        tint: usageColor(.codex),
                        rows: [
                            usageRow("5小时", codexPrimary, tint: usageColor(.sessionAlt)),
                            usageRow("7日", codexSecondary, tint: usageColor(.weeklyAlt))
                        ],
                        resetRows: codexResetRows,
                        footer: credits.map { ("Credits", $0.value, usageColor(.credits)) }
                    )
                }
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

            if shouldShowClaudeCredentialInput {
                claudeCredentialInput
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
        .onAppear {
            Task { @MainActor in
                loadClaudeSessionKeyIfNeeded()
            }
        }
    }

    private var shouldShowClaudeCredentialInput: Bool {
        let status = claudeStatus?.value ?? ""
        return status == "未登录"
            || status == "错误"
            || extraMessages.contains { $0.contains("Claude 未登录") || $0.contains("Claude 错误") }
    }

    private var claudeResetRows: [UsageMonitorResetRow] {
        [
            resetRow(needle: "Claude 5小时", label: "5小时", tint: usageColor(.session)),
            resetRow(needle: "Claude 7日", label: "7日", tint: usageColor(.weekly))
        ].compactMap { $0 }
    }

    private var codexResetRows: [UsageMonitorResetRow] {
        [
            resetRow(needle: "Codex 5小时", label: "5小时", tint: usageColor(.sessionAlt)),
            resetRow(needle: "Codex 7日", label: "7日", tint: usageColor(.weeklyAlt))
        ].compactMap { $0 }
    }

    private var claudeCredentialInput: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(usageColor(.claude).opacity(0.82))
                Text("Claude Session Key")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 0)
                if let claudeCredentialMessage {
                    Text(claudeCredentialMessage)
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 7) {
                SecureField("sessionKey", text: $claudeSessionKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.2, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.black.opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white.opacity(0.09), lineWidth: 0.6)
                            )
                    )
                    .onSubmit {
                        Task { @MainActor in
                            saveClaudeSessionKey()
                        }
                    }

                Button {
                    Task { @MainActor in
                        saveClaudeSessionKey()
                    }
                } label: {
                    Text("保存")
                        .font(.system(size: 9.6, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(width: 38, height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(usageColor(.claude).opacity(0.30))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task { @MainActor in
                        clearClaudeSessionKey()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.2, weight: .bold))
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(width: 24, height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(0.065))
                        )
                }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(usageColor(.claude).opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(usageColor(.claude).opacity(0.18), lineWidth: 0.7)
                )
        )
    }

    @MainActor
    private func loadClaudeSessionKeyIfNeeded() {
        guard !didLoadClaudeSessionKey else { return }
        didLoadClaudeSessionKey = true
        claudeSessionKey = PluginStorage.shared.getSecret(pluginId: pluginId, key: "claudeSessionKey") ?? ""
    }

    @MainActor
    private func saveClaudeSessionKey() {
        let trimmed = claudeSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearClaudeSessionKey()
            return
        }

        claudeSessionKey = trimmed
        claudeCredentialMessage = "已保存，正在刷新"
        PluginStorage.shared.setSecret(pluginId: pluginId, key: "claudeSessionKey", value: trimmed)
        Task {
            await PluginHost.shared.notifyConfigUpdate(pluginId: pluginId, key: "claudeSessionKey", value: trimmed)
            await PluginHost.shared.sendAction(actionId: "refresh", to: pluginId)
        }
    }

    @MainActor
    private func clearClaudeSessionKey() {
        claudeSessionKey = ""
        claudeCredentialMessage = "已清空"
        PluginStorage.shared.deleteSecret(pluginId: pluginId, key: "claudeSessionKey")
        Task {
            await PluginHost.shared.notifyConfigUpdate(pluginId: pluginId, key: "claudeSessionKey", value: "")
            await PluginHost.shared.sendAction(actionId: "refresh", to: pluginId)
        }
    }

    private func providerCard(
        title: String,
        subtitle: String,
        assetName: String,
        tint: Color,
        rows: [UsageMonitorRow],
        resetRows: [UsageMonitorResetRow],
        footer: (String, String, Color)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tint.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(tint.opacity(0.24), lineWidth: 0.6)
                    )

                Spacer(minLength: 0)

                Text(subtitle)
                    .font(.system(size: 8.8, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(tint.opacity(0.14))
                    )
            }

            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            VStack(spacing: 5) {
                ForEach(rows) { row in
                    usageMeter(row)
                }
            }
            .padding(.top, 1)

            if !resetRows.isEmpty {
                VStack(spacing: 3) {
                    ForEach(resetRows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 8.4, weight: .semibold))
                                .foregroundStyle(row.tint.opacity(0.64))
                                .frame(width: 10)
                            Text(row.label)
                                .font(.system(size: 8.4, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                            Spacer(minLength: 0)
                            Text(row.value)
                                .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                }
                .padding(.top, 1)
            }

            if let footer {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(footer.0)
                        .font(.system(size: 8.6, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer(minLength: 0)
                    Text(footer.1)
                        .font(.system(size: 9.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(footer.2.opacity(0.86))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 116, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), .white.opacity(0.045), .black.opacity(0.16)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tint.opacity(0.20), lineWidth: 0.7)
                )
        )
    }

    private func usageMeter(_ row: UsageMonitorRow) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack {
                Text(row.label)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer(minLength: 0)
                Text(row.valueText)
                    .font(.system(size: 9.2, weight: .semibold, design: .rounded))
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
            if isResetMessage(text.content) {
                return nil
            }
            return text.content
        }
    }

    private func resetRow(needle: String, label: String, tint: Color) -> UsageMonitorResetRow? {
        guard var value = text(containing: needle) else { return nil }
        value = value.replacingOccurrences(of: needle, with: "")
        value = value.replacingOccurrences(of: "后重置", with: "")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return UsageMonitorResetRow(label: label, value: value, tint: tint)
    }

    private func isResetMessage(_ content: String) -> Bool {
        content.contains("Claude 5小时")
            || content.contains("Claude 7日")
            || content.contains("Codex 5小时")
            || content.contains("Codex 7日")
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

private struct UsageMonitorResetRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
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
                tint: ProcMonitorIslandStyle.cyan,
                help: "机身温度：读取系统无权限电池/机身传感器，读不到时显示 --"
            )
            hardwareMetricBadge(
                icon: "cpu.fill",
                value: monitor.hardwareMetrics.cpuTemperatureText,
                tint: ProcMonitorIslandStyle.amber,
                help: "CPU 温度：直接读取 Apple Silicon HID 温度传感器，无需管理员授权"
            )
            hardwareMetricBadge(
                icon: "memorychip.fill",
                value: "\(Int(monitor.memoryPercent.rounded()))%",
                tint: ProcMonitorIslandStyle.green,
                help: "全机内存占用率"
            )
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hardwareMetricBadge(icon: String, value: String, tint: Color, help: String) -> some View {
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
        .help(help)
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

    private static let cpuTemperatureSensorSources = discoverCPUTemperatureSensorSources()

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
                self.hardwareMetrics = hardwareMetrics.fillingMissingValues(from: self.hardwareMetrics)
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
            cpuTemperatureCelsius: fetchAppleSiliconCPUTemperature() ?? fetchExternalCPUTemperature()
        )
    }

    private static func fetchBatteryTemperature() -> Double? {
        if let value = fetchIORegistryTemperature(
            serviceClass: "AppleSmartBattery",
            propertyNames: ["Temperature", "VirtualTemperature"]
        ) {
            return value
        }

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

    private static func fetchIORegistryTemperature(
        serviceClass: String,
        propertyNames: [String]
    ) -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        for name in propertyNames {
            guard let property = IORegistryEntryCreateCFProperty(
                service,
                name as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(),
                  let rawValue = doubleValue(from: property)
            else { continue }

            let celsius = normalizedTemperature(rawValue)
            guard celsius > -20, celsius < 120 else { continue }
            return celsius
        }

        return nil
    }

    private static func normalizedTemperature(_ rawValue: Double) -> Double {
        rawValue > 200 ? rawValue / 100 : rawValue
    }

    private static func doubleValue(from value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? UInt64 {
            return Double(value)
        }
        return nil
    }

    private static func fetchAppleSiliconCPUTemperature() -> Double? {
        AppleSiliconTemperatureReader.cpuTemperature(isCPUSensor: isAppleSiliconCPUTemperatureSensor)
    }

    private static func isAppleSiliconCPUTemperatureSensor(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("PMU ") else { return false }
        let lowercased = normalized.lowercased()
        return lowercased.contains("tdie")
            || normalized.contains(" TP")
            || lowercased.contains("pacc")
            || lowercased.contains("eacc")
    }

    private static func fetchExternalCPUTemperature() -> Double? {
        for source in cpuTemperatureSensorSources {
            guard let output = runCommand(executable: source.executable, arguments: source.arguments) else { continue }
            if let value = firstDouble(in: output), value > -20, value < 130 {
                return value
            }
        }
        return nil
    }

    private static func discoverCPUTemperatureSensorSources() -> [ExternalSensorCommand] {
        var sources: [ExternalSensorCommand] = []
        for executable in [
            "/opt/homebrew/bin/osx-cpu-temp",
            "/usr/local/bin/osx-cpu-temp"
        ] where FileManager.default.isExecutableFile(atPath: executable) {
            sources.append(ExternalSensorCommand(executable: executable, arguments: []))
        }

        for executable in [
            "/opt/homebrew/bin/smc",
            "/usr/local/bin/smc"
        ] where FileManager.default.isExecutableFile(atPath: executable) {
            for key in ["TC0P", "TC0E", "TC0F", "Tp0P", "Ts0P"] {
                sources.append(ExternalSensorCommand(executable: executable, arguments: ["-k", key, "-r"]))
            }
        }

        for executable in [
            "/opt/homebrew/bin/istats",
            "/usr/local/bin/istats"
        ] where FileManager.default.isExecutableFile(atPath: executable) {
            sources.append(ExternalSensorCommand(executable: executable, arguments: ["cpu", "temp"]))
        }

        return sources
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

    private static func lastDouble(in text: String) -> Double? {
        let pattern = #"(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range)
            .reversed()
            .compactMap { match -> Double? in
                guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
                return Double(text[valueRange])
            }
            .first
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

    init(
        enclosureTemperatureCelsius: Double? = nil,
        cpuTemperatureCelsius: Double? = nil
    ) {
        self.enclosureTemperatureCelsius = enclosureTemperatureCelsius
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
    }

    func fillingMissingValues(from previous: ProcMonitorHardwareMetrics) -> ProcMonitorHardwareMetrics {
        ProcMonitorHardwareMetrics(
            enclosureTemperatureCelsius: enclosureTemperatureCelsius ?? previous.enclosureTemperatureCelsius,
            cpuTemperatureCelsius: cpuTemperatureCelsius ?? previous.cpuTemperatureCelsius
        )
    }

    var enclosureTemperatureText: String {
        temperatureText(enclosureTemperatureCelsius)
    }

    var cpuTemperatureText: String {
        temperatureText(cpuTemperatureCelsius, missing: "受限")
    }

    private func temperatureText(_ value: Double?, missing: String = "--") -> String {
        guard let value else { return missing }
        return "\(Int(value.rounded()))°"
    }
}

private enum AppleSiliconTemperatureReader {
    private typealias EventSystemClient = AnyObject
    private typealias ServiceClient = AnyObject
    private typealias Event = AnyObject
    private typealias CreateClient = @convention(c) (CFAllocator?) -> EventSystemClient?
    private typealias SetMatching = @convention(c) (EventSystemClient?, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (EventSystemClient?) -> CFArray?
    private typealias CopyEvent = @convention(c) (ServiceClient?, Int64, Int32, Int64) -> Event?
    private typealias CopyProperty = @convention(c) (ServiceClient?, CFString) -> CFTypeRef?
    private typealias GetFloatValue = @convention(c) (Event?, Int32) -> Double

    private struct Symbols {
        let createClient: CreateClient
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyEvent: CopyEvent
        let copyProperty: CopyProperty
        let getFloatValue: GetFloatValue
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) ?? dlopen(nil, RTLD_LAZY),
              let createClient = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let getFloatValue = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return nil }

        return Symbols(
            createClient: unsafeBitCast(createClient, to: CreateClient.self),
            setMatching: unsafeBitCast(setMatching, to: SetMatching.self),
            copyServices: unsafeBitCast(copyServices, to: CopyServices.self),
            copyEvent: unsafeBitCast(copyEvent, to: CopyEvent.self),
            copyProperty: unsafeBitCast(copyProperty, to: CopyProperty.self),
            getFloatValue: unsafeBitCast(getFloatValue, to: GetFloatValue.self)
        )
    }()

    static func cpuTemperature(isCPUSensor: (String) -> Bool) -> Double? {
        guard let symbols else { return nil }

        let temperatureEventType: Int64 = 15
        let temperatureField = Int32(temperatureEventType << 16)
        let matching = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 0x0005
        ] as CFDictionary

        guard let client = symbols.createClient(nil),
              symbols.setMatching(client, matching) == 0,
              let services = symbols.copyServices(client)
        else { return nil }

        var cpuValues: [Double] = []
        let count = CFArrayGetCount(services)
        for index in 0..<count {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: ServiceClient.self)
            let name = symbols.copyProperty(service, "Product" as CFString) as? String ?? ""
            guard isCPUSensor(name),
                  let event = symbols.copyEvent(service, temperatureEventType, 0, 0)
            else { continue }

            let value = symbols.getFloatValue(event, temperatureField)
            guard value >= 10, value <= 120 else { continue }
            cpuValues.append(value)
        }

        return cpuValues.max()
    }
}

private struct ExternalSensorCommand {
    let executable: String
    let arguments: [String]
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

// MARK: - VideoLoom recorder panel

private struct VideoLoomIslandPanelView: View {
    let pluginId: String
    let sections: [ExpandedSection]
    @ObservedObject private var arbiter = PluginSlotArbiter.shared

    @State private var shotInProgress = false

    private var isExpanded: Bool { arbiter.stickyPeekExpanded }

    private var statSection: StatSection? {
        sections.compactMap { s -> StatSection? in
            guard case .stat(let stat) = s else { return nil }
            return stat
        }.first
    }

    private var toggleSections: [ActionToggleSection] {
        sections.compactMap { s -> ActionToggleSection? in
            guard case .actionToggle(let t) = s else { return nil }
            return t
        }
    }

    private var buttonSections: [ButtonSection] {
        sections.compactMap { s -> ButtonSection? in
            guard case .button(let b) = s else { return nil }
            return b
        }
    }

    private var textSections: [TextSection] {
        sections.compactMap { s -> TextSection? in
            guard case .text(let t) = s else { return nil }
            return t
        }
    }

    /// The recorder reports the finished state with reveal/dismiss buttons and no
    /// toggles. It gets a dedicated single-row (horizontal) layout.
    private var isFinished: Bool {
        toggleSections.isEmpty && buttonSections.contains { $0.actionId == "dismiss" }
    }

    var body: some View {
        Group {
            if isFinished {
                finishedRow
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            } else {
                recordingPanel
                    .padding(.horizontal, 10)
                    .padding(.vertical, 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.44))
        )
        // Report the whole card's frame so the mouse monitor can tell a tap on the
        // island background (toggles expand) from a click outside it.
        .reportsRecorderButtonFrame(NotchViewModel.recorderPanelFrameKey)
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        .onChange(of: arbiter.recorderShotToken) { _, token in
            // Capture finished — stop the spinner.
            guard token > 0 else { return }
            shotInProgress = false
        }
    }

    /// Begin the screenshot spinner; a safety timeout clears it if no result comes.
    private func beginShot() {
        shotInProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            shotInProgress = false
        }
    }

    /// Single row: status tag + timer + primary controls (pause / mic / camera /
    /// stop). Tapping the row expands it to reveal the auxiliary tools (annotate /
    /// screenshot); tapping again collapses.
    private var recordingPanel: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)
            statCluster
            Spacer(minLength: 0).frame(maxWidth: 14)
            controlButtons
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { arbiter.stickyPeekExpanded.toggle() }
    }

    @ViewBuilder
    private var statCluster: some View {
        if let stat = statSection {
            HStack(spacing: 5) {
                // Combined status tag — the colored indicator + label ("录制中" /
                // "已暂停") as one pill, to the LEFT of the timer.
                HStack(spacing: 3) {
                    if let icon = stat.icon {
                        IslandPluginRenderer.iconView(icon, size: 8)
                    }
                    Text(stat.label)
                        .font(.system(size: 8.5, weight: .semibold))
                }
                .foregroundStyle(IslandPluginRenderer.tintColor(stat.tint))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(IslandPluginRenderer.tintColor(stat.tint).opacity(0.16))
                )

                // Live timer. With startedAt the island renders a SwiftUI timer
                // locally so the sections JSON never changes on each tick (no
                // re-layout → stable button hit-test).
                if let startedAt = stat.startedAt {
                    Text(
                        timerInterval: Date(timeIntervalSince1970: startedAt)...Date.distantFuture,
                        countsDown: false
                    )
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    // Reserve width for "10:00:00" (8 chars) so the layout never
                    // shifts at any format boundary (10 min / 1 h / 10 h).
                    .frame(minWidth: 60)
                } else {
                    Text(stat.value)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(minWidth: 60)
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var controlButtons: some View {
        // Always in the peek bar: the primary recording controls.
        if let pause = toggleSections.first(where: { $0.actionId == "togglePause" }) {
            peekIconButton(icon: toggleIcon(pause), tint: pause.active ? .green : .default,
                           actionId: pause.actionId, help: pause.label)
        }
        if let mic = toggleSections.first(where: { $0.actionId == "toggleMic" }) {
            peekIconButton(icon: toggleIcon(mic), tint: mic.active ? .green : .default,
                           actionId: mic.actionId, help: mic.label)
        }
        if let camera = toggleSections.first(where: { $0.actionId == "toggleCamera" }) {
            peekIconButton(icon: toggleIcon(camera), tint: camera.active ? .green : .default,
                           actionId: camera.actionId, help: camera.label)
        }
        // Auxiliary tools live behind the expand tap: annotate + screenshot.
        if isExpanded {
            if let annotate = toggleSections.first(where: { $0.actionId == "toggleAnnotate" }) {
                peekIconButton(icon: toggleIcon(annotate), tint: annotate.active ? .green : .default,
                               actionId: annotate.actionId, help: annotate.label)
            }
            if let shot = buttonSections.first(where: { $0.actionId == "screenshot" }) {
                peekIconButton(icon: "camera.fill", tint: .default,
                               actionId: shot.actionId, help: shot.label,
                               loading: shotInProgress,
                               onTap: { beginShot() })
            }
        }
        if let stop = buttonSections.first(where: { $0.actionId == "stop" }) {
            peekIconButton(icon: "stop.fill", tint: .red, actionId: stop.actionId, help: stop.label)
        }
    }

    // MARK: - Finished (horizontal: 已保存 + 打开文件夹 + 完成)

    private var finishedRow: some View {
        HStack(spacing: 8) {
            if let stat = statSection {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandPluginRenderer.tintColor(.green))
                    Text(stat.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .fixedSize()
            }

            if let name = textSections.first?.content {
                Text(name)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 6)

            ForEach(Array(buttonSections.enumerated()), id: \.offset) { _, button in
                finishedButton(button)
            }
        }
        .padding(.vertical, 2)
    }

    private func finishedButton(_ button: ButtonSection) -> some View {
        let isDismiss = button.actionId == "dismiss"
        let tint: PluginTint = isDismiss ? .green : .blue
        let label = isDismiss ? "完成" : "打开"
        // Visual only — dispatched by the mouse monitor (handleRecorderClick).
        return Button {
        } label: {
            HStack(spacing: 4) {
                Image(systemName: buttonIcon(button))
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .fixedSize()
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(height: 27)
            .background(
                Capsule().fill(IslandPluginRenderer.tintColor(tint).opacity(isDismiss ? 0.28 : 0.16))
            )
        }
        .buttonStyle(.plain)
        .reportsRecorderButtonFrame(button.actionId)
    }

    private func peekIconButton(icon: String, tint: PluginTint, actionId: String, help: String,
                                loading: Bool = false, onTap: (() -> Void)? = nil) -> some View {
        // Visual only — the click is dispatched by the mouse monitor's coordinate
        // hit-test (handleRecorderClick), since the click-through peek window doesn't
        // reliably deliver clicks to SwiftUI buttons (non-activating panel). onTap
        // drives the local screenshot spinner if SwiftUI registers the press.
        Button {
            onTap?()
        } label: {
            Group {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.85))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tint == .default ? .white.opacity(0.85) : IslandPluginRenderer.tintColor(tint))
                }
            }
            .frame(width: 15, height: 15)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint == .default ? .white.opacity(0.08) : IslandPluginRenderer.tintColor(tint).opacity(0.16))
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .reportsRecorderButtonFrame(actionId)
    }

    private func toggleIcon(_ toggle: ActionToggleSection) -> String {
        switch toggle.actionId {
        case "togglePause": return toggle.active ? "play.fill" : "pause.fill"
        case "toggleMic": return toggle.active ? "mic.fill" : "mic.slash.fill"
        case "toggleCamera": return toggle.active ? "video.fill" : "video.slash.fill"
        case "toggleAnnotate": return toggle.active ? "pencil.tip" : "pencil.tip.crop.circle"
        default: return "circle.fill"
        }
    }

    private func buttonIcon(_ button: ButtonSection) -> String {
        switch button.actionId {
        case "stop": return "stop.fill"
        case "screenshot": return "camera.fill"
        case "revealFile": return "folder.fill"
        case "dismiss": return "checkmark.circle.fill"
        default: return "circle.fill"
        }
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
