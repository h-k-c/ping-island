//
//  NotchViewModel.swift
//  PingIsland
//
//  State management for the dynamic island
//

import AppKit
import Combine
import SwiftUI

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

enum NotchOpenReason {
    case click
    case hover
    case notification
    case boot
    case unknown
}

enum NotchContentType: Equatable {
    case plugin(pluginId: String)

    var id: String {
        switch self {
        case .plugin(let id): return "plugin-\(id)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published private(set) var presentationMode: IslandPresentationMode = .docked
    @Published private(set) var detachedDisplayMode: DetachedIslandDisplayMode = .compact
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType?
    /// Screen-independent frames (window-local, SwiftUI top-left origin) of the
    /// recorder peek's tappable controls, keyed by plugin actionId. Reported by the
    /// SwiftUI island via the "notchWindow" coordinate space and consumed by the
    /// global mouse monitor to hit-test clicks (the peek window is click-through).
    @Published var recorderButtonFrames: [String: CGRect] = [:]
    @Published var isHovering: Bool = false
    /// Whether hovering the closed notch is allowed to auto-expand it. Idle states
    /// (ears just showing plugins) do not expand on hover; only notification
    /// moments do. Synced from NotchView's `isInNotificationMoment`.
    @Published var hoverExpansionAllowed: Bool = false
    @Published private(set) var openedMeasuredHeight: CGFloat?
    @Published private(set) var isFullscreenEdgeRevealActive = false
    @Published private(set) var isFullscreenPhysicalNotchCompactActive = false
    @Published private(set) var isFullscreenBrowserHiddenActive = false
    @Published private(set) var isIdleAutoHiddenActive = false
    @Published private(set) var isSettingsPopoverPresented = false
    @Published private(set) var isInlineTextInputActive = false

    // MARK: - Geometry

    @Published private(set) var geometry: NotchGeometry
    let spacing: CGFloat = 12
    @Published private(set) var hasPhysicalNotch: Bool

    private static let defaultClosedHeight = ScreenNotchMetrics.fallbackClosedHeight
    private static let defaultClosedWidth: CGFloat = 266
    // Preserve the visible side rails that the default closed island has beyond
    // the physical camera housing, so mascot/count content never sits under it.
    private static let physicalNotchContentAllowance: CGFloat =
        defaultClosedWidth - ScreenNotchMetrics.fallbackNotchWidth
    private static let clickedInstancesPanelWidthRatio: CGFloat = 0.44
    private static let clickedInstancesPanelMaximumWidth: CGFloat = 520
    private static let procMonitorPluginId = "com.auralink.procmonitor"
    private static let detachmentLongPressNarrowedWidthScale: CGFloat = 0.82
    private static let detachmentLongPressMaximumShrink: CGFloat = 56
    private static let closedCenterInteractionReduction: CGFloat = 40
    private static let closedCenterInteractionMinimumWidth: CGFloat = 132
    private static let closedToolHitPadding: CGFloat = 10
    @Published private(set) var closedWidth: CGFloat

    private enum ClosedEarClickTarget {
        case left(pluginId: String?)
        case right(pluginId: String?)

        var pluginId: String? {
            switch self {
            case .left(let pluginId), .right(let pluginId):
                return pluginId
            }
        }
    }

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }
    var closedHeight: CGFloat {
        usesPhysicalNotchClosedPresentation
            ? deviceNotchRect.height
            : detectedClosedHeight
    }
    var usesPhysicalNotchClosedPresentation: Bool {
        hasPhysicalNotch && isFullscreenPhysicalNotchCompactActive
    }
    var closedSize: CGSize {
        if usesPhysicalNotchClosedPresentation {
            return deviceNotchRect.size
        }
        return CGSize(width: closedWidth, height: closedHeight)
    }
    var closedScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - closedSize.width / 2,
            y: screenRect.maxY - closedSize.height,
            width: closedSize.width,
            height: closedSize.height
        )
    }

    private var detectedClosedHeight: CGFloat {
        guard hasPhysicalNotch else { return Self.defaultClosedHeight }
        let systemHeight = ceil(deviceNotchRect.height)
        return systemHeight > 0 ? systemHeight : Self.defaultClosedHeight
    }

    private var detectedClosedWidth: CGFloat {
        Self.detectedClosedWidth(
            deviceNotchRect: deviceNotchRect,
            hasPhysicalNotch: hasPhysicalNotch
        )
    }

    private static func detectedClosedWidth(
        deviceNotchRect: CGRect,
        hasPhysicalNotch: Bool
    ) -> CGFloat {
        guard hasPhysicalNotch else { return defaultClosedWidth }
        let systemWidth = ceil(deviceNotchRect.width)
        guard systemWidth > 0 else { return defaultClosedWidth }
        return max(defaultClosedWidth, systemWidth + physicalNotchContentAllowance)
    }

    static func shouldAutoCollapseHoverPreview(
        isHovering: Bool,
        status: NotchStatus,
        openReason: NotchOpenReason,
        isSettingsPopoverPresented: Bool,
        isInlineTextInputActive: Bool,
        autoCollapseOnLeave: Bool
    ) -> Bool {
        !isHovering
            && status == .opened
            && openReason == .hover
            && !isSettingsPopoverPresented
            && !isInlineTextInputActive
            && autoCollapseOnLeave
    }

    private var narrowedClosedWidth: CGFloat {
        if hasPhysicalNotch {
            let systemWidth = ceil(deviceNotchRect.width)
            if systemWidth > 0 {
                return systemWidth
            }
        }

        let baseWidth = detectedClosedWidth
        return max(
            baseWidth * Self.detachmentLongPressNarrowedWidthScale,
            baseWidth - Self.detachmentLongPressMaximumShrink
        )
    }

    private var dockedClosedWidthTarget: CGFloat {
        guard presentationMode == .docked, detachmentTracking != nil else {
            return detectedClosedWidth
        }
        return narrowedClosedWidth
    }

    /// Dynamic opened size based on content type
    var openedSize: CGSize {
        panelSize(for: .docked)
    }

    var detachedSize: CGSize {
        switch detachedDisplayMode {
        case .compact:
            return compactDetachedSize
        case .hoverExpanded:
            return expandedDetachedSize
        }
    }

    func panelSize(for style: IslandOpenedPresentationStyle) -> CGSize {
        let maxAllowedHeight = maximumOpenedHeight

        switch contentType {
        case .plugin, .none:
            let fallbackHeight: CGFloat = pluginPreferredFallbackHeight ?? (openReason == .hover ? 150 : 170)
            let measuredHeight = openedMeasuredHeight ?? fallbackHeight

            switch style {
            case .docked:
                return CGSize(
                    width: dockedPanelWidth,
                    height: min(maxAllowedHeight, max(closedHeight + 24, measuredHeight))
                )
            case .detached:
                return CGSize(
                    width: min(screenRect.width - 112, 400),
                    height: min(
                        maxAllowedHeight,
                        max(closedHeight + 24, min(measuredHeight, 300))
                    )
                )
            }
        }
    }

    private var pluginPreferredFallbackHeight: CGFloat? {
        if case .plugin(Self.procMonitorPluginId) = contentType { return 445 }
        // The recorder opens as a minimal peek bar; give it a small fallback so it
        // never flashes a tall panel before the real height is measured. When the
        // user expands it, allow more room.
        if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = contentType {
            // Both states are a single row now, so the height stays compact.
            return 38
        }
        return nil
    }

    /// True when the notch is currently showing the sticky-peek (recorder) plugin.
    private var currentlyDisplayedStickyPeekPlugin: Bool {
        if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = contentType { return true }
        return false
    }

    /// Collapse the recorder's expanded panel back to the peek bar. Invoked by the
    /// panel window when a left click lands on empty panel space (hitTest miss).
    func collapseStickyPeekIfNeeded() {
        guard status == .opened, currentlyDisplayedStickyPeekPlugin else { return }
        let arbiter = PluginSlotArbiter.shared
        guard arbiter.stickyPeekActive, arbiter.stickyPeekExpanded else { return }
        arbiter.stickyPeekExpanded = false
    }

    /// SwiftUI reports the recorder controls' frames in the "notchWindow" space
    /// (window-local, top-left origin). Store them for the mouse monitor to use.
    func updateRecorderButtonFrames(_ frames: [String: CGRect]) {
        guard frames != recorderButtonFrames else { return }
        recorderButtonFrames = frames
    }

    /// Reserved key under which the SwiftUI island reports the visible card's frame
    /// (so we can hit-test "tapped the island background" without resizing the
    /// window). Must not collide with any plugin actionId.
    static let recorderPanelFrameKey = "__recorderPanel__"

    /// Screen frame (bottom-left origin) of the recorder peek's VISIBLE window — the
    /// full notch window — matching the "notchWindow" coordinate space the SwiftUI
    /// button frames are reported in, so window-local frames map to screen correctly.
    private var recorderPeekScreenFrame: CGRect {
        let height = geometry.windowHeight
        return CGRect(
            x: screenRect.minX,
            y: screenRect.maxY - height,
            width: screenRect.width,
            height: height
        )
    }

    /// Map a window-local (SwiftUI top-left) frame to screen coordinates (bottom-left).
    private func recorderFrameToScreen(_ local: CGRect, window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + local.minX,
            y: window.maxY - (local.minY + local.height),
            width: local.width,
            height: local.height
        )
    }

    /// Screen rect of the visible recorder card, derived from the SwiftUI-reported
    /// panel frame (the actual rendered bounds — not the under-measured openedSize).
    /// The window controller sizes the invisible click-absorber to this so every
    /// control is covered and no tap on the island leaks through to the desktop.
    /// Padded slightly so rounded-corner edge taps are still absorbed.
    var recorderCardScreenFrame: CGRect? {
        guard let panel = recorderButtonFrames[Self.recorderPanelFrameKey] else { return nil }
        return recorderFrameToScreen(panel, window: recorderPeekScreenFrame).insetBy(dx: -6, dy: -6)
    }

    /// Hit-test a click (screen coordinates) against the recorder peek. Returns true
    /// when the click is consumed: either it landed on a control (whose action is
    /// dispatched) or on the island card itself (which toggles expand). Returns false
    /// when the click is outside the visible island so the caller can fall through.
    private func handleRecorderClick(at screenPoint: CGPoint) -> Bool {
        let window = recorderPeekScreenFrame
        // A click on a specific control fires that action.
        for (actionId, local) in recorderButtonFrames where actionId != Self.recorderPanelFrameKey {
            let buttonScreen = recorderFrameToScreen(local, window: window)
            if buttonScreen.insetBy(dx: -4, dy: -4).contains(screenPoint) {
                NotificationCenter.default.post(
                    name: .pluginButtonTapped, object: nil,
                    userInfo: ["pluginId": PluginSlotArbiter.stickyPeekPluginId, "actionId": actionId]
                )
                return true
            }
        }
        // Not on a button: a tap anywhere on the island card toggles expand/collapse
        // (reveals the auxiliary tools), matching the SwiftUI row's onTapGesture.
        if let panelLocal = recorderButtonFrames[Self.recorderPanelFrameKey] {
            let panelScreen = recorderFrameToScreen(panelLocal, window: window)
            if panelScreen.contains(screenPoint) {
                PluginSlotArbiter.shared.stickyPeekExpanded.toggle()
                return true
            }
        }
        return false
    }

    private var dockedPanelWidth: CGFloat {
        if openReason == .hover {
            return min(screenRect.width - 64, 600)
        }
        if case .plugin(Self.procMonitorPluginId) = contentType {
            return min(screenRect.width - 64, 414)
        }
        // The recorder peek shows status + timer + primary controls (pause / mic /
        // camera / stop); expanding reveals two more (annotate / screenshot), so the
        // bar widens to fit them.
        if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = contentType {
            if PluginSlotArbiter.shared.recorderFinished { return 360 }
            return PluginSlotArbiter.shared.stickyPeekExpanded ? 340 : 280
        }
        return min(
            screenRect.width * Self.clickedInstancesPanelWidthRatio,
            Self.clickedInstancesPanelMaximumWidth
        )
    }

    private var compactDetachedSize: CGSize {
        if AppSettings.notchDisplayMode == .detailed {
            return closedSize
        }

        let orbEdge = max(closedSize.height, 40)
        return CGSize(width: orbEdge, height: orbEdge)
    }

    private var expandedDetachedSize: CGSize {
        let maxAllowedHeight = maximumOpenedHeight
        let fallbackHeight: CGFloat = 220

        return CGSize(
            width: min(screenRect.width - 112, 400),
            height: min(maxAllowedHeight, max(closedHeight + 24, fallbackHeight))
        )
    }

    private var maximumOpenedHeight: CGFloat {
        let maxPanelHeight = CGFloat(AppSettings.maxPanelHeight)
        let screenLimit = screenRect.height - 120

        if openReason == .hover {
            return min(screenLimit, maxPanelHeight)
        }

        return min(screenLimit, maxPanelHeight)
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    var closedNotchResizeAnimation: Animation {
        if isDetachmentNarrowingClosedNotch {
            return .linear(duration: detachmentLongPressNarrowAnimationDuration)
        }
        return .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    }

    var isDetachmentNarrowingClosedNotch: Bool {
        presentationMode == .docked && detachmentTracking != nil && status != .opened
    }

    var isDetachmentGestureActive: Bool {
        presentationMode == .docked && detachmentTracking != nil
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events: EventMonitors?
    private let fullscreenActivityProvider: @MainActor (CGRect) -> Bool
    private let fullscreenBrowserHiddenProvider: @MainActor (CGRect) -> Bool
    private let hideInFullscreenProvider: @MainActor () -> Bool
    private let autoHideWhenIdleProvider: @MainActor () -> Bool
    private var hoverTimer: DispatchWorkItem?
    // Keep hover previews feeling responsive without making incidental cursor
    // passes over the notch expand it too aggressively.
    private let defaultHoverActivationDelay: TimeInterval = 0.24
    private let fullscreenHoverActivationDelay: TimeInterval = 0.18
    private let fullscreenRevealZoneHeight: CGFloat = 8
    private let fullscreenRevealZoneHorizontalInset: CGFloat = 36
    private let fullscreenStateSettleDelay: TimeInterval
    private var fullscreenPhysicalNotchCollapseWorkItem: DispatchWorkItem?
    private let detachmentLongPressDuration = IslandDetachmentGestureGate.defaultLongPressDuration
    private let detachmentLongPressNarrowAnimationDuration =
        IslandDetachmentGestureGate.defaultLongPressDuration * 20
    private let detachmentLongPressResetDuration: TimeInterval = 0.18
    private let detachmentTapMovementTolerance: CGFloat = 8
    private var detachmentLongPressWorkItem: DispatchWorkItem?

    var onDetachmentRequested: ((IslandDetachmentRequest) -> Void)?
    var onDetachmentUpdated: ((CGPoint) -> Void)?
    var onDetachmentFinished: ((CGPoint?) -> Void)?

    private struct DockedDetachmentTracking {
        let id: UUID
        let source: IslandDetachmentSource
        let startLocation: CGPoint
        var isLongPressSatisfied: Bool
        var hasExceededTapMovementTolerance: Bool
        var hasTriggeredDetachment: Bool
    }

    private var detachmentTracking: DockedDetachmentTracking?

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool,
        enableEventMonitoring: Bool = true,
        observeSystemEnvironment: Bool = true,
        fullscreenActivityProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenAppActive,
        hideInFullscreenProvider: @escaping @MainActor () -> Bool = { AppSettings.hideInFullscreen },
        fullscreenBrowserHiddenProvider: @escaping @MainActor (CGRect) -> Bool = FullscreenAppDetector.isFullscreenBrowserActive,
        autoHideWhenIdleProvider: @escaping @MainActor () -> Bool = { AppSettings.autoHideWhenIdle },
        fullscreenStateSettleDelay: TimeInterval = 0.18
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedWidth = Self.detectedClosedWidth(
            deviceNotchRect: deviceNotchRect,
            hasPhysicalNotch: hasPhysicalNotch
        )
        self.events = enableEventMonitoring ? EventMonitors.shared : nil
        self.fullscreenActivityProvider = fullscreenActivityProvider
        self.fullscreenBrowserHiddenProvider = fullscreenBrowserHiddenProvider
        self.hideInFullscreenProvider = hideInFullscreenProvider
        self.autoHideWhenIdleProvider = autoHideWhenIdleProvider
        self.fullscreenStateSettleDelay = fullscreenStateSettleDelay
        if enableEventMonitoring {
            setupEventHandlers()
        }
        if observeSystemEnvironment {
            observeEnvironment()
        }
        refreshFullscreenPresentationState()
    }

    #if compiler(>=6.3)
    // Keep teardown outside MainActor isolation; Xcode 26 can otherwise abort
    // while destroying this view model in unit-test scope teardown.
    nonisolated deinit {}
    #endif

    func updateScreenGeometry(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        windowHeight: CGFloat,
        hasPhysicalNotch: Bool
    ) {
        let updatedGeometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            windowHeight: windowHeight
        )
        let geometryChanged = updatedGeometry != geometry || hasPhysicalNotch != self.hasPhysicalNotch
        guard geometryChanged else { return }

        geometry = updatedGeometry
        self.hasPhysicalNotch = hasPhysicalNotch
        openedMeasuredHeight = nil
        syncClosedWidth(animated: false)
        refreshFullscreenPresentationState()
    }

    private func observeEnvironment() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$hideInFullscreen
            .sink { [weak self] _ in
                self?.refreshFullscreenPresentationState()
            }
            .store(in: &cancellables)

        AppSettings.shared.$autoHideWhenIdle
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$maxPanelHeight
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func refreshFullscreenPresentationState() {
        let isFullscreenActive = fullscreenActivityProvider(screenRect)
        let shouldHideForFullscreenBrowser = fullscreenBrowserHiddenProvider(screenRect)
        let shouldUseEdgeReveal = shouldUseFullscreenEdgeReveal(isFullscreenActive: isFullscreenActive)
        let shouldUsePhysicalNotchCompact = shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive)

        if shouldHideForFullscreenBrowser != isFullscreenBrowserHiddenActive {
            isFullscreenBrowserHiddenActive = shouldHideForFullscreenBrowser
        }

        applyPhysicalNotchFullscreenState(shouldUsePhysicalNotchCompact)

        guard shouldUseEdgeReveal != isFullscreenEdgeRevealActive else { return }
        isFullscreenEdgeRevealActive = shouldUseEdgeReveal

        if shouldUseEdgeReveal {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }

        if shouldHideForFullscreenBrowser {
            hoverTimer?.cancel()
            hoverTimer = nil
            isHovering = false
            if status == .opened {
                notchClose()
            }
        }
    }

    func refreshFullscreenPresentationStateForTesting() {
        refreshFullscreenPresentationState()
    }

    private func applyPhysicalNotchFullscreenState(_ shouldUsePhysicalNotchCompact: Bool) {
        if shouldUsePhysicalNotchCompact {
            fullscreenPhysicalNotchCollapseWorkItem?.cancel()
            fullscreenPhysicalNotchCollapseWorkItem = nil
            if !isFullscreenPhysicalNotchCompactActive {
                isFullscreenPhysicalNotchCompactActive = true
            }
            return
        }

        guard isFullscreenPhysicalNotchCompactActive else { return }

        fullscreenPhysicalNotchCollapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fullscreenPhysicalNotchCollapseWorkItem = nil
            let isFullscreenActive = self.fullscreenActivityProvider(self.screenRect)
            if self.shouldUsePhysicalNotchCompact(isFullscreenActive: isFullscreenActive) {
                self.isFullscreenPhysicalNotchCompactActive = true
            } else {
                self.isFullscreenPhysicalNotchCompactActive = false
            }
        }
        fullscreenPhysicalNotchCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenStateSettleDelay, execute: workItem)
    }

    private func shouldUseFullscreenEdgeReveal(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider() && !hasPhysicalNotch && isFullscreenActive
    }

    private func shouldUsePhysicalNotchCompact(isFullscreenActive: Bool) -> Bool {
        hideInFullscreenProvider()
            && hasPhysicalNotch
            && isFullscreenActive
            && !isFullscreenBrowserHiddenActive
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        guard let events else { return }

        events.mouseLocation
            .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDown(event)
            }
            .store(in: &cancellables)

        events.mouseDragged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseDragged(event)
            }
            .store(in: &cancellables)

        events.mouseUp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleMouseUp(event)
            }
            .store(in: &cancellables)
    }

    /// Whether we're in chat mode.
    private var isInChatMode: Bool {
        return false
    }

    private func handleMouseMove(_ location: CGPoint) {
        guard presentationMode == .docked else { return }

        let inNotch = isPointInHoverTrigger(location)
        // For recorder peek, extend the hover zone 30 px below the panel so the
        // cursor entering from below activates hover well before reaching the buttons,
        // giving the 16 ms throttle enough lead time to fire ignoresMouseEvents = false.
        var hoverSize = openedSize
        if status == .opened, case .plugin(PluginSlotArbiter.stickyPeekPluginId) = contentType {
            hoverSize.height += 30
        }
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: hoverSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders
        guard newHovering != isHovering else { return }

        isHovering = newHovering

        // Cancel any pending hover timer
        hoverTimer?.cancel()
        hoverTimer = nil

        if Self.shouldAutoCollapseHoverPreview(
            isHovering: newHovering,
            status: status,
            openReason: openReason,
            isSettingsPopoverPresented: isSettingsPopoverPresented,
            isInlineTextInputActive: isInlineTextInputActive,
            autoCollapseOnLeave: AppSettings.autoCollapseOnLeave
        ) {
            notchClose()
        }

        // Start hover timer to auto-expand after a short dwell
        if isHovering && (status == .closed || status == .popping) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.performDeferredHoverOpenIfNeeded()
            }
            hoverTimer = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverActivationDelay, execute: workItem)
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard presentationMode == .docked else { return }

        if isSettingsPopoverPresented {
            return
        }

        if MouseEventReplay.isReplayed(event) {
            return
        }

        let location = NSEvent.mouseLocation

        switch status {
        case .opened:
            if currentlyDisplayedStickyPeekPlugin {
                // Recorder peek: the window is fully click-through, so its controls
                // are driven here by coordinate hit-testing against the SwiftUI-
                // reported button frames (just like the closed-state ears). A click
                // on a button fires that action; a click elsewhere inside the island
                // toggles expand/collapse.
                if handleRecorderClick(at: location) {
                    return
                }
                // The click landed outside the island region.
                if PluginSlotArbiter.shared.stickyPeekActive {
                    // A recording is in progress — never tear down the live activity.
                    return
                }
                if PluginSlotArbiter.shared.recorderFinished {
                    // Dismiss the finished result (resets the recorder to idle and
                    // restores the pill) and close.
                    NotificationCenter.default.post(
                        name: .pluginButtonTapped, object: nil,
                        userInfo: ["pluginId": PluginSlotArbiter.stickyPeekPluginId, "actionId": "dismiss"]
                    )
                    notchClose()
                    return
                }
                notchClose()
                return
            }

            if detachmentTriggerScreenRect.contains(location) {
                beginDockedDetachmentTracking(source: .opened, startLocation: location)
            } else if geometry.isPointOutsidePanel(location, size: openedSize) {
                if PluginSlotArbiter.shared.stickyPeekActive {
                    // The user had detoured to an ear plugin while recording; return
                    // to the recorder peek instead of closing (which would orphan the
                    // recording).
                    PluginSlotArbiter.shared.stickyPeekExpanded = false
                    presentPlugin(PluginSlotArbiter.stickyPeekPluginId, reason: .click)
                } else {
                    notchClose()
                }
            }
        case .closed, .popping:
            if let earTarget = closedEarClickTarget(at: location) {
                if let pluginId = earTarget.pluginId {
                    presentPlugin(pluginId, reason: .click)
                }
            } else if detachmentTriggerScreenRect.contains(location) {
                beginDockedDetachmentTracking(source: .closed, startLocation: location)
            } else if isPointInHoverTrigger(location), hasExpandedContent {
                // Only enlarge if the center plugin actually has content to show.
                // contentType being set is not enough — the plugin may have no
                // expanded sections (e.g. after a notification was dismissed), which
                // would open an empty black panel.
                notchOpen(reason: .click)
            }
        }
    }

    /// True when the center of the island has actual expanded content to show.
    /// Prevents opening an empty black panel when contentType is stale or the
    /// assigned plugin has no current sections.
    private var hasExpandedContent: Bool {
        guard case .plugin(let id) = contentType else { return false }
        // procmonitor generates its own content without using expandedContent
        if id == "com.auralink.procmonitor" { return true }
        return !(PluginSlotArbiter.shared.expandedContent[id]?.isEmpty ?? true)
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }
        guard var tracking = detachmentTracking else { return }

        let location = NSEvent.mouseLocation

        if !tracking.isLongPressSatisfied {
            let horizontalDistance = abs(location.x - tracking.startLocation.x)
            let verticalDistance = abs(location.y - tracking.startLocation.y)
            if max(horizontalDistance, verticalDistance) > detachmentTapMovementTolerance {
                tracking.hasExceededTapMovementTolerance = true
            }
            detachmentTracking = tracking
            return
        }

        guard IslandDetachmentGestureGate.qualifies(
            start: tracking.startLocation,
            current: location,
            hasSatisfiedLongPress: tracking.isLongPressSatisfied
        ) else {
            detachmentTracking = tracking
            return
        }

        if tracking.hasTriggeredDetachment {
            onDetachmentUpdated?(location)
        } else {
            tracking.hasTriggeredDetachment = true
            onDetachmentRequested?(
                IslandDetachmentRequest(
                    source: tracking.source,
                    dragStartScreenLocation: tracking.startLocation,
                    currentScreenLocation: location
                )
            )
        }

        detachmentTracking = tracking
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard presentationMode == .docked || detachmentTracking?.hasTriggeredDetachment == true else { return }
        guard let tracking = detachmentTracking else { return }

        let location = NSEvent.mouseLocation
        if tracking.hasTriggeredDetachment {
            onDetachmentFinished?(location)
        } else if tracking.source == .closed,
                  !tracking.isLongPressSatisfied,
                  !tracking.hasExceededTapMovementTolerance,
                  detachmentTriggerScreenRect.contains(location) {
            notchOpen(reason: .click)
        } else if tracking.source == .opened,
                  !tracking.isLongPressSatisfied,
                  !tracking.hasExceededTapMovementTolerance,
                  detachmentTriggerScreenRect.contains(location),
                  !isInChatMode {
            notchClose()
        }

        cancelDockedDetachmentTracking()
    }

    private func beginDockedDetachmentTracking(
        source: IslandDetachmentSource,
        startLocation: CGPoint
    ) {
        hoverTimer?.cancel()
        hoverTimer = nil
        cancelDockedDetachmentTracking()

        let trackingID = UUID()
        detachmentTracking = DockedDetachmentTracking(
            id: trackingID,
            source: source,
            startLocation: startLocation,
            isLongPressSatisfied: false,
            hasExceededTapMovementTolerance: false,
            hasTriggeredDetachment: false
        )
        syncClosedWidth(
            animated: true,
            animation: .linear(duration: detachmentLongPressNarrowAnimationDuration)
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var tracking = self.detachmentTracking, tracking.id == trackingID else { return }
            tracking.isLongPressSatisfied = true
            self.detachmentTracking = tracking
            self.detachmentLongPressWorkItem = nil
            if tracking.source == .opened {
                self.notchClose()
            }
        }
        detachmentLongPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + detachmentLongPressDuration, execute: workItem)
    }

    private func cancelDockedDetachmentTracking() {
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(
            animated: true,
            animation: .easeOut(duration: detachmentLongPressResetDuration)
        )
    }

    private var hoverActivationDelay: TimeInterval {
        isFullscreenEdgeRevealActive ? fullscreenHoverActivationDelay : defaultHoverActivationDelay
    }

    var shouldHideWindowPresentation: Bool {
        if presentationMode == .detached {
            return true
        }
        if isFullscreenBrowserHiddenActive {
            return true
        }
        if isFullscreenEdgeRevealActive && status != .opened {
            return true
        }
        if isIdleAutoHiddenActive && status != .opened {
            return true
        }
        return false
    }

    var shouldHideClosedPresentation: Bool {
        shouldHideWindowPresentation
    }

    var shouldSuppressAutomaticPresentation: Bool {
        presentationMode == .detached
            || isFullscreenBrowserHiddenActive
            || (isFullscreenEdgeRevealActive && status != .opened)
    }

    var closedPresentationOffsetY: CGFloat {
        shouldHideWindowPresentation ? -(closedHeight + 12) : 0
    }

    func isPointInHoverTrigger(_ point: CGPoint) -> Bool {
        if shouldHideClosedPresentation {
            return fullscreenRevealTriggerRect.contains(point)
        }
        if hoverExpansionAllowed {
            return isPointInClosedNotch(point)
        }
        return closedCenterInteractionRect.insetBy(dx: 0, dy: -5).contains(point)
    }

    private func isPointInClosedNotch(_ point: CGPoint) -> Bool {
        closedScreenRect.insetBy(dx: -10, dy: -5).contains(point)
    }

    private func closedEarClickTarget(at point: CGPoint) -> ClosedEarClickTarget? {
        guard !hoverExpansionAllowed else { return nil }
        guard closedScreenRect.insetBy(dx: -10, dy: -5).contains(point) else { return nil }

        let arbiter = PluginSlotArbiter.shared
        if closedLeftToolInteractionRect.contains(point) {
            return .left(pluginId: arbiter.activeLeftPluginId ?? arbiter.leftEarAssignment)
        }
        if closedRightToolInteractionRect.contains(point) {
            return .right(pluginId: arbiter.activeRightPluginId ?? arbiter.rightEarAssignment)
        }
        return nil
    }

    private var closedCenterInteractionRect: CGRect {
        let detectedCenterWidth = min(
            closedScreenRect.width,
            max(geometry.notchScreenRect.width, ScreenNotchMetrics.fallbackNotchWidth)
        )
        let protectedCenterWidth = max(
            Self.closedCenterInteractionMinimumWidth,
            detectedCenterWidth - Self.closedCenterInteractionReduction
        )
        return CGRect(
            x: screenRect.midX - protectedCenterWidth / 2,
            y: closedScreenRect.minY,
            width: protectedCenterWidth,
            height: closedScreenRect.height
        )
    }

    private var closedLeftToolInteractionRect: CGRect {
        let centerRect = closedCenterInteractionRect
        return CGRect(
            x: closedScreenRect.minX - Self.closedToolHitPadding,
            y: closedScreenRect.minY - 5,
            width: max(0, centerRect.minX - closedScreenRect.minX) + Self.closedToolHitPadding,
            height: closedScreenRect.height + 10
        )
    }

    private var closedRightToolInteractionRect: CGRect {
        let centerRect = closedCenterInteractionRect
        return CGRect(
            x: centerRect.maxX,
            y: closedScreenRect.minY - 5,
            width: max(0, closedScreenRect.maxX - centerRect.maxX) + Self.closedToolHitPadding,
            height: closedScreenRect.height + 10
        )
    }

    func updateIdleAutoHiddenState(hasVisibleSessionActivity: Bool) {
        let shouldHide = autoHideWhenIdleProvider() && !hasVisibleSessionActivity
        if shouldHide != isIdleAutoHiddenActive {
            isIdleAutoHiddenActive = shouldHide
        }
    }

    private var fullscreenRevealTriggerRect: CGRect {
        let width = closedSize.width + (fullscreenRevealZoneHorizontalInset * 2)
        return CGRect(
            x: screenRect.midX - width / 2,
            y: screenRect.maxY - fullscreenRevealZoneHeight,
            width: width,
            height: fullscreenRevealZoneHeight
        )
    }

    var detachmentTriggerScreenRect: CGRect {
        geometry.notchScreenRect
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        hoverTimer?.cancel()
        hoverTimer = nil

        if reason == .notification && shouldSuppressAutomaticPresentation {
            return
        }

        openReason = reason
        status = .opened
        openedMeasuredHeight = nil
    }

    func performDeferredHoverOpenIfNeeded() {
        guard isHovering else { return }
        // Idle notch (ears showing plugins) stays compact on hover; only expand
        // when a notification/attention moment is active.
        guard hoverExpansionAllowed else { return }
        guard status == .closed || status == .popping else { return }
        notchOpen(reason: .hover)
    }

    func notchClose() {
        status = .closed
        openedMeasuredHeight = nil
        isInlineTextInputActive = false
    }

    func beginDetachedPresentation(contentType: NotchContentType?, playSound: Bool = true) {
        hoverTimer?.cancel()
        hoverTimer = nil
        detachmentLongPressWorkItem?.cancel()
        detachmentLongPressWorkItem = nil
        detachmentTracking = nil
        syncClosedWidth(animated: false)
        isHovering = false
        detachedDisplayMode = .compact
        openedMeasuredHeight = nil

        self.contentType = contentType
        openReason = .click
        status = .opened
        presentationMode = .detached
        if playSound {
            AppSettings.playDetachedCapsuleSound()
        }
    }

    func setDetachedDisplayMode(_ mode: DetachedIslandDisplayMode) {
        guard presentationMode == .detached else { return }
        guard detachedDisplayMode != mode else { return }
        detachedDisplayMode = mode
        if mode == .compact {
            openedMeasuredHeight = nil
        }
    }

    func redockAfterDetached() {
        cancelDockedDetachmentTracking()
        detachedDisplayMode = .compact
        notchClose()
        presentationMode = .docked
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func setSettingsPopoverPresented(_ isPresented: Bool) {
        isSettingsPopoverPresented = isPresented
    }

    func setInlineTextInputActive(_ isActive: Bool) {
        guard isInlineTextInputActive != isActive else { return }
        isInlineTextInputActive = isActive
    }

    func presentPlugin(_ pluginId: String, reason: NotchOpenReason = .click) {
        openedMeasuredHeight = nil
        contentType = .plugin(pluginId: pluginId)
        notchOpen(reason: reason)
    }

    func updateOpenedMeasuredHeight(_ height: CGFloat?) {
        let sanitized = height.map { max(closedHeight, ceil($0)) }

        guard sanitized != openedMeasuredHeight else { return }
        openedMeasuredHeight = sanitized
    }

    func setManualAttentionActive(_ isActive: Bool) {
        syncClosedWidth(animated: false)
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        guard !shouldSuppressAutomaticPresentation else { return }
        notchOpen(reason: .boot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.openReason == .boot else { return }
            self.notchClose()
        }
    }

    private func syncClosedWidth(
        animated: Bool,
        animation: Animation? = nil
    ) {
        let targetWidth = dockedClosedWidthTarget
        guard closedWidth != targetWidth else { return }

        if animated, let animation {
            withAnimation(animation) {
                closedWidth = targetWidth
            }
        } else {
            closedWidth = targetWidth
        }
    }

#if DEBUG
    func beginDockedDetachmentTrackingForTesting(
        source: IslandDetachmentSource = .closed,
        startLocation: CGPoint = .zero
    ) {
        beginDockedDetachmentTracking(source: source, startLocation: startLocation)
    }

    func cancelDockedDetachmentTrackingForTesting() {
        cancelDockedDetachmentTracking()
    }
#endif
}
