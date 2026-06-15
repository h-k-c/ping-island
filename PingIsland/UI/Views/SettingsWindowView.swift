import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case display
    case realtimeNotifications
    case plugins
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .display: return "显示"
        case .realtimeNotifications: return "实时通知"
        case .plugins: return "插件"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "基础行为"
        case .display: return "显示方式"
        case .realtimeNotifications: return "会话来源"
        case .plugins: return "岛上工具"
        case .about: return "版本与更新"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .display: return "rectangle.on.rectangle"
        case .realtimeNotifications: return "bell.badge.fill"
        case .plugins: return "puzzlepiece.extension.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.12, green: 0.42, blue: 0.95)
        case .display: return Color(red: 0.46, green: 0.40, blue: 0.96)
        case .realtimeNotifications: return Color(red: 0.20, green: 0.68, blue: 0.92)
        case .plugins: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .about: return Color(red: 0.17, green: 0.60, blue: 0.96)
        }
    }

    static var visibleCategories: [SettingsCategory] {
        [.general, .display, .realtimeNotifications, .plugins, .about]
    }
}

struct QoderCLIHookRefreshNoticeGate {
    private static let defaultsKey = "SettingsPanel.qoderCLIHookRefreshNoticeShown.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func consumeShouldShowNotice() -> Bool {
        guard !defaults.bool(forKey: Self.defaultsKey) else {
            return false
        }

        defaults.set(true, forKey: Self.defaultsKey)
        return true
    }
}


enum AccessibilityPermissionStatus {
#if APP_STORE
    static let isAvailable = false

    static func isTrusted(prompt: Bool = false) -> Bool {
        false
    }
#else
    static let isAvailable = true

    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }
#endif
}

@MainActor
final class SettingsPanelViewModel: ObservableObject {
    struct HookReinstallFeedback: Equatable {
        let message: String
        let isError: Bool
    }

    @Published var launchAtLogin = false
    @Published private(set) var hookInstallationStates: [String: Bool] = [:]
    @Published private(set) var ideExtensionInstallationStates: [String: Bool] = [:]
    @Published var accessibilityEnabled = false
    @Published var isExportingLogs = false
    @Published var logExportStatus = AppLocalization.string("导出最近 10 分钟的 Island 诊断日志与配置")
    @Published private(set) var reinstallingHookProfileID: String?
    @Published private(set) var customHookInstallations: [HookInstaller.CustomHookInstallation] = []
    @Published private(set) var qoderCLIHookRefreshStatus: HookInstaller.QoderCLIHookRefreshStatus?
    @Published private(set) var qoderCLIHookRefreshNoticeStatus: HookInstaller.QoderCLIHookRefreshStatus?
    @Published private(set) var bridgeHealthStatus = HookInstaller.BridgeHealthStatus(
        isHealthy: false,
        message: AppLocalization.string("Bridge 链路尚未检测")
    )

    private var hookFeedbackClearTasks: [String: Task<Void, Never>] = [:]
    private let qoderCLIHookRefreshStatusProvider: @MainActor () -> HookInstaller.QoderCLIHookRefreshStatus?
    private let qoderCLIHookRefreshNoticeGate: QoderCLIHookRefreshNoticeGate
    private let accessibilityStatusProvider: @MainActor (_ prompt: Bool) -> Bool
    private let accessibilitySettingsOpener: @MainActor () -> Void

    init(
        qoderCLIHookRefreshStatusProvider: @escaping @MainActor () -> HookInstaller.QoderCLIHookRefreshStatus? = {
            HookInstaller.qoderCLIHookRefreshStatus()
        },
        qoderCLIHookRefreshNoticeDefaults: UserDefaults = .standard,
        accessibilityStatusProvider: @escaping @MainActor (_ prompt: Bool) -> Bool = { prompt in
            AccessibilityPermissionStatus.isTrusted(prompt: prompt)
        },
        accessibilitySettingsOpener: @escaping @MainActor () -> Void = {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    ) {
        self.qoderCLIHookRefreshStatusProvider = qoderCLIHookRefreshStatusProvider
        qoderCLIHookRefreshNoticeGate = QoderCLIHookRefreshNoticeGate(
            defaults: qoderCLIHookRefreshNoticeDefaults
        )
        self.accessibilityStatusProvider = accessibilityStatusProvider
        self.accessibilitySettingsOpener = accessibilitySettingsOpener
    }



    func refreshInitialState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshAccessibilityStatus()
        refreshLocalizedState()
    }

    func refresh(for category: SettingsCategory) {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshAccessibilityStatus()
        refreshLocalizedState()

        switch category {
        case .display:
            ScreenSelector.shared.refreshScreens()
        case .general, .realtimeNotifications, .plugins, .about:
            break
        }
    }

    func refreshAccessibilityStatus() {
        guard AccessibilityPermissionStatus.isAvailable else {
            accessibilityEnabled = false
            return
        }

        accessibilityEnabled = accessibilityStatusProvider(false)
    }

    func refreshLocalizedState() {
        guard !isExportingLogs else { return }
        logExportStatus = AppLocalization.string("导出最近 10 分钟的 Island 诊断日志与配置")
    }

    func refreshQoderCLIHookRefreshStatus() {
        let status = qoderCLIHookRefreshStatusProvider()
        qoderCLIHookRefreshStatus = status

        guard let status else {
            qoderCLIHookRefreshNoticeStatus = nil
            return
        }

        if qoderCLIHookRefreshNoticeStatus != nil {
            return
        }

        guard qoderCLIHookRefreshNoticeGate.consumeShouldShowNotice() else {
            qoderCLIHookRefreshNoticeStatus = nil
            return
        }

        qoderCLIHookRefreshNoticeStatus = status
    }


    func refreshBridgeHealthStatus() {
        bridgeHealthStatus = HookInstaller.bridgeHealthStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func isHookInstalled(_ profile: ManagedHookClientProfile) -> Bool {
        hookInstallationStates[profile.id] ?? false
    }





    func currentHookSelection(for profile: ManagedHookClientProfile) -> HookInstallSelection {
        HookInstaller.loadSelection(for: profile)
    }



    func installCustomHook(profileID: String, directoryPath: String) {
        HookInstaller.installCustom(profileID: profileID, directoryPath: directoryPath)
    }


    func uninstallAllHooks() {
#if APP_STORE
        guard HookInstaller.uninstallAllWithUserAuthorization() else {
            return
        }
#else
        HookInstaller.uninstall()
#endif
        for installation in HookInstaller.customInstallations() {
            HookInstaller.uninstallCustom(id: installation.id)
        }
        refreshBridgeHealthStatus()
    }


    func openHookConfigurationDirectory(for profile: ManagedHookClientProfile) {
        guard let directoryURL = hookConfigurationDirectoryURL(for: profile) else {
            return
        }

        NSWorkspace.shared.open(directoryURL)
    }








    func openAccessibilitySettings() {
        guard AccessibilityPermissionStatus.isAvailable else {
            accessibilityEnabled = false
            return
        }

        accessibilityEnabled = accessibilityStatusProvider(true)
        if !accessibilityEnabled {
            accessibilitySettingsOpener()
        }
    }

    func exportLogs() {
        guard !isExportingLogs else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "PingIsland-Diagnostics-\(Self.archiveTimestamp()).zip"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExportingLogs = true
        logExportStatus = AppLocalization.string("正在导出日志…")

        Task {
            do {
                let result = try await DiagnosticsExporter.shared.exportArchive(to: destinationURL)
                await MainActor.run {
                    if result.warnings.isEmpty {
                        logExportStatus = AppLocalization.format(
                            "已导出到 %@",
                            result.archiveURL.lastPathComponent
                        )
                    } else {
                        logExportStatus = AppLocalization.format(
                            "已导出，附带 %lld 条警告",
                            result.warnings.count
                        )
                    }
                    isExportingLogs = false
                }
            } catch {
                await MainActor.run {
                    logExportStatus = AppLocalization.format(
                        "导出失败：%@",
                        error.localizedDescription
                    )
                    isExportingLogs = false
                }
            }
        }
    }

    private static func archiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }



    private func hookConfigurationDirectoryURL(for profile: ManagedHookClientProfile) -> URL? {
        let fileManager = FileManager.default

        for configurationURL in profile.configurationURLs {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: configurationURL.path, isDirectory: &isDirectory) else {
                continue
            }

            return isDirectory.boolValue ? configurationURL : configurationURL.deletingLastPathComponent()
        }

        if let existingDirectory = profile.configurationURLs
            .map({ $0.deletingLastPathComponent() })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existingDirectory
        }

        return profile.primaryConfigurationURL.deletingLastPathComponent()
    }
}

private enum SettingsPanelPresentation {
    case window
    case popover
}

private struct SettingsCategoryLoadingView: View {
    let category: SettingsCategory

    var body: some View {
        SettingsSectionCard(title: category.title) {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white.opacity(0.82))

                Text(verbatim: loadingTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))

                Text(verbatim: loadingSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.54))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    private var loadingTitle: String {
        AppLocalization.format("正在加载%@设置…", AppLocalization.string(category.title))
    }

    private var loadingSubtitle: String {
        switch category {
        case .display:
            return AppLocalization.string("正在刷新显示器与用量展示状态")
        case .general, .realtimeNotifications, .plugins, .about:
            return AppLocalization.string("马上就好")
        }
    }
}

private struct SettingsSidebarSection: Identifiable {
    let title: String?
    let categories: [SettingsCategory]

    var id: String { title ?? categories.map(\.rawValue).joined(separator: "-") }
}

private struct SettingsGlassSurface: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

private enum SettingsPanelMetrics {
    static let windowSize = AppSettings.defaultSettingsWindowSize
    static let windowMinSize = AppSettings.minimumSettingsWindowSize
    static let windowMaxSize = AppSettings.maximumSettingsWindowSize
    static let popoverSize = CGSize(width: 760, height: 620)
    static let windowSidebarWidth: CGFloat = 236
    static let popoverSidebarWidth: CGFloat = 212
    static let windowContentTopInset: CGFloat = 0
    static let popoverContentTopInset: CGFloat = 0
    static let outerPadding: CGFloat = 0
}

private struct SettingsPanelContentView: View {
    let presentation: SettingsPanelPresentation
    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil

    @StateObject private var viewModel = SettingsPanelViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var selectedCategory: SettingsCategory? = .general
    @State private var showingUninstallAllHooksConfirmation = false
    @State private var showingAnalyticsConsentPrompt = false
    @State private var isAccessibilityPollingActive = false
    @State private var arePreviewAnimationsActive = false
    @State private var loadingCategory: SettingsCategory?
    @State private var categoryRefreshTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, contentTopInset)
            .padding(.horizontal, SettingsPanelMetrics.outerPadding)
            .padding(.bottom, SettingsPanelMetrics.outerPadding)
            .frame(
                minWidth: minimumWidth,
                idealWidth: idealWidth,
                maxWidth: maximumWidth,
                minHeight: minimumHeight,
                idealHeight: idealHeight,
                maxHeight: maximumHeight,
                alignment: .topLeading
            )
        }
        .background(panelBackgroundColor)
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 30, y: 18)
        .preferredColorScheme(.dark)
        .environment(\.mascotAnimationsEnabled, arePreviewAnimationsActive)
        .onAppear {
            viewModel.refreshInitialState()
            let isVisible = presentation == .popover || currentWindow?.isVisible == true
            isAccessibilityPollingActive = isVisible
            arePreviewAnimationsActive = isVisible

            scheduleCategoryRefresh(for: currentCategory, showLoading: false)
            showAnalyticsConsentPromptIfNeeded()
        }
        .onDisappear {
            isAccessibilityPollingActive = false
            arePreviewAnimationsActive = false
            categoryRefreshTask?.cancel()
            categoryRefreshTask = nil
            loadingCategory = nil
        }
        .task(id: isAccessibilityPollingActive) {
            guard isAccessibilityPollingActive else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.refreshAccessibilityStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowVisibilityDidChange)) { notification in
            guard presentation == .window,
                  let isVisible = notification.userInfo?[SettingsWindowVisibilityNotification.isVisibleKey] as? Bool else {
                return
            }

            isAccessibilityPollingActive = isVisible
            arePreviewAnimationsActive = isVisible
            if isVisible {
                scheduleCategoryRefresh(for: currentCategory, showLoading: false)
                showAnalyticsConsentPromptIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowCategorySelectionRequested)) { notification in
            guard presentation == .window,
                  let rawCategory = notification.userInfo?[SettingsWindowCategorySelectionRequest.categoryKey] as? String,
                  let category = SettingsCategory(rawValue: rawCategory) else {
                return
            }

            selectSidebarCategory(category)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            scheduleCategoryRefresh(for: currentCategory, showLoading: false)
        }
        .onChange(of: settings.appLanguage) { _, _ in
            viewModel.refreshLocalizedState()
        }
        .alert(
            AppLocalization.string("帮助提升 Ping Island 体验？"),
            isPresented: $showingAnalyticsConsentPrompt
        ) {
            Button(AppLocalization.string("暂不开启"), role: .cancel) {
                settings.analyticsConsentPromptCompleted = true
            }
            Button(AppLocalization.string("同意开启")) {
                settings.analyticsEnabled = true
                settings.analyticsConsentPromptCompleted = true
            }
        } message: {
            Text(appLocalized: "仅发送匿名统计，用于了解启动、功能使用和 Hook 安装成功率。不会包含会话内容、代码、路径或主机信息。")
        }
        .alert(
            AppLocalization.string("一键卸载所有 Hooks 配置文件？"),
            isPresented: $showingUninstallAllHooksConfirmation
        ) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("一键卸载所有 Hooks 配置文件"), role: .destructive) {
                viewModel.uninstallAllHooks()
            }
        } message: {
            Text(appLocalized: "这会移除 Island 为所有本机集成写入的托管 Hooks 配置文件，包括自定义配置记录。")
        }
    }

    private var minimumWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMinSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var maximumWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMaxSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var idealWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSize.width
        case .popover:
            return SettingsPanelMetrics.popoverSize.width
        }
    }

    private var minimumHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMinSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var maximumHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowMaxSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var idealHeight: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSize.height
        case .popover:
            return SettingsPanelMetrics.popoverSize.height
        }
    }

    private var sidebarWidth: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowSidebarWidth
        case .popover:
            return SettingsPanelMetrics.popoverSidebarWidth
        }
    }

    private var panelBackgroundColor: Color {
        .clear
    }

    private var contentTopInset: CGFloat {
        switch presentation {
        case .window:
            return SettingsPanelMetrics.windowContentTopInset
        case .popover:
            return SettingsPanelMetrics.popoverContentTopInset
        }
    }

    private var sidebarSections: [SettingsSidebarSection] {
        [
                SettingsSidebarSection(
                    title: nil,
                    categories: SettingsCategory.visibleCategories
                )
        ]
    }

    private var sidebar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if presentation == .window {
                    sidebarWindowControls
                }

                ForEach(sidebarSections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = section.title {
                            Text(appLocalized: title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.32))
                                .padding(.horizontal, 12)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(section.categories) { category in
                                Button {
                                    selectSidebarCategory(category)
                                } label: {
                                    SidebarItemView(
                                        category: category,
                                        isSelected: selectedCategory == category,
                                        showsNoticeDot: false
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("settings.sidebar.\(category.rawValue)")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
        .padding(8)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
                .fill(Color.white.opacity(0.055))
                .overlay {
                    SettingsGlassSurface(material: .sidebar, blendingMode: .withinWindow)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 24,
                                bottomLeadingRadius: 24,
                                bottomTrailingRadius: 0,
                                topTrailingRadius: 0,
                                style: .continuous
                            )
                        )
                        .opacity(0.94)
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.04),
                            Color.black.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 24,
                            bottomLeadingRadius: 24,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    )
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 120, height: 120)
                        .blur(radius: 36)
                        .offset(x: 28, y: -26)
                }
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 24, y: 14)
    }

    private var sidebarWindowControls: some View {
        HStack(spacing: 10) {
            WindowControlButton(color: Color(red: 1.0, green: 0.37, blue: 0.36)) {
                if let onClose {
                    onClose()
                } else {
                    currentWindow?.performClose(nil)
                }
            }

            WindowControlButton(color: Color(red: 1.0, green: 0.74, blue: 0.18)) {
                if let onMinimize {
                    onMinimize()
                } else {
                    currentWindow?.miniaturize(nil)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                if loadingCategory == currentCategory {
                    SettingsCategoryLoadingView(category: currentCategory)
                } else {
                    switch currentCategory {
                    case .general:
                        generalContent
                    case .display:
                        displayContent
                    case .realtimeNotifications:
                        RealtimeNotificationsSettingsView()
                    case .plugins:
                        PluginsSettingsView()
                    case .about:
                        aboutContent
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(currentCategory)
        .accessibilityIdentifier("settings.detail.\(currentCategory.rawValue)")
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 26,
                topTrailingRadius: 26,
                style: .continuous
            )
                .fill(Color.white.opacity(0.035))
                .overlay {
                    SettingsGlassSurface(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 0,
                                bottomTrailingRadius: 26,
                                topTrailingRadius: 26,
                                style: .continuous
                            )
                        )
                        .opacity(0.96)
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.11),
                            Color.white.opacity(0.03),
                            Color.black.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 26,
                            topTrailingRadius: 26,
                            style: .continuous
                        )
                    )
                }
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 26,
                topTrailingRadius: 26,
                style: .continuous
            )
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 24, y: 14)
    }

    private var currentCategory: SettingsCategory {
        let category = selectedCategory ?? .general
        guard SettingsCategory.visibleCategories.contains(category) else {
            return .general
        }
        return category
    }

    private var currentWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func selectSidebarCategory(_ category: SettingsCategory) {
        selectedCategory = category

        let categoryToRefresh = currentCategory
        scheduleCategoryRefresh(
            for: categoryToRefresh,
            showLoading: shouldShowLoading(for: categoryToRefresh)
        )
    }

    private func showAnalyticsConsentPromptIfNeeded() {
        guard !settings.analyticsConsentPromptCompleted,
              !settings.analyticsEnabled,
              !showingAnalyticsConsentPrompt else {
            return
        }
        showingAnalyticsConsentPrompt = true
    }

    private func shouldShowLoading(for category: SettingsCategory) -> Bool {
        switch category {
        case .display:
            return true
        case .general, .realtimeNotifications, .plugins, .about:
            return false
        }
    }

    private func scheduleCategoryRefresh(for category: SettingsCategory, showLoading: Bool) {
        categoryRefreshTask?.cancel()
        categoryRefreshTask = nil

        if showLoading {
            loadingCategory = category
        } else if loadingCategory == category {
            loadingCategory = nil
        }

        categoryRefreshTask = Task { @MainActor in
            if showLoading {
                try? await Task.sleep(nanoseconds: 80_000_000)
            } else {
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            viewModel.refresh(for: category)

            guard !Task.isCancelled else { return }
            if loadingCategory == category {
                loadingCategory = nil
            }
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "系统") {
                SettingsInfoLine(
                    title: "语言",
                    subtitle: "默认跟随系统语言，也可以单独固定为简体中文或 English。"
                ) {
                    appLanguagePicker
                }
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "登录时打开",
                    subtitle: "启动 macOS 后自动显示 Island",
                    isOn: Binding(
                        get: { viewModel.launchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
                SettingsLineDivider()

                SettingsInfoLine(title: "显示器", subtitle: "选择 Island 所在显示器") {
                    screenPicker
                }
            }

            SettingsSectionCard(title: "基础行为") {
                SettingsToggleLine(
                    title: "全屏时隐藏",
                    subtitle: "全屏工作时减少打扰，需要时再唤出 Island",
                    isOn: $settings.hideInFullscreen
                )
                SettingsLineDivider()

                SettingsToggleLine(
                    title: "无活跃会话时自动隐藏",
                    subtitle: "当前没有正在运行或需要处理的会话时，自动隐藏 Island",
                    isOn: $settings.autoHideWhenIdle
                )
            }

            SettingsSectionCard(title: "应用") {
                SettingsActionLine(
                    title: "退出应用",
                    subtitle: "立即关闭 Island"
                ) {
                    NSApplication.shared.terminate(nil)
                } accessory: {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
            }

#if APP_STORE
            SettingsSectionCard(title: "App Store 沙箱") {
                SettingsInfoLine(
                    title: "需要手动授权目录",
                    subtitle: "App Store 版本不会默认写入 ~/.claude、~/.codex 等配置。安装或重装 Hooks 时，请在系统弹窗中授权用户主目录。"
                ) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(TerminalColors.amber)
                }
                SettingsLineDivider()
                SettingsInfoLine(
                    title: "Bridge 链路自检",
                    subtitle: viewModel.bridgeHealthStatus.message
                ) {
                    HStack(spacing: 10) {
                        Text(appLocalized: viewModel.bridgeHealthStatus.isHealthy ? "正常" : "异常")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule(style: .continuous).fill((viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber).opacity(0.16)))
                            .overlay(Capsule(style: .continuous).strokeBorder((viewModel.bridgeHealthStatus.isHealthy ? TerminalColors.green : TerminalColors.amber).opacity(0.28), lineWidth: 1))
                        HookManagementButton(title: "重新检测", tint: TerminalColors.blue) {
                            viewModel.refreshBridgeHealthStatus()
                        }
                    }
                }
            }
#endif

#if !APP_STORE
            SettingsSectionCard(title: "系统权限") {
                SettingsStatusLine(
                    title: "辅助功能",
                    subtitle: viewModel.accessibilityEnabled ? "已授权，可进行窗口聚焦与前台检测" : "未授权，部分自动聚焦能力不可用",
                    status: viewModel.accessibilityEnabled ? "已开启" : "待开启",
                    statusColor: viewModel.accessibilityEnabled ? TerminalColors.green : TerminalColors.amber
                ) {
                    if !viewModel.accessibilityEnabled { viewModel.openAccessibilitySettings() }
                }
            }
#endif

        }
    }

    private var displayContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "显示器") {
                SettingsInfoLine(
                    title: "当前显示器",
                    subtitle: "切换后会重新挂载 Island 窗口位置"
                ) {
                    screenPicker
                }
                SettingsLineDivider()

                if let selectedScreen = screenSelector.selectedScreen {
                    SettingsValueLine(
                        title: "当前输出",
                        value: selectedScreen.localizedName
                    )
                }
            }

            SettingsSectionCard(title: "面板") {
                SettingsInfoLine(
                    title: "展示方式",
                    subtitle: "当前固定使用刘海屏方式，Island 会停靠在屏幕顶部中央。"
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(appLocalized: "刘海屏方式")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(TerminalColors.blue)
                }
            }
        }
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "应用信息") {
                SettingsValueLine(title: "版本", value: appVersion, style: .compactDetail)
                SettingsLineDivider()
                SettingsValueLine(title: "构建", value: appBuild, style: .compactDetail)
                SettingsLineDivider()
                SettingsValueLine(title: "安装时间", value: versionMetadata, style: .compactDetail)
                SettingsLineDivider()
                SettingsValueLine(title: "之前版本", value: previousVersion, style: .compactDetail)
            }

            SettingsSectionCard(title: "隐私与分析") {
                SettingsToggleLine(
                    title: "匿名使用统计",
                    subtitle: "匿名统计启动、功能使用、Hook 安装和会话状态；不包含内容、代码、路径或主机信息。",
                    isOn: $settings.analyticsEnabled,
                    style: .compactDetail
                )
                SettingsLineDivider()
                SettingsInfoLine(
                    title: "采集范围",
                    subtitle: "未同意前不上传；开启后有每日上限，可随时关闭。",
                    style: .compactDetail
                ) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            SettingsSectionCard(title: "更新") {
                SettingsToggleLine(
                    title: "自动检查更新",
                    subtitle: "启动时和空闲时自动检查、下载并安装更新；关闭后仅在手动检查时更新",
                    isOn: $settings.automaticUpdateChecksEnabled,
                    style: .compactDetail
                )
                SettingsLineDivider()

                SettingsActionLine(
                    title: updateTitle,
                    subtitle: updateSubtitle,
                    style: .compactDetail
                ) {
                    handleUpdateAction()
                } accessory: {
                    updateAccessory
                }

                if updateManager.canShowReleaseNotes {
                    SettingsLineDivider()

                    SettingsActionLine(
                        title: updateManager.releaseNotesActionTitle,
                        subtitle: updateManager.releaseNotesActionSubtitle,
                        style: .compactDetail
                    ) {
                        updateManager.showReleaseNotes()
                    } accessory: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }

            SettingsSectionCard(title: "链接") {
                SettingsActionLine(title: "GitHub", subtitle: "打开 Issues 页面反馈问题") {
                    if let url = URL(string: "https://github.com/erha19/ping-island/issues") {
                        NSWorkspace.shared.open(url)
                    }
                } accessory: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }

                SettingsLineDivider()

                SettingsActionLine(
                    title: "导出诊断日志",
                    subtitle: viewModel.logExportStatus
                ) {
                    viewModel.exportLogs()
                } accessory: {
                    if viewModel.isExportingLogs {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white.opacity(0.8))
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private var screenPicker: some View {
        Picker("显示器", selection: screenSelectionBinding) {
            Text(appLocalized: "自动").tag("automatic")
            ForEach(screenSelector.availableScreens, id: \.self) { screen in
                Text(screen.localizedName).tag(screenToken(for: screen))
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
    }

    private var appLanguagePicker: some View {
        Picker("语言", selection: $settings.appLanguage) {
            ForEach(AppLanguage.allCases) { language in
                Text(appLocalized: language.title).tag(language)
            }
        }
        .labelsHidden()
        .settingsMenuPicker(width: 168)
    }

    private var screenSelectionBinding: Binding<String> {
        Binding(
            get: {
                if screenSelector.selectionMode == .automatic {
                    return "automatic"
                }
                if let selected = screenSelector.selectedScreen {
                    return screenToken(for: selected)
                }
                return "automatic"
            },
            set: { token in
                if token == "automatic" {
                    screenSelector.selectAutomatic()
                } else if let screen = screenSelector.availableScreens.first(where: { screenToken(for: $0) == token }) {
                    screenSelector.selectScreen(screen)
                }
                NotificationCenter.default.post(
                    name: NSApplication.didChangeScreenParametersNotification,
                    object: nil
                )
            }
        )
    }

    private func shortcutBinding(for action: GlobalShortcutAction) -> Binding<GlobalShortcut?> {
        Binding(
            get: { settings.shortcut(for: action) },
            set: { settings.setShortcut($0, for: action) }
        )
    }

    private func screenToken(for screen: NSScreen) -> String {
        let identifier = ScreenIdentifier(screen: screen)
        return "\(identifier.displayID ?? 0)-\(identifier.localizedName)"
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var versionMetadata: String {
        guard let metadata = HookInstaller.getVersionMetadata(),
              let installedAt = metadata["installedAt"] as? String else {
            return AppLocalization.string("首次安装")
        }

        // Format the date
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: installedAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }

        return installedAt
    }

    private var previousVersion: String {
        guard let metadata = HookInstaller.getVersionMetadata(),
              let previous = metadata["previousVersion"] as? String,
              !previous.isEmpty else {
            return AppLocalization.string("无")
        }
        return previous
    }

    private var updateTitle: String {
        switch updateManager.state {
        case .idle, .upToDate:
            return AppLocalization.string("检查更新")
        case .checking:
            return AppLocalization.string("检查中...")
        case .found, .downloading, .extracting, .readyToInstall, .installing:
            return AppLocalization.string("静默更新中")
        case .error:
            return AppLocalization.string("重试更新")
        }
    }

    private var updateSubtitle: String {
        switch updateManager.state {
        case .idle:
            return updateManager.isConfigured
                ? AppLocalization.string(
                    settings.automaticUpdateChecksEnabled
                        ? "启动时和空闲时自动检查、下载并安装更新"
                        : "自动更新已关闭，可随时手动检查"
                )
                : updateManager.configurationStatus.message
        case .upToDate:
            return AppLocalization.string("当前已经是最新版本")
        case .checking:
            return AppLocalization.string("正在后台检查更新")
        case .found(let version, _):
            return AppLocalization.format("发现新版本 v%@，将静默下载并安装", version)
        case .downloading:
            return AppLocalization.string("正在后台下载更新")
        case .extracting:
            return AppLocalization.string("正在准备安装更新")
        case .readyToInstall(let version):
            return AppLocalization.format("v%@ 已就绪，空闲时自动重启安装", version)
        case .installing:
            return AppLocalization.string("正在静默安装并重启")
        case .error:
            return AppLocalization.string("后台更新失败，点击后重新检查")
        }
    }

    @ViewBuilder
    private var updateAccessory: some View {
        switch updateManager.state {
        case .checking, .downloading, .extracting, .installing:
            ProgressView()
                .controlSize(.small)
        case .upToDate:
            Text(appLocalized: "最新")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .found(let version, _), .readyToInstall(let version):
            Text("v\(version)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .idle, .error:
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func handleUpdateAction() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .checking, .found, .downloading, .extracting, .readyToInstall, .installing:
            break
        }
    }
}

struct SettingsWindowView: View {
    var onClose: (() -> Void)? = nil
    var onMinimize: (() -> Void)? = nil

    var body: some View {
        AppLocalizedRootView {
            SettingsPanelContentView(
                presentation: .window,
                onClose: onClose,
                onMinimize: onMinimize
            )
            .accessibilityIdentifier("settings.root")
        }
    }
}

struct NotchSettingsPopoverView: View {
    var body: some View {
        AppLocalizedRootView {
            SettingsPanelContentView(presentation: .popover)
                .frame(width: SettingsPanelMetrics.popoverSize.width, height: SettingsPanelMetrics.popoverSize.height)
        }
    }
}

private struct SidebarItemView: View {
    let category: SettingsCategory
    let isSelected: Bool
    var showsNoticeDot: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(isSelected ? 0.95 : 1))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                isSelected
                                ? LinearGradient(
                                    colors: [
                                        category.tint.opacity(0.95),
                                        category.tint.opacity(0.60)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        category.tint.opacity(0.92),
                                        category.tint.opacity(0.74)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if showsNoticeDot {
                    Circle()
                        .fill(TerminalColors.amber)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.black.opacity(0.42), lineWidth: 1)
                        )
                        .offset(x: 2, y: -2)
                        .accessibilityLabel("有需要注意的集成提示")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalized: category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(isSelected ? 0.94 : 0.80))
                    .lineLimit(1)

                Text(appLocalized: category.subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(isSelected ? 0.60 : 0.42))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.10 : 0.04), lineWidth: 1)
        )
        .shadow(color: isSelected ? category.tint.opacity(0.18) : .clear, radius: 14, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct WindowControlButton: View {
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized: title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        SettingsGlassSurface(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .opacity(0.96)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.08),
                                        Color.white.opacity(0.025),
                                        Color.black.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 18, y: 10)
        }
    }
}

private struct SettingsLineDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.white.opacity(0.10))
            .padding(.horizontal, 18)
    }
}



private struct CustomHookInstallSheet: View {
    @ObservedObject var viewModel: SettingsPanelViewModel
    let onDismiss: () -> Void

    @State private var selectedProfileID: String = ""
    @State private var customPath: String = ""

    private var availableProfiles: [ManagedHookClientProfile] {
        ClientProfileRegistry.managedHookProfiles
    }

    private var canInstall: Bool {
        !selectedProfileID.isEmpty && !customPath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(appLocalized: "添加自定义 Hook 配置")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "选择应用")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    Picker("", selection: $selectedProfileID) {
                        Text(appLocalized: "请选择...").tag("")
                        ForEach(availableProfiles) { profile in
                            Text(profile.title).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: "安装目录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))

                    HStack(spacing: 8) {
                        TextField("", text: $customPath, prompt: Text(verbatim: installPathPlaceholder))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            )

                        Button(action: selectDirectory) {
                            Text(appLocalized: "选择目录")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if let resolvedFileName {
                        Text(resolvedInstallTargetDescription(resolvedFileName: resolvedFileName))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let installHint {
                        Text(verbatim: installHint)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button(action: onDismiss) {
                    Text(appLocalized: "取消")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: install) {
                    Text(appLocalized: "安装")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(canInstall ? .white : .white.opacity(0.4))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(canInstall ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(canInstall ? TerminalColors.blue.opacity(0.5) : .white.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canInstall)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var resolvedFileName: String? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID),
              !customPath.isEmpty else {
            return nil
        }
        return profile.primaryConfigurationURL.lastPathComponent
    }

    private var installPathPlaceholder: String {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return "例如 /path/to/.claude"
        }

        switch profile.installationKind {
        case .jsonHooks, .tomlHooks:
            return "例如 /path/to/.claude"
        case .pluginFile:
            return "例如 /path/to/plugins"
        case .pluginDirectory:
            return "例如 /path/to/.hermes 或 /path/to/plugins"
        case .hookDirectory:
            return "例如 /path/to/.openclaw 或 /path/to/hooks"
        }
    }

    private var installHint: String? {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return nil
        }
        switch profile.installationKind {
        case .hookDirectory:
            return AppLocalization.string("OpenClaw 可选择 ~/.openclaw 根目录，或已配置到 extraDirs 的 hooks 目录。")
        case .pluginDirectory:
            return AppLocalization.string("Hermes 可选择 ~/.hermes 根目录，或 plugins 目录。")
        case .jsonHooks, .pluginFile, .tomlHooks:
            return nil
        }
    }

    private func resolvedInstallTargetDescription(resolvedFileName: String) -> String {
        guard let profile = ClientProfileRegistry.managedHookProfile(id: selectedProfileID) else {
            return AppLocalization.format("安装后将写入: %@/%@", customPath, resolvedFileName)
        }

        let baseURL = URL(fileURLWithPath: customPath)
        let targetURL: URL
        switch profile.installationKind {
        case .jsonHooks, .pluginFile, .tomlHooks:
            targetURL = baseURL.appendingPathComponent(resolvedFileName)
        case .pluginDirectory:
            if baseURL.lastPathComponent == ".hermes" {
                targetURL = baseURL
                    .appendingPathComponent("plugins", isDirectory: true)
                    .appendingPathComponent(resolvedFileName, isDirectory: true)
            } else if baseURL.lastPathComponent == "plugins" {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            } else {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            }
        case .hookDirectory:
            if baseURL.lastPathComponent == ".openclaw" {
                targetURL = baseURL
                    .appendingPathComponent("hooks", isDirectory: true)
                    .appendingPathComponent(resolvedFileName, isDirectory: true)
            } else if baseURL.lastPathComponent == "hooks" {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            } else {
                targetURL = baseURL.appendingPathComponent(resolvedFileName, isDirectory: true)
            }
        }

        return AppLocalization.format("安装后将写入: %@", targetURL.path)
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = AppLocalization.string("选择 Hook 配置目录")
        panel.prompt = AppLocalization.string("选择")

        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
        }
    }

    private func install() {
        guard canInstall else { return }
        viewModel.installCustomHook(profileID: selectedProfileID, directoryPath: customPath)
        onDismiss()
    }
}

enum HookInstallOptionsMode {
    case install
    case edit
}


private struct HookInstallOptionsSheet: View {
    let profile: ManagedHookClientProfile
    let mode: HookInstallOptionsMode
    let initialSelection: HookInstallSelection
    let onConfirm: (HookInstallSelection) -> Void
    let onDismiss: () -> Void

    @State private var enabledEventNames: Set<String>
    @State private var advancedExpanded: Bool

    init(
        profile: ManagedHookClientProfile,
        mode: HookInstallOptionsMode,
        initialSelection: HookInstallSelection,
        onConfirm: @escaping (HookInstallSelection) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.profile = profile
        self.mode = mode
        self.initialSelection = initialSelection
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _enabledEventNames = State(initialValue: initialSelection.enabledEventNames)
        _advancedExpanded = State(initialValue: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categoryToggles
                    advancedSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)

            footer
        }
        .padding(24)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HookManagementIcon(profile: profile)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: profile.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private var categoryToggles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(profile.availableEventCategories) { category in
                CategoryToggleRow(
                    category: category,
                    state: state(for: category),
                    onToggle: { toggleCategory(category) }
                )

                if category != profile.availableEventCategories.last {
                    Divider()
                        .overlay(Color.white.opacity(0.08))
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(profile.availableEventCategories) { category in
                    let events = profile.events(in: category)
                    if !events.isEmpty {
                        Text(appLocalized: category.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ForEach(events, id: \.name) { event in
                            EventToggleRow(
                                event: event,
                                isOn: enabledEventNames.contains(event.name),
                                onToggle: { toggleEvent(event.name) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        } label: {
            Text(appLocalized: "高级 — 按事件单独配置")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
        }
        .tint(.white.opacity(0.6))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(appLocalized: footerHint)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(action: onDismiss) {
                Text(appLocalized: "取消")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: confirm) {
                Text(appLocalized: confirmTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(canConfirm ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(canConfirm ? brandTint(profile.brand).opacity(0.5) : .white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(canConfirm ? brandTint(profile.brand).opacity(0.55) : .white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm)
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .install:
            return "选择需要安装的 Hook 事件类别。可在高级中按单个事件微调。"
        case .edit:
            return "调整已安装的 Hook 事件，保存后会刷新该客户端的 hooks 配置。"
        }
    }

    private var footerHint: String {
        AppLocalization.string("默认全部启用；关闭某些事件后，对应通知或审批将不再触发。")
    }

    private var confirmTitle: String {
        switch mode {
        case .install: return "安装"
        case .edit: return "保存"
        }
    }

    private var canConfirm: Bool {
        !enabledEventNames.isEmpty
    }

    private func confirm() {
        guard canConfirm else { return }
        onConfirm(HookInstallSelection(enabledEventNames: enabledEventNames))
    }

    private func state(for category: HookInstallEventCategory) -> CategoryToggleState {
        let names = profile.events(in: category).map(\.name)
        guard !names.isEmpty else { return .off }
        let enabledCount = names.filter { enabledEventNames.contains($0) }.count
        if enabledCount == 0 { return .off }
        if enabledCount == names.count { return .on }
        return .mixed
    }

    private func toggleCategory(_ category: HookInstallEventCategory) {
        let names = profile.events(in: category).map(\.name)
        let currentState = state(for: category)
        switch currentState {
        case .on:
            for name in names { enabledEventNames.remove(name) }
        case .off, .mixed:
            for name in names { enabledEventNames.insert(name) }
        }
    }

    private func toggleEvent(_ name: String) {
        if enabledEventNames.contains(name) {
            enabledEventNames.remove(name)
        } else {
            enabledEventNames.insert(name)
        }
    }
}

private enum CategoryToggleState {
    case on
    case off
    case mixed
}

private struct CategoryToggleRow: View {
    let category: HookInstallEventCategory
    let state: CategoryToggleState
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: category.iconSymbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized: category.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(appLocalized: category.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: onToggle) {
                indicator
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state {
        case .on:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TerminalColors.green)
        case .mixed:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(TerminalColors.amber)
        case .off:
            Image(systemName: "circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

private struct EventToggleRow: View {
    let event: HookInstallEventDescriptor
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: event.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.86))

            if let timeout = event.timeout {
                Text(verbatim: "\(timeout)s")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.05))
                    )
            }

            Spacer(minLength: 12)

            Button(action: onToggle) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isOn ? TerminalColors.green : .white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

private struct HookManagementIcon: View {
    let profile: ManagedHookClientProfile

    var body: some View {
        SettingsClientIcon(
            logoAssetName: profile.logoAssetName,
            prefersBundledLogoOverAppIcon: profile.prefersBundledLogoOverAppIcon,
            localAppBundleIdentifiers: profile.localAppBundleIdentifiers,
            iconSymbolName: profile.iconSymbolName
        )
    }
}

private struct SettingsClientIcon: View {
    let logoAssetName: String?
    let prefersBundledLogoOverAppIcon: Bool
    let localAppBundleIdentifiers: [String]
    let iconSymbolName: String

    var body: some View {
        if let preferredLogoAssetName {
            Image(preferredLogoAssetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else if let resolvedAppIcon {
            Image(nsImage: resolvedAppIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        } else {
            Image(systemName: iconSymbolName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }

    private var resolvedAppIcon: NSImage? {
        ClientAppLocator.icon(bundleIdentifiers: localAppBundleIdentifiers)
    }

    private var preferredLogoAssetName: String? {
        guard let logoAssetName else {
            return nil
        }

        return prefersBundledLogoOverAppIcon || resolvedAppIcon == nil
            ? logoAssetName
            : nil
    }
}

private func brandTint(_ brand: SessionClientBrand) -> Color {
    brand.tintColor
}

private func ideTint(_ profileID: String) -> Color {
    switch profileID {
    case "vscode-extension":
        return Color(red: 0.15, green: 0.55, blue: 0.96)
    case "cursor-extension":
        return Color(red: 0.30, green: 0.72, blue: 0.98)
    case "codebuddy-extension":
        return Color(red: 0.98, green: 0.61, blue: 0.28)
    case "qoder-extension":
        return Color(red: 0.12, green: 0.88, blue: 0.56)
    default:
        return Color.white.opacity(0.72)
    }
}

private struct HookManagementButton: View {
    let title: String
    let tint: Color
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.86))
                }

                Text(appLocalized: title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.34), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.72 : 1)
    }
}

private enum SettingsLineVisualStyle {
    case standard
    case compactDetail

    var bodySpacing: CGFloat {
        switch self {
        case .standard: return 6
        case .compactDetail: return 5
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .standard: return 14
        case .compactDetail: return 12
        }
    }

    var subtitleFont: Font {
        switch self {
        case .standard:
            return .system(size: 11, weight: .medium)
        case .compactDetail:
            return .system(size: 10.5, weight: .regular)
        }
    }

    var subtitleColor: Color {
        switch self {
        case .standard:
            return .white.opacity(0.58)
        case .compactDetail:
            return .white.opacity(0.62)
        }
    }

    var subtitleLineSpacing: CGFloat {
        switch self {
        case .standard: return 0
        case .compactDetail: return 1
        }
    }

    var valueFont: Font {
        switch self {
        case .standard:
            return .system(size: 13, weight: .semibold)
        case .compactDetail:
            return .system(size: 12.5, weight: .medium)
        }
    }

    var valueColor: Color {
        switch self {
        case .standard:
            return .white.opacity(0.72)
        case .compactDetail:
            return .white.opacity(0.68)
        }
    }
}

private struct SettingsToggleLine: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    var style: SettingsLineVisualStyle = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: style.bodySpacing) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .settingsCompactSwitch()
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(style.subtitleFont)
                    .foregroundColor(style.subtitleColor)
                    .lineSpacing(style.subtitleLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, style.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
    }
}

private extension View {
    func settingsCompactSwitch(scale: CGFloat = 0.84) -> some View {
        self
            .toggleStyle(.switch)
            .controlSize(.small)
            .scaleEffect(scale)
            .frame(width: 32, height: 18)
    }

    func settingsMenuPicker(width: CGFloat) -> some View {
        self
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: width, alignment: .trailing)
    }
}

private struct SettingsInfoLine<Accessory: View>: View {
    let title: String
    let subtitle: String?
    var style: SettingsLineVisualStyle = .standard
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: style.bodySpacing) {
            HStack(alignment: .center, spacing: 16) {
                Text(appLocalized: title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 12)

                accessory
            }

            if let subtitle {
                Text(appLocalized: subtitle)
                    .font(style.subtitleFont)
                    .foregroundColor(style.subtitleColor)
                    .lineSpacing(style.subtitleLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, style.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsActionLine<Accessory: View>: View {
    let title: String
    let subtitle: String?
    var style: SettingsLineVisualStyle = .standard
    let action: () -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Button(action: action) {
            SettingsInfoLine(title: title, subtitle: subtitle, style: style) {
                accessory
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCodeCapsule: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.74))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SettingsValueLine: View {
    let title: String
    let value: String
    var style: SettingsLineVisualStyle = .standard

    var body: some View {
        HStack(spacing: 16) {
            Text(appLocalized: title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Spacer(minLength: 12)

            Text(value)
                .font(style.valueFont)
                .foregroundColor(style.valueColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, style.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutSettingsLine: View {
    let action: GlobalShortcutAction
    @Binding var shortcut: GlobalShortcut?

    var body: some View {
        ShortcutRecorderControl(
            action: action,
            shortcut: $shortcut,
            defaultShortcut: action.defaultShortcut
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ShortcutRecorderControl: View {
    let action: GlobalShortcutAction
    @Binding var shortcut: GlobalShortcut?
    let defaultShortcut: GlobalShortcut?

    @State private var isRecording = false
    @State private var helperTextKey: String?
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appLocalized: action.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Text(appLocalized: action.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                recordButton
            }

            HStack(alignment: .center, spacing: 8) {
                Text(appLocalized: "当前键位")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.40))

                if let shortcut {
                    ShortcutVisualLabel(
                        shortcut: shortcut,
                        fontSize: 11,
                        foregroundColor: .white.opacity(0.92),
                        keyBackground: Color.black.opacity(0.28),
                        keyBorder: Color.white.opacity(0.08),
                        keyMinWidth: 24,
                        keyHorizontalPadding: 7,
                        keyVerticalPadding: 5,
                        keyCornerRadius: 10
                    )
                } else {
                    Text(appLocalized: "未设置")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.42))
                }

                Spacer(minLength: 12)

                if shortcut != nil {
                    Button {
                        shortcut = nil
                        helperTextKey = nil
                        stopRecording()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(ShortcutIconButtonStyle())
                    .help(AppLocalization.string("清空快捷键"))
                    .accessibilityLabel(Text(appLocalized: "清空快捷键"))
                }

                if defaultShortcut != nil {
                    Button {
                        shortcut = defaultShortcut
                        helperTextKey = nil
                        stopRecording()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(ShortcutIconButtonStyle())
                    .help(AppLocalization.string("恢复默认快捷键"))
                    .accessibilityLabel(Text(appLocalized: "恢复默认快捷键"))
                }
            }

            Text(appLocalized: helperTextKey ?? (isRecording ? "录制中，按 Esc 取消，Delete 清空" : "需要同时按下至少一个修饰键"))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isRecording ? TerminalColors.green.opacity(0.90) : .white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var recordButton: some View {
        Button {
            toggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                    .font(.system(size: 11, weight: .bold))

                Text(appLocalized: isRecording ? "按下新快捷键" : "点击录制")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isRecording ? .black : .white.opacity(0.88))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isRecording ? TerminalColors.green.opacity(0.96) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isRecording ? TerminalColors.green.opacity(0.9) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(AppLocalization.string(isRecording ? "停止录制快捷键" : "开始录制快捷键"))
        .accessibilityLabel(Text(appLocalized: isRecording ? "停止录制快捷键" : "开始录制快捷键"))
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        helperTextKey = nil
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleRecording(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleRecording(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            helperTextKey = nil
            stopRecording()
            return
        }

        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            shortcut = nil
            helperTextKey = nil
            stopRecording()
            return
        }

        guard let recordedShortcut = GlobalShortcut(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            helperTextKey = "需要同时按下至少一个修饰键"
            return
        }

        shortcut = recordedShortcut
        helperTextKey = nil
        stopRecording()
    }
}

private struct ShortcutIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.76 : 0.88))
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : 0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

private struct SubagentVisibilityPicker: View {
    @Binding var mode: SubagentVisibilityMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(SubagentVisibilityMode.allCases) { candidate in
                Text(candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "子 Agent 显示"))
        .settingsMenuPicker(width: 168)
    }
}

private struct UsageValueModePicker: View {
    @Binding var mode: UsageValueMode

    var body: some View {
        Picker("", selection: $mode) {
            ForEach(UsageValueMode.allCases) { candidate in
                Text(appLocalized: candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "用量显示方式"))
        .settingsMenuPicker(width: 168)
    }
}

private struct AutoRoutePromptsIdleDelayPicker: View {
    @Binding var delay: AutoRoutePromptsIdleDelay

    var body: some View {
        Picker("", selection: $delay) {
            ForEach(AutoRoutePromptsIdleDelay.allCases) { candidate in
                Text(appLocalized: candidate.title).tag(candidate)
            }
        }
        .labelsHidden()
        .accessibilityLabel(Text(appLocalized: "静默时长"))
        .settingsMenuPicker(width: 132)
    }
}

private struct DisplayPreviewMascotPicker: View {
    private let accessibilityTitleKey = "默认宠物形象"
    @Binding var kind: MascotKind

    var body: some View {
        Picker(selection: $kind) {
            ForEach(MascotKind.allCases) { candidate in
                Text(
                    verbatim: AppLocalization.format(
                        "%@ · %@",
                        AppLocalization.string(candidate.subtitle),
                        AppLocalization.string(candidate.title)
                    )
                )
                .tag(candidate)
            }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .accessibilityLabel(Text(verbatim: AppLocalization.string(accessibilityTitleKey)))
        .pickerStyle(.menu)
        .frame(minWidth: 180, alignment: .trailing)
    }
}

private struct NotchDisplayPreviewMock: View {
    let mode: NotchDisplayMode
    let mascotKind: MascotKind
    let width: CGFloat
    let height: CGFloat

    private let actualClosedWidth: CGFloat = 274
    private let actualSideWidth: CGFloat = 30
    private let actualCenterWidth: CGFloat = 186

    var body: some View {
        let sideSlotWidth = width * (actualSideWidth / actualClosedWidth)
        let centerSlotWidth = width * (actualCenterWidth / actualClosedWidth)

        return HStack(spacing: 0) {
            HStack {
                MascotView(kind: mascotKind, status: .idle, size: 14)
            }
            .frame(width: sideSlotWidth, alignment: .center)

            HStack {
                if mode == .detailed {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 14)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.white.opacity(0.76))
                                .frame(width: 42, height: 3)
                                .padding(.leading, 8)
                        }
                        .frame(width: centerSlotWidth * 0.92, alignment: .center)
                } else {
                    Color.clear
                        .frame(width: centerSlotWidth * 0.92)
                }
            }
            .frame(width: centerSlotWidth, alignment: .center)

            HStack {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 18, height: 14)
                    .overlay(
                        Text("3")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                    )
            }
            .frame(width: sideSlotWidth, alignment: .center)
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 5)
    }
}

private struct NotchDisplayModeSelector: View {
    @Binding var mode: NotchDisplayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appLocalized: "刘海显示模式")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Text(appLocalized: "直接预览刘海闭合态效果。简约模式只显示宠物和数量，详细模式会额外显示中间过程信息。")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(NotchDisplayMode.allCases) { candidate in
                    NotchDisplayModeCard(
                        mode: candidate,
                        isSelected: mode == candidate
                    ) {
                        mode = candidate
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct NotchDisplayModeCard: View {
    let mode: NotchDisplayMode
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(previewBackground)
                        .aspectRatio(7.0 / 3.0, contentMode: .fit)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(previewBorder, lineWidth: 1)
                        )
                        .overlay {
                            previewScene
                                .padding(12)
                        }
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLocalized: mode.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)

                        Text(appLocalized: mode.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isSelected ? accentColor : .white.opacity(0.26))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.09 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? accentColor.opacity(0.56) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: isSelected ? accentColor.opacity(0.18) : .clear, radius: 16, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var accentColor: Color {
        switch mode {
        case .compact:
            return Color(red: 0.24, green: 0.72, blue: 0.98)
        case .detailed:
            return Color(red: 0.98, green: 0.68, blue: 0.25)
        }
    }

    private var previewBackground: LinearGradient {
        switch mode {
        case .compact:
            return LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.18, blue: 0.30),
                    Color(red: 0.05, green: 0.09, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .detailed:
            return LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.17, blue: 0.09),
                    Color(red: 0.11, green: 0.07, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var previewBorder: Color {
        isSelected ? accentColor.opacity(0.42) : Color.white.opacity(0.10)
    }

    @ViewBuilder
    private var previewScene: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(spacing: 0) {
                    NotchDisplayPreviewMock(
                        mode: mode,
                        mascotKind: settings.previewMascotKind,
                        width: min(max(proxy.size.width * 0.9, 112), 168),
                        height: min(max(proxy.size.height * 0.28, 22), 28)
                    )
                        .padding(.top, 10)

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()
                        Text(appLocalized: mode == .compact ? "简约示意" : "详细示意")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.42))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct SettingsStatusLine: View {
    let title: String
    let subtitle: String?
    let status: String
    let statusColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 16) {
                    Text(appLocalized: title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer(minLength: 12)

                    HStack(spacing: 10) {
                        Text(appLocalized: status)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(statusColor)

                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                if let subtitle {
                    Text(appLocalized: subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
