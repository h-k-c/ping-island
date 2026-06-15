import Security
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

            // One card per user-facing island tool. Core session monitors subscribe
            // to hookEvent internally, but they are product defaults rather than
            // configurable plugins.
            ForEach(visiblePlugins) { plugin in
                pluginCard(plugin)
            }

            if visiblePlugins.isEmpty {
                emptyCard
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

    // MARK: - Slot Assignment

    private var slotAssignmentCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("槽位分配")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

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
        HStack(spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(side).font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("", selection: assignment) {
                Text("不显示").tag(Optional<String>.none)
                ForEach(plugins, id: \.id) { p in
                    Text(p.manifest.name).tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Plugin Card

    private func pluginCard(_ plugin: InstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card title = plugin name
            Text(plugin.manifest.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            card {
                // Header row
                pluginHeaderRow(plugin)

                // Config items (always rendered uniformly)
                if !plugin.manifest.configItems.isEmpty {
                    rowDivider()
                    ForEach(Array(plugin.manifest.configItems.enumerated()), id: \.offset) { idx, item in
                        if idx > 0 { rowDivider() }
                        PluginConfigItemView(plugin: plugin, item: item)
                    }
                }
            }
        }
    }

    private func pluginHeaderRow(_ plugin: InstalledPlugin) -> some View {
        HStack(alignment: .center, spacing: 12) {
            pluginIcon(plugin).frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                // Name row with status badges
                HStack(spacing: 6) {
                    Text(plugin.manifest.version)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    if plugin.manifest.isBuiltIn {
                        badge("内置", color: .secondary)
                    }
                    if case .failed(let r) = host.processStates[plugin.id] {
                        badge("崩溃", color: .red, filled: true).help(r)
                    }
                }

                // Description
                if let desc = plugin.manifest.description {
                    Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                }

                // Slot badges
                if !plugin.manifest.slots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(plugin.manifest.slots, id: \.rawValue) { slot in
                            badge(slot.displayName, color: .secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            // Toggle / always-on
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
    }

    // MARK: - Empty state

    private var emptyCard: some View {
        card {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有已安装的插件")
                    .font(.system(size: 13, weight: .medium))
                Text("将 .pingplugin 文件放入插件文件夹即可安装")
                    .font(.system(size: 11))
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
        registry.installedPlugins.filter { p in
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    /// Returns icon symbol + color from manifest.icon if declared, otherwise falls back to hash palette.
    /// Zero hardcoding for specific plugin IDs.
    private func iconMeta(for manifest: PluginManifest) -> (symbol: String, color: Color) {
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
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
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

private extension PluginManifest {
    var isCoreSessionMonitor: Bool {
        isBuiltIn && subscribesTo.contains("hookEvent")
    }
}

struct RealtimeNotificationsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

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
                    .font(.system(size: 13, weight: .medium))
                Text("安装默认 Hooks 后，Claude、Codex 等会话源会显示在这里")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func realtimeNotificationRow(_ source: ManagedHookClientProfile) -> some View {
        HStack(spacing: 10) {
            RealtimeSourceIcon(profile: source)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("通知时左耳来源图标")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { settings.realtimeNotificationIconStyle(for: source.id) },
                set: { settings.setRealtimeNotificationIconStyle($0, for: source.id) }
            )) {
                ForEach(RealtimeNotificationIconStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

private struct RealtimeSourceIcon: View {
    let profile: ManagedHookClientProfile

    var body: some View {
        if let logoAssetName = preferredLogoAssetName {
            Image(logoAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else if let resolvedAppIcon {
            Image(nsImage: resolvedAppIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: profile.iconSymbolName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(profile.brand.tintColor.opacity(0.22))
                )
        }
    }

    private var resolvedAppIcon: NSImage? {
        ClientAppLocator.icon(bundleIdentifiers: profile.localAppBundleIdentifiers)
    }

    private var preferredLogoAssetName: String? {
        guard let logoAssetName = profile.logoAssetName else { return nil }
        return profile.prefersBundledLogoOverAppIcon || resolvedAppIcon == nil
            ? logoAssetName
            : nil
    }
}

// MARK: - Config Item View (manifest-driven)

private struct PluginConfigItemView: View {
    let plugin: InstalledPlugin
    let item: PluginConfigItem

    @State private var secretInput = ""
    @State private var showInput = false
    @State private var isStored = false
    @State private var infoExists = false

    var body: some View {
        Group {
            switch item.type {
            case .info:     infoRow
            case .secret:   secretRow
            case .toggle:   toggleRow
            case .text:     textRow
            case .number:   numberRow
            case .select:   selectRow
            case .array:    arrayRow
            case .time:     timeRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
        .onAppear { refreshState() }
    }

    // MARK: - Row types

    private var infoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: infoExists || hookInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(infoExists || hookInstalled ? Color.green : Color.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).font(.system(size: 11)).foregroundStyle(.primary)
                if let hint = item.hint, !hookInstalled && item.infoPath == nil {
                    Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let _ = item.hint, !hookInstalled, item.infoPath == nil {
                Button("安装") { installHook() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var secretRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isStored ? "checkmark.circle.fill" : "key.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isStored ? Color.green : Color.orange)
                    .frame(width: 16)
                Text(item.label).font(.system(size: 11)).foregroundStyle(.primary)
                Spacer()
                if isStored {
                    Button("重置") { deleteSecret(); showInput = false }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.red.opacity(0.8))
                } else {
                    Button(showInput ? "取消" : "设置") { showInput.toggle(); secretInput = "" }
                        .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.blue)
                }
            }
            if !isStored && !showInput, let hint = item.hint {
                Text(hint).font(.system(size: 9)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            if showInput {
                HStack(spacing: 6) {
                    SecureField("粘贴…", text: $secretInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    Button("保存") { saveSecret(secretInput.trimmingCharacters(in: .whitespaces)); showInput = false; secretInput = "" }
                        .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(.blue)
                        .disabled(secretInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var toggleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(item.label).font(.system(size: 11)).foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: approvalBinding)
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }

    private var textRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(item.label).font(.system(size: 11))
            Spacer()
            TextField(item.hint ?? "", text: storedTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: 160)
                .padding(4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var numberRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(item.label).font(.system(size: 11))
            if let unit = item.unit {
                Text(unit).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            TextField("", text: storedTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 60)
                .padding(4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .multilineTextAlignment(.trailing)
        }
    }

    private var selectRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(item.label).font(.system(size: 11))
            Spacer()
            Picker("", selection: storedTextBinding) {
                Text("请选择").tag("")
                ForEach(item.options ?? [], id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140)
        }
    }

    private var arrayRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.number")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(item.label).font(.system(size: 11))
                Spacer()
                Button("编辑") { showInput.toggle() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.blue)
            }
            if showInput {
                Text("多个值用换行分隔")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                TextEditor(text: storedTextBinding)
                    .font(.system(size: 11))
                    .frame(height: 60)
                    .padding(4)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private var timeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(item.label).font(.system(size: 11))
            Spacer()
            TextField("HH:mm", text: storedTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 55)
                .padding(4)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helpers

    /// Binding for non-secret text/number/select/array/time stored in UserDefaults.
    /// Automatically pushes config/update to running plugin on change.
    private var storedTextBinding: Binding<String> {
        let pluginId = plugin.id
        let key = item.key
        let storageKey = "\(pluginId).\(key)"
        return Binding(
            get: { UserDefaults.standard.string(forKey: storageKey) ?? item.defaultValue ?? "" },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: storageKey)
                Task { @MainActor in
                    await PluginHost.shared.notifyConfigUpdate(
                        pluginId: pluginId, key: key, value: newValue)
                }
            }
        )
    }

    /// Generic toggle binding backed by PluginStorage — no hardcoded plugin IDs.
    /// Falls back to AppSettings for legacy approval routing keys.
    private var approvalBinding: Binding<Bool> {
        let pluginId = plugin.id
        let key = item.key
        let storageKey = "\(pluginId).\(key)"
        return Binding(
            get: {
                if let stored = UserDefaults.standard.object(forKey: storageKey) as? Bool {
                    return stored
                }
                return item.defaultValue == "true"
            },
            set: { newValue in
                UserDefaults.standard.set(newValue, forKey: storageKey)
                Task { @MainActor in
                    await PluginHost.shared.notifyConfigUpdate(
                        pluginId: pluginId, key: key, value: newValue)
                }
            }
        )
    }

    /// Check hook install status using infoHookId first, then hint (backward compat).
    private var hookInstalled: Bool {
        let profileId = item.infoHookId ?? item.hint
        guard let profileId,
              let profile = ClientProfileRegistry.managedHookProfiles.first(where: { $0.id == profileId })
        else { return false }
        return HookInstaller.isInstalled(profile)
    }

    private func installHook() {
        let profileId = item.infoHookId ?? item.hint
        guard let profileId,
              let profile = ClientProfileRegistry.managedHookProfiles.first(where: { $0.id == profileId })
        else { return }
        HookInstaller.install(profile)
    }

    private func refreshState() {
        isStored = loadSecret() != nil
        if let path = item.infoPath {
            infoExists = FileManager.default.fileExists(
                atPath: (NSHomeDirectory() as NSString).appendingPathComponent(path))
        }
    }

    private var keychainKey: String { "\(plugin.id).\(item.key)" }

    private func loadSecret() -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrAccount: keychainKey as CFString,
                                   kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess,
              let d = r as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    private func saveSecret(_ value: String) {
        guard !value.isEmpty else { return }
        let del: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrAccount: keychainKey as CFString]
        SecItemDelete(del as CFDictionary)
        // For claudeSessionKey, also save with the legacy key ClaudeAPIService expects
        let legacyKey = item.key
        if legacyKey != keychainKey {
            let delLegacy: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                               kSecAttrAccount: legacyKey as CFString]
            SecItemDelete(delLegacy as CFDictionary)
            let addLegacy: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                               kSecAttrAccount: legacyKey as CFString,
                                               kSecValueData: value.data(using: .utf8)!,
                                               kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            SecItemAdd(addLegacy as CFDictionary, nil)
        }
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                     kSecAttrAccount: keychainKey as CFString,
                                     kSecValueData: value.data(using: .utf8)!,
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(add as CFDictionary, nil)
        isStored = true
        // Push config/update so the running plugin gets the new value
        let pid = plugin.id; let k = item.key
        Task { @MainActor in
            await PluginHost.shared.notifyConfigUpdate(pluginId: pid, key: k, value: value)
        }
    }

    private func deleteSecret() {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                   kSecAttrAccount: keychainKey as CFString]
        SecItemDelete(q as CFDictionary)
        isStored = false
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
