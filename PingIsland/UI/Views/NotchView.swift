//
//  NotchView.swift
//  PingIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

/// Keeps the compact center message slightly narrower than the full center slot
/// so the closed notch matches the tighter visual balance used elsewhere.
private let compactCenterContentInset: CGFloat = 14
private let compactLeftEarContentInset: CGFloat = 1
private let compactEarOutset: CGFloat = 2

struct OpenedPanelContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    private static let startupDetachmentHintDelay: TimeInterval = 1.8
    private static let detachmentHintRetryDelay: TimeInterval = 0.75

    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var pluginArbiter = PluginSlotArbiter.shared
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var activePluginNotification: PluginNotifyUpdate?
    @State private var pluginNotificationDismissWork: DispatchWorkItem?
    @State private var isShowingDetachmentHint: Bool = false
    @State private var detachmentHintDismissWorkItem: DispatchWorkItem?
    @State private var detachmentHintPresentationWorkItem: DispatchWorkItem?

    @Namespace private var activityNamespace

    private let petIconSize: CGFloat = 16

    private var isOnBuiltinDisplay: Bool {
        screenSelector.selectedScreen?.isBuiltinDisplay == true
    }

    private var shouldHideForIdleState: Bool {
        settings.autoHideWhenIdle
            && activePluginNotification == nil
    }

    /// Whether the closed notch is currently surfacing a plugin notification.
    private var isInNotificationMoment: Bool {
        activePluginNotification != nil
    }

    private var showsClosedNotificationSource: Bool {
        viewModel.status != .opened && isInNotificationMoment
    }

    /// In fullscreen on physical-notch displays, the closed state should visually
    /// collapse back to the native macOS notch with no Island content shown.
    private var shouldHideClosedContent: Bool {
        viewModel.usesPhysicalNotchClosedPresentation && viewModel.status != .opened
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        viewModel.closedSize
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    private var closedContentWidth: CGFloat {
        closedNotchSize.width
    }

    private var closedInnerWidth: CGFloat {
        max(0, closedContentWidth - (cornerRadiusInsets.closed.bottom * 2))
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        instrumentedBody
    }

    private var instrumentedBody: some View {
        shortcutAwareBody
    }

    private var shortcutAwareBody: some View {
        visibilityAwareBody
            .onReceive(NotificationCenter.default.publisher(for: .pingIslandPresentNotchDetachmentHint)) { _ in
                presentDetachmentHintIfNeeded(force: true)
            }
            .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
                guard viewModel.status == .opened else {
                    viewModel.updateOpenedMeasuredHeight(nil)
                    return
                }

                switch viewModel.contentType {
                case .plugin:
                    let measuredHeight = height > 0
                        ? closedNotchSize.height + height + 12
                        : nil
                    viewModel.updateOpenedMeasuredHeight(measuredHeight)
                default:
                    viewModel.updateOpenedMeasuredHeight(nil)
                }
            }
    }

    private var visibilityAwareBody: some View {
        contentTypeAwareBody
            .onChange(of: viewModel.isFullscreenEdgeRevealActive) { _, isActive in
                if isActive && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleVisibilityChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isFullscreenBrowserHiddenActive) { _, isActive in
                if isActive {
                    isVisible = false
                } else {
                    handleVisibilityChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.isIdleAutoHiddenActive) { _, isHidden in
                if isHidden && viewModel.status != .opened {
                    isVisible = false
                } else {
                    handleVisibilityChange()
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: viewModel.presentationMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: viewModel.isFullscreenPhysicalNotchCompactActive) { _, isActive in
                if !isActive {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                }
            }
            .onChange(of: settings.surfaceMode) { _, _ in
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
            }
            .onChange(of: settings.notchDetachmentHintPending) { _, isPending in
                if isPending {
                    scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
                } else {
                    cancelScheduledDetachmentHintPresentation()
                }
            }
    }

    private var contentTypeAwareBody: some View {
        settingsAwareBody
            .onChange(of: pluginArbiter.pendingNotifications) { _, notifications in
                if activePluginNotification == nil, !notifications.isEmpty {
                    dequeuePluginNotification()
                }
            }
            .onChange(of: isInNotificationMoment) { _, active in
                viewModel.hoverExpansionAllowed = active
            }
            .onAppear { viewModel.hoverExpansionAllowed = isInNotificationMoment }
    }

    private var settingsAwareBody: some View {
        lifecycleBody
            .onChange(of: settings.autoHideWhenIdle) { _, _ in
                handleVisibilityChange()
            }
    }

    private var lifecycleBody: some View {
        presentedBody
            .onAppear {
                viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)
                isVisible = !viewModel.shouldHideWindowPresentation
                scheduleDetachmentHintPresentationIfNeeded(delay: Self.startupDetachmentHintDelay)
            }
            .onDisappear {
                cancelScheduledDetachmentHintPresentation()
            }
            .onChange(of: viewModel.status) { oldStatus, newStatus in
                handleStatusChange(from: oldStatus, to: newStatus)
            }
    }

    private var presentedBody: some View {
        bodyContent
            .offset(y: viewModel.closedPresentationOffsetY)
            .opacity(isVisible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .preferredColorScheme(.dark)
    }

    // MARK: - Body Content

    private var bodyContent: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                styledNotchLayout
            }

            if isShowingDetachmentHint {
                NotchDetachmentHintView()
                    .offset(x: -22, y: 28)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)),
                            removal: .opacity.animation(.easeOut(duration: 0.18))
                        )
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var styledNotchLayout: some View {
        let isOpened = viewModel.status == .opened
        let horizontalInset = isOpened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.bottom
        let shadowColor = (isOpened || isHovering) ? Color.black.opacity(0.7) : .clear

        return notchLayout
            .frame(maxWidth: isOpened ? notchSize.width : nil, alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding([.horizontal, .bottom], isOpened ? 12 : 0)
            .background(.black)
            .clipShape(currentNotchShape)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
            }
            .shadow(color: shadowColor, radius: 6)
            .frame(
                maxWidth: isOpened ? notchSize.width : nil,
                maxHeight: isOpened ? notchSize.height : nil,
                alignment: .top
            )
            .animation(isOpened ? openAnimation : closeAnimation, value: viewModel.status)
            .animation(viewModel.closedNotchResizeAnimation, value: notchSize)
            .animation(.smooth, value: activityCoordinator.expandingActivity)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .contentShape(Rectangle())
            .onHover { hovering in
                let shouldShowHoverFeedback = hovering && (isOpened || isInNotificationMoment)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                    isHovering = shouldShowHoverFeedback
                }
            }
            .onTapGesture {
                if !isOpened {
                    viewModel.notchOpen(reason: isInNotificationMoment ? .notification : .click)
                }
            }
    }

    // MARK: - Notch Layout

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .frame(height: max(24, closedNotchSize.height))
                .zIndex(1)

            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24)
                    .zIndex(0)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        Group {
            if shouldHideClosedContent {
                Color.clear
                    .frame(width: closedInnerWidth, height: closedNotchSize.height)
            } else {
                HStack(spacing: 0) {
                    // Left ear — plugin notification source during notification,
                    // otherwise the assigned plugin.
                    if viewModel.status != .opened {
                        ZStack {
                            if showsClosedNotificationSource,
                               let notification = activePluginNotification,
                               let plugin = installedPlugin(for: notification.pluginId) {
                                pluginSourceIcon(plugin, size: petIconSize)
                            } else if let pluginContent = pluginArbiter.activeLeft {
                                IslandPluginRenderer.compactView(content: pluginContent)
                                    .padding(.leading, compactLeftEarContentInset)
                            }
                        }
                        .offset(x: -compactEarOutset)
                        .frame(width: closedLeadingWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                presentAssignedPlugin(pluginArbiter.activeLeftPluginId ?? pluginArbiter.leftEarAssignment)
                            }
                        )
                    }

                    // Center content
                    if viewModel.status == .opened {
                        openedHeaderContent
                    } else {
                        closedCenterContent
                    }

                    // Right ear — notification bell during plugin notification,
                    // otherwise the assigned plugin.
                    if viewModel.status != .opened {
                        ZStack {
                            if isInNotificationMoment {
                                notificationIndicatorIcon(size: 12)
                            } else if let pluginContent = pluginArbiter.activeRight {
                                IslandPluginRenderer.compactView(content: pluginContent)
                            }
                        }
                        .offset(x: compactEarOutset)
                        .frame(width: closedTrailingWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture().onEnded {
                                presentAssignedPlugin(pluginArbiter.activeRightPluginId ?? pluginArbiter.rightEarAssignment)
                            }
                        )
                    }
                }
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    private var closedLeadingWidth: CGFloat {
        compactSlotWidth(for: pluginArbiter.activeLeft) + compactLeftEarContentInset + compactEarOutset
    }

    private func presentAssignedPlugin(_ pluginId: String?) {
        guard !isInNotificationMoment, let pluginId else { return }
        viewModel.presentPlugin(pluginId, reason: .click)
    }

    private var closedTrailingWidth: CGFloat {
        compactSlotWidth(for: pluginArbiter.activeRight) + compactEarOutset
    }

    private func compactSlotWidth(for content: PluginCompactContent?) -> CGFloat {
        guard let content else {
            return sideWidth
        }
        let labelWidth = CGFloat(content.label?.count ?? 0) * 6.3
        let iconWidth: CGFloat = content.icon == nil ? 0 : 11.5
        let badgeWidth: CGFloat = (content.badge ?? 0) > 0 ? 16 : 0
        let estimatedWidth = labelWidth + iconWidth + badgeWidth + 6
        return max(sideWidth, min(70, estimatedWidth))
    }

    private var closedCenterWidth: CGFloat {
        max(0, closedInnerWidth - closedLeadingWidth - closedTrailingWidth + (isBouncing ? 16 : 0))
    }

    private var compactCenterContentWidth: CGFloat {
        max(0, closedCenterWidth - compactCenterContentInset)
    }

    @ViewBuilder
    private var closedCenterContent: some View {
        HStack {
            Color.clear
                .frame(width: compactCenterContentWidth)
        }
        .frame(width: closedCenterWidth, alignment: .center)
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            if isInNotificationMoment,
               let notification = activePluginNotification,
               let plugin = installedPlugin(for: notification.pluginId) {
                pluginSourceIcon(plugin, size: petIconSize)
                    .padding(.leading, 14)
            }

            Spacer(minLength: 0)

            NotchSettingsButton(
                hasUnseenUpdate: updateManager.hasUnseenUpdate,
                action: openSettingsWindow
            )
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func notificationIndicatorIcon(size: CGFloat) -> some View {
        RingingBellIndicatorIcon(size: size + 2, color: .white.opacity(0.9))
    }

    @ViewBuilder
    private func pluginSourceIcon(_ plugin: InstalledPlugin, size: CGFloat) -> some View {
        if let iconPath = plugin.manifest.iconPath,
           let image = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let icon = plugin.manifest.icon {
            Image(systemName: icon.sfSymbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(Color(hex: icon.color) ?? .white.opacity(0.9))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func installedPlugin(for pluginId: String) -> InstalledPlugin? {
        PluginRegistry.shared.installedPlugins.first { $0.id == pluginId }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        IslandOpenedContentView(
            viewModel: viewModel,
            surface: .docked,
            trigger: triggerForCurrentPresentation,
            style: .docked,
            activePluginNotification: activePluginNotification,
            onDismissPluginNotification: {
                clearActivePluginNotification(keepPanelOpen: true)
            }
        )
        .frame(width: notchSize.width - 24)
    }

    private var triggerForCurrentPresentation: IslandExpandedTrigger {
        switch viewModel.openReason {
        case .hover:
            return .hover
        case .notification:
            return .notification
        case .click, .boot, .unknown:
            return .click
        }
    }

    // MARK: - Event Handlers

    private func handleVisibilityChange() {
        viewModel.updateIdleAutoHiddenState(hasVisibleSessionActivity: !shouldHideForIdleState)

        if viewModel.shouldHideWindowPresentation {
            isVisible = false
            return
        }

        activityCoordinator.hideActivity()
        isVisible = true
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            cancelScheduledDetachmentHintPresentation()
            dismissDetachmentHint()
            if oldStatus != .opened, newStatus == .opened {
                recordIslandOpened()
            }
        case .closed:
            if oldStatus == .opened {
                recordIslandClosed()
            }
            isVisible = !viewModel.shouldHideWindowPresentation
            scheduleDetachmentHintPresentationIfNeeded(delay: Self.detachmentHintRetryDelay)
        }
    }

    // MARK: - Plugin Notifications

    private func dequeuePluginNotification() {
        guard let update = PluginSlotArbiter.shared.dequeueNotification() else { return }
        pluginNotificationDismissWork?.cancel()
        pluginNotificationDismissWork = nil
        activePluginNotification = update
        viewModel.contentType = nil
        viewModel.notchOpen(reason: .notification)
    }

    private func clearActivePluginNotification(keepPanelOpen: Bool) {
        pluginNotificationDismissWork?.cancel()
        pluginNotificationDismissWork = nil
        guard activePluginNotification != nil else { return }
        withAnimation(.smooth) {
            activePluginNotification = nil
        }
        if !keepPanelOpen,
           viewModel.status == .opened,
           viewModel.openReason == .notification {
            viewModel.contentType = nil
            viewModel.notchClose()
        }

        if activePluginNotification == nil, !pluginArbiter.pendingNotifications.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                dequeuePluginNotification()
            }
        }
    }

    // MARK: - Detachment Hint

    private func scheduleDetachmentHintPresentationIfNeeded(force: Bool = false, delay: TimeInterval) {
        guard force || settings.notchDetachmentHintPending else {
            cancelScheduledDetachmentHintPresentation()
            return
        }

        detachmentHintPresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [force] in
            detachmentHintPresentationWorkItem = nil
            presentDetachmentHintIfNeeded(force: force)
        }
        detachmentHintPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelScheduledDetachmentHintPresentation() {
        detachmentHintPresentationWorkItem?.cancel()
        detachmentHintPresentationWorkItem = nil
    }

    private func presentDetachmentHintIfNeeded(force: Bool = false) {
        guard force || settings.notchDetachmentHintPending else { return }
        guard settings.surfaceMode == .notch else { return }
        guard viewModel.presentationMode == .docked else { return }
        guard viewModel.status == .closed else { return }
        guard !shouldHideClosedContent else { return }

        cancelScheduledDetachmentHintPresentation()
        settings.notchDetachmentHintPending = false
        detachmentHintDismissWorkItem?.cancel()

        if !isShowingDetachmentHint {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                isShowingDetachmentHint = true
            }
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) {
                isShowingDetachmentHint = false
            }
        }
        detachmentHintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func dismissDetachmentHint() {
        detachmentHintDismissWorkItem?.cancel()
        detachmentHintDismissWorkItem = nil
        guard isShowingDetachmentHint else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingDetachmentHint = false
        }
    }

    // MARK: - Telemetry

    private func recordIslandOpened() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandOpened(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private func recordIslandClosed() {
        let openSource = telemetryOpenSource(for: viewModel.openReason)
        let contentRoute = telemetryContentRoute(for: viewModel.contentType)
        let presentation = telemetryPresentationMode
        Task {
            await TelemetryService.shared.recordIslandClosed(
                openSource: openSource,
                contentRoute: contentRoute,
                presentation: presentation
            )
        }
    }

    private var telemetryPresentationMode: String {
        switch viewModel.presentationMode {
        case .docked:
            return "docked"
        case .detached:
            return "detached"
        }
    }

    private func telemetryOpenSource(for reason: NotchOpenReason) -> String {
        switch reason {
        case .click:
            return "click"
        case .hover:
            return "hover"
        case .notification:
            return "notification"
        case .boot:
            return "boot"
        case .unknown:
            return "unknown"
        }
    }

    private func telemetryContentRoute(for contentType: NotchContentType?) -> String {
        if activePluginNotification != nil {
            return "plugin_notification"
        }

        switch contentType {
        case .plugin:
            return "plugin_content"
        case .none:
            return "idle"
        }
    }

    // MARK: - Misc

    private func openSettingsWindow() {
        updateManager.markUpdateSeen()
        SettingsWindowController.shared.present()
    }
}

// MARK: - Private Views

private struct NotchDetachmentHintView: View {
    @State private var isArrowNudging = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StraightDetachHintArrow()
                .stroke(
                    Color.white.opacity(0.86),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 76, height: 40)
                .offset(
                    x: -36 + (isArrowNudging ? -4 : 4),
                    y: 2 + (isArrowNudging ? -3 : 3)
                )
                .onAppear {
                    isArrowNudging = false
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        isArrowNudging = true
                    }
                }
                .onDisappear {
                    isArrowNudging = false
                }

            Text(appLocalized: "拖动宠物，让宠物离岛工作")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.96))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.88))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
                .offset(y: 62)
        }
        .frame(width: 242, height: 118, alignment: .topTrailing)
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.string("拖动宠物，让宠物离岛工作")))
    }
}

private struct StraightDetachHintArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.maxX - 14, y: rect.maxY - 14)
        let end = CGPoint(x: rect.minX + 14, y: rect.minY + 16)

        path.move(to: start)
        path.addQuadCurve(
            to: end,
            control: CGPoint(x: rect.midX + 4, y: rect.midY + 6)
        )

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 12, y: end.y - 2))

        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x + 6, y: end.y + 11))

        return path
    }
}

private struct NotchSettingsButton: View {
    let hasUnseenUpdate: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovering ? .black : .white.opacity(0.92))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
                    )

                if hasUnseenUpdate {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black, lineWidth: 1.5)
                        )
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("设置")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct RingingBellIndicatorIcon: View {
    let size: CGFloat
    let color: Color

    @ObservedObject private var energyGovernor = EnergyGovernor.shared
    @State private var isRinging = false

    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: max(9, size - 3), weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isRinging ? 11 : -11), anchor: .top)
            .symbolEffect(.pulse, options: .repeating, value: isRinging)
            .shadow(color: color.opacity(0.28), radius: 3)
            .onAppear {
                guard energyGovernor.policy.animationLevel != .staticFrames else { return }
                withAnimation(.easeInOut(duration: 0.16).repeatForever(autoreverses: true)) {
                    isRinging = true
                }
            }
            .onDisappear {
                isRinging = false
            }
    }
}
