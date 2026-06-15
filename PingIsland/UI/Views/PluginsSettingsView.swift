import SwiftUI

struct PluginsSettingsView: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var host = PluginHost.shared
    @ObservedObject private var arbiter = PluginSlotArbiter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Slot assignment — always at top
            if !compactCapablePlugins.isEmpty {
                slotAssignmentCard
            }

            if !visiblePlugins.isEmpty {
                toolsListCard
            }

            if visiblePlugins.isEmpty {
                emptyCard
            }

            // Footer
            VStack(alignment: .leading, spacing: 7) {
                Text("默认工具和第三方插件都会从这个文件夹加载。")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack {
                Button {
                    NSWorkspace.shared.open(PluginRegistry.defaultPluginsDirectoryURL)
                } label: {
                    Label("打开用户插件文件夹", systemImage: "folder")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    PluginRegistry.shared.rescan()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Slot Assignment

    private var slotAssignmentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("槽位分配")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 8)

            card {
                slotRow(side: "右耳", image: "arrow.right.circle",
                        assignment: Binding(get: { arbiter.rightEarAssignment },
                                           set: { arbiter.rightEarAssignment = $0 }),
                        plugins: compactCapablePlugins)
                rowDivider()
                slotRow(side: "左耳", image: "arrow.left.circle",
                        assignment: Binding(get: { arbiter.leftEarAssignment },
                                           set: { arbiter.leftEarAssignment = $0 }),
                        plugins: compactCapablePlugins)
            }
        }
    }

    private func slotRow(side: String, image: String,
                         assignment: Binding<String?>,
                         plugins: [InstalledPlugin]) -> some View {
        let selectedPlugin = plugins.first { $0.id == assignment.wrappedValue }

        return HStack(spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(side)
                .font(.system(size: 11, weight: .medium))
            Spacer()
            if let selectedPlugin {
                pluginIcon(selectedPlugin)
                    .frame(width: 20, height: 20)
            }
            Picker("", selection: assignment) {
                Text("不显示").tag(Optional<String>.none)
                ForEach(plugins, id: \.id) { p in
                    Text(p.manifest.name).tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(.system(size: 11, weight: .semibold))
            .controlSize(.small)
            .frame(maxWidth: 126)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Plugin List

    private var toolsListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("岛上工具")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 8)

            card {
                ForEach(Array(visiblePlugins.enumerated()), id: \.element.id) { index, plugin in
                    if index > 0 { rowDivider() }
                    pluginRow(plugin)
                }
            }
        }
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        HStack(alignment: .center, spacing: 10) {
            pluginIcon(plugin).frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(plugin.manifest.name)
                        .font(.system(size: 10.8, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(plugin.manifest.version)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    if plugin.manifest.isBuiltIn {
                        badge("内置", color: .secondary)
                    }
                    if case .failed(let r) = host.processStates[plugin.id] {
                        badge("崩溃", color: .red, filled: true).help(r)
                    }
                }

                if let desc = plugin.manifest.description {
                    Text(desc)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !plugin.manifest.slots.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(plugin.manifest.slots, id: \.rawValue) { slot in
                            badge(slot.displayName, color: .secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Empty state

    private var emptyCard: some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有已安装的插件")
                    .font(.system(size: 12, weight: .medium))
                Text("将 .pingplugin 文件放入插件文件夹即可安装")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Helpers

    /// Plugins shown as configurable cards.
    private var visiblePlugins: [InstalledPlugin] {
        registry.installedPlugins.filter { !$0.manifest.isCoreSessionMonitor }
    }

    /// Plugins that can render a compact ear, regardless of the specific side
    /// they declare. Both ears can be assigned any of these — the user's choice
    /// decides placement (see PluginSlotArbiter), not the plugin's declared side.
    private var compactCapablePlugins: [InstalledPlugin] {
        visiblePlugins.filter { p in
            p.manifest.slots.contains { $0 == .compactLeft || $0 == .compactRight || $0 == .compact }
        }
    }

    @ViewBuilder
    private func pluginIcon(_ plugin: InstalledPlugin) -> some View {
        // Priority: iconPath (file) > manifest.icon (self-declared) > fallback hash palette
        if let iconPath = plugin.manifest.iconPath,
           let img = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            let meta = iconMeta(for: plugin.manifest)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [meta.color.opacity(0.85), meta.color.opacity(0.55)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: meta.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Returns icon symbol + color from manifest.icon if declared, otherwise falls back to hash palette.
    /// Zero hardcoding for specific plugin IDs.
    private func iconMeta(for manifest: PluginManifest) -> (symbol: String, color: Color) {
        switch manifest.id {
        case "com.example.weatherdemo":
            return ("sun.max.fill", Color(red: 1.0, green: 0.62, blue: 0.16))
        case "com.wudanwu.pingisland.procmonitor":
            return ("cpu.fill", Color(red: 0.22, green: 0.82, blue: 0.52))
        case "com.wudanwu.pingisland.usage":
            return ("chart.xyaxis.line", Color(red: 0.32, green: 0.62, blue: 0.96))
        default:
            break
        }

        if let decl = manifest.icon {
            let color = Color(hex: decl.color) ?? Color(red: 0.4, green: 0.4, blue: 0.9)
            return (decl.sfSymbol, color)
        }
        // Fallback: deterministic color from plugin ID hash
        let palette: [(String, Color)] = [
            ("puzzlepiece.extension.fill", Color(red: 0.20, green: 0.60, blue: 0.90)),
            ("puzzlepiece.extension.fill", Color(red: 0.95, green: 0.55, blue: 0.20)),
            ("puzzlepiece.extension.fill", Color(red: 0.85, green: 0.25, blue: 0.45)),
            ("puzzlepiece.extension.fill", Color(red: 0.30, green: 0.75, blue: 0.65)),
            ("puzzlepiece.extension.fill", Color(red: 0.70, green: 0.40, blue: 0.90)),
        ]
        return palette[abs(manifest.id.hashValue) % palette.count]
    }

    private func badge(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 8.2, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
    }

    private func rowDivider() -> some View {
        Divider().background(Color.white.opacity(0.05)).padding(.leading, 12)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension PluginManifest {
    var isCoreSessionMonitor: Bool {
        isBuiltIn && subscribesTo.contains("hookEvent")
    }
}

struct RealtimeNotificationsSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if realtimeNotificationSources.isEmpty {
                emptyCard
            } else {
                sourceCard
            }
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("实时通知源")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 8)

            card {
                ForEach(Array(realtimeNotificationSources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { rowDivider() }
                    realtimeNotificationRow(source)
                }
            }
        }
    }

    private var emptyCard: some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有实时通知源")
                    .font(.system(size: 12, weight: .medium))
                Text("安装默认 Hooks 后，Claude、Codex 等会话源会显示在这里")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func realtimeNotificationRow(_ source: ManagedHookClientProfile) -> some View {
        HStack(spacing: 10) {
            RealtimeSourceMascotIcon(profile: source)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("默认来源宠物")
                    .font(.system(size: 9.4))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var realtimeNotificationSources: [ManagedHookClientProfile] {
        ClientProfileRegistry.managedHookProfiles.filter(\.alwaysVisibleInSettings)
    }

    private func rowDivider() -> some View {
        Divider().background(Color.white.opacity(0.05)).padding(.leading, 14)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct RealtimeSourceMascotIcon: View {
    @ObservedObject private var settings = AppSettings.shared
    let profile: ManagedHookClientProfile

    var body: some View {
        MascotView(
            kind: settings.mascotKind(for: mascotClient),
            status: .idle,
            size: 25
        )
    }

    private var mascotClient: MascotClient {
        switch profile.brand {
        case .claude:
            return .claude
        case .codebuddy:
            return .codebuddy
        case .codex:
            return .codex
        case .gemini:
            return .gemini
        case .hermes:
            return .hermes
        case .qwen:
            return .qwen
        case .opencode:
            return .opencode
        case .qoder:
            return .qoder
        case .copilot:
            return .copilot
        case .kimi:
            return .kimi
        case .neutral:
            if profile.id.contains("openclaw") {
                return .openclaw
            }
            return .claude
        }
    }
}

// MARK: - Color from hex string

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8)  & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}
