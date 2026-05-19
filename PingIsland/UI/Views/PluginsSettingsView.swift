import SwiftUI

struct PluginsSettingsView: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var host = PluginHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if registry.installedPlugins.isEmpty {
                emptyState
            } else {
                pluginList
            }

            Divider()
                .padding(.vertical, 8)

            HStack {
                Button("打开插件文件夹") {
                    NSWorkspace.shared.open(PluginRegistry.defaultPluginsDirectoryURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                Button("刷新") {
                    PluginRegistry.shared.rescan()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("没有已安装的插件")
                .font(.headline)
            Text("将 .pingplugin 文件放入插件文件夹即可安装。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var pluginList: some View {
        VStack(spacing: 0) {
            ForEach(registry.installedPlugins) { plugin in
                pluginRow(plugin)
                Divider().padding(.leading, 52)
            }
        }
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        HStack(spacing: 12) {
            pluginIcon(plugin)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(plugin.manifest.version)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if plugin.manifest.isBuiltIn {
                        Text("内置")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }

                    // Only show badge for non-ready states
                    if case .failed(let reason) = host.processStates[plugin.id] {
                        Text("崩溃")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .help(reason)
                    } else if host.processStates[plugin.id] == nil, !plugin.manifest.isBuiltIn {
                        Text("未启动")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.12), in: Capsule())
                    }
                }

                if !plugin.manifest.slots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(plugin.manifest.slots, id: \.rawValue) { slot in
                            Text(slot.displayName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }

                if let desc = plugin.manifest.description {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if plugin.manifest.isBuiltIn {
                Text("始终开启")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Toggle("", isOn: Binding(
                    get: { registry.isEnabled(plugin.id) },
                    set: { registry.setEnabled($0, for: plugin.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func pluginIcon(_ plugin: InstalledPlugin) -> some View {
        if let iconPath = plugin.manifest.iconPath,
           let image = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }
}
