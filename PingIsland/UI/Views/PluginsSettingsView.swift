import SwiftUI

struct PluginsSettingsView: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var host = PluginHost.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if registry.installedPlugins.isEmpty {
                emptyCard
            } else {
                pluginsCard
            }

            // Footer
            HStack {
                Button {
                    NSWorkspace.shared.open(PluginRegistry.defaultPluginsDirectoryURL)
                } label: {
                    Label("打开插件文件夹", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    PluginRegistry.shared.rescan()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cards

    private var emptyCard: some View {
        pluginCard {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有已安装的插件")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text("将 .pingplugin 文件放入插件文件夹即可安装")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private var pluginsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(registry.installedPlugins) { plugin in
                singlePluginCard(plugin)
            }
        }
    }

    private func singlePluginCard(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header: plugin name as title
            Text(plugin.manifest.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            pluginCard {
                // Main info row
                HStack(alignment: .center, spacing: 12) {
                    pluginIcon(plugin)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(plugin.manifest.version)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            if plugin.manifest.isBuiltIn {
                                capsuleBadge("内置", color: .secondary)
                            }

                            if case .failed(let reason) = host.processStates[plugin.id] {
                                capsuleBadge("崩溃", color: .red, fill: true)
                                    .help(reason)
                            }

                            // Slot badges
                            ForEach(plugin.manifest.slots, id: \.rawValue) { slot in
                                capsuleBadge(slot.displayName, color: .secondary)
                            }
                        }

                        if let desc = plugin.manifest.description {
                            Text(desc)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if plugin.manifest.isBuiltIn {
                        Text("始终开启")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { registry.isEnabled(plugin.id) },
                            set: { registry.setEnabled($0, for: plugin.id) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                // Hook status row
                if let profile = hookProfile(for: plugin.id) {
                    configDivider()
                    hookStatusRow(profile: profile)
                }

                // Approval routing row
                if let routeBinding = approvalRouteBinding(for: plugin.id) {
                    configDivider()
                    approvalRouteRow(isOn: routeBinding)
                }

                // Usage plugin auth config
                if plugin.id == "com.wudanwu.pingisland.usage" {
                    configDivider()
                    UsagePluginAuthView()
                }
            }
        }
    }

    // MARK: - Config Sub-rows

    private func hookStatusRow(profile: ManagedHookClientProfile) -> some View {
        let installed = HookInstaller.isInstalled(profile)
        return HStack(spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(installed ? Color.green : Color.orange)
                .frame(width: 16)

            Text(installed ? "Hook 已安装" : "Hook 未安装")
                .font(.system(size: 11))
                .foregroundStyle(installed ? Color.secondary : Color.orange)

            Spacer()

            if !installed {
                Button("安装") { HookInstaller.install(profile) }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    private func approvalRouteRow(isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text("审批与提问保留在终端")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Helpers

    private func approvalRouteBinding(for pluginId: String) -> Binding<Bool>? {
        switch pluginId {
        case "com.wudanwu.pingisland.claude": return $settings.claudeRoutePromptsToTerminal
        case "com.wudanwu.pingisland.codex":  return $settings.codexRoutePromptsToTerminal
        default: return nil
        }
    }

    private func hookProfile(for pluginId: String) -> ManagedHookClientProfile? {
        let profileId: String
        switch pluginId {
        case "com.wudanwu.pingisland.claude": profileId = "claude-hooks"
        case "com.wudanwu.pingisland.codex":  profileId = "codex-hooks"
        default: return nil
        }
        return ClientProfileRegistry.managedHookProfiles.first { $0.id == profileId }
    }

    @ViewBuilder
    private func capsuleBadge(_ text: String, color: Color, fill: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(fill ? .white : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill ? color : color.opacity(0.14), in: Capsule())
    }

    private func configDivider() -> some View {
        Divider()
            .background(Color.white.opacity(0.05))
            .padding(.leading, 14)
    }

    @ViewBuilder
    private func pluginIcon(_ plugin: InstalledPlugin) -> some View {
        if let iconPath = plugin.manifest.iconPath,
           let image = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            let meta = pluginIconMeta(for: plugin.manifest.id)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [meta.color.opacity(0.85), meta.color.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: meta.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Returns a stable SF Symbol + color for a plugin ID.
    private func pluginIconMeta(for pluginId: String) -> (symbol: String, color: Color) {
        switch pluginId {
        case "com.wudanwu.pingisland.claude":
            return ("brain.head.profile", Color(red: 0.55, green: 0.36, blue: 0.96))
        case "com.wudanwu.pingisland.codex":
            return ("terminal.fill", Color(red: 0.18, green: 0.72, blue: 0.45))
        default:
            // Derive a stable color from the plugin ID hash
            let palette: [(String, Color)] = [
                ("puzzlepiece.extension.fill", Color(red: 0.20, green: 0.60, blue: 0.90)),
                ("puzzlepiece.extension.fill", Color(red: 0.95, green: 0.55, blue: 0.20)),
                ("puzzlepiece.extension.fill", Color(red: 0.85, green: 0.25, blue: 0.45)),
                ("puzzlepiece.extension.fill", Color(red: 0.30, green: 0.75, blue: 0.65)),
                ("puzzlepiece.extension.fill", Color(red: 0.70, green: 0.40, blue: 0.90)),
            ]
            let index = abs(pluginId.hashValue) % palette.count
            return palette[index]
        }
    }

    // MARK: - Card container (matches SettingsSectionCard style)

    @ViewBuilder
    private func pluginCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
