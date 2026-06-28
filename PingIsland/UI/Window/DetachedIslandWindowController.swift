import AppKit
import Combine
import SwiftUI

final class DetachedIslandWindow: NSWindow {
    var petMouseDownHandler: ((NSEvent) -> Bool)?
    var petMouseDraggedHandler: ((NSEvent) -> Bool)?
    var petMouseUpHandler: ((NSEvent) -> Bool)?
    var petRightMouseDownHandler: ((NSEvent) -> Bool)?
    var petRightMouseUpHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        let handled: Bool = switch event.type {
        case .leftMouseDown:
            petMouseDownHandler?(event) ?? false
        case .leftMouseDragged:
            petMouseDraggedHandler?(event) ?? false
        case .leftMouseUp:
            petMouseUpHandler?(event) ?? false
        case .rightMouseDown:
            petRightMouseDownHandler?(event) ?? false
        case .rightMouseUp:
            petRightMouseUpHandler?(event) ?? false
        default:
            false
        }

        guard !handled else { return }
        super.sendEvent(event)
    }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func configureTransparency() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

@MainActor
final class DetachedIslandViewController: NSViewController {
    private let viewModel: NotchViewModel
    private let interactionModel: DetachedIslandInteractionModel
    private let bubbleViewState: DetachedIslandBubbleViewState
    private let onClose: () -> Void
    var onPetTap: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragStarted: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragChanged: (CGSize) -> Void = { _ in } {
        didSet { refreshRootViewIfLoaded() }
    }
    var onPetDragEnded: () -> Void = {} {
        didSet { refreshRootViewIfLoaded() }
    }
    var onBubbleHoverChanged: (Bool) -> Void = { _ in } {
        didSet { refreshRootViewIfLoaded() }
    }
    private var hostingView: TransparentHostingView<AppLocalizedRootView<DetachedIslandPanelView>>!

    init(
        viewModel: NotchViewModel,
        interactionModel: DetachedIslandInteractionModel,
        bubbleViewState: DetachedIslandBubbleViewState,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.interactionModel = interactionModel
        self.bubbleViewState = bubbleViewState
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = TransparentHostingView(rootView: makeRootView())

        self.view = hostingView
    }

    private func makeRootView() -> AppLocalizedRootView<DetachedIslandPanelView> {
        AppLocalizedRootView {
            DetachedIslandPanelView(
                viewModel: viewModel,
                interactionModel: interactionModel,
                bubbleViewState: bubbleViewState,
                onClose: onClose,
                onPetTap: onPetTap,
                onPetDragStarted: onPetDragStarted,
                onPetDragChanged: onPetDragChanged,
                onPetDragEnded: onPetDragEnded,
                onBubbleHoverChanged: onBubbleHoverChanged
            )
        }
    }

    private func refreshRootViewIfLoaded() {
        guard hostingView != nil else { return }
        hostingView.rootView = makeRootView()
    }
}

@MainActor
final class DetachedIslandWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultTrailingInset: CGFloat = 32
    private static let defaultBottomInset: CGFloat = 48

    private let viewModel: NotchViewModel
    private let onClose: () -> Void
    private let onPetAnchorChanged: (CGPoint) -> Void
    private let interactionModel = DetachedIslandInteractionModel()
    private let bubbleViewState = DetachedIslandBubbleViewState()
    private let detachedViewController: DetachedIslandViewController
    private var lastAppliedLayout: DetachedIslandWindowLayout
    private var cancellables = Set<AnyCancellable>()
    private var isWindowSizeUpdateScheduled = false
    private var isApplyingWindowSizeUpdate = false
    private var hasPendingWindowSizeUpdate = false
    private var interactionActivationWorkItem: DispatchWorkItem?
    private var bubbleVisibilityWorkItem: DispatchWorkItem?
    private var bubbleHoverGraceWorkItem: DispatchWorkItem?
    private var floatingSettingsHintDismissWorkItem: DispatchWorkItem?
    private var outsideClickMonitor: EventMonitor?
    private var floatingDragStartOrigin: CGPoint?
    private var petMouseDownPoint: CGPoint?
    private var petMouseDownScreenPoint: CGPoint?
    private var isPetDragActive = false
    private var isPetSecondaryClickArmed = false
    var bubbleHoverGraceDelay: TimeInterval = 3
    private var currentGuideBubbleSize: CGSize? {
        interactionModel.isSettingsHintVisible ? DetachedIslandPanelMetrics.settingsHintBubbleSize : nil
    }

    init(
        viewModel: NotchViewModel,
        onClose: @escaping () -> Void,
        onPetAnchorChanged: @escaping (CGPoint) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
        self.onPetAnchorChanged = onPetAnchorChanged
        self.lastAppliedLayout = Self.windowLayout(
            for: viewModel
        )

        let initialContentSize = lastAppliedLayout.containerSize
        let hostingController = DetachedIslandViewController(
            viewModel: viewModel,
            interactionModel: interactionModel,
            bubbleViewState: bubbleViewState,
            onClose: onClose
        )
        hostingController.loadViewIfNeeded()
        self.detachedViewController = hostingController

        let window = DetachedIslandWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        hostingController.view.frame = NSRect(origin: .zero, size: initialContentSize)
        hostingController.view.autoresizingMask = [.width, .height]
        window.contentView = hostingController.view
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // Keep shadow rendering inside SwiftUI content; window-level shadow on a transparent
        // borderless window produces jagged outlines around the composited alpha edges.
        window.hasShadow = false
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = true
        // Keep the detached pet visible above fullscreen apps and across spaces.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)

        hostingController.onPetTap = { [weak self] in
            self?.handlePetTap()
        }
        hostingController.onPetDragStarted = { [weak self] in
            self?.beginFloatingDrag()
        }
        hostingController.onPetDragChanged = { [weak self] translation in
            self?.updateFloatingDrag(translation: translation)
        }
        hostingController.onPetDragEnded = { [weak self] in
            self?.endFloatingDrag()
        }
        hostingController.onBubbleHoverChanged = { [weak self] isHovering in
            self?.handleBubbleHoverChanged(isHovering)
        }
        window.petMouseDownHandler = { [weak self] event in
            self?.handlePetMouseDown(event) ?? false
        }
        window.petMouseDraggedHandler = { [weak self] event in
            self?.handlePetMouseDragged(event) ?? false
        }
        window.petMouseUpHandler = { [weak self] event in
            self?.handlePetMouseUp(event) ?? false
        }
        window.petRightMouseDownHandler = { [weak self] event in
            self?.handlePetRightMouseDown(event) ?? false
        }
        window.petRightMouseUpHandler = { [weak self] event in
            self?.handlePetRightMouseUp(event) ?? false
        }

        window.delegate = self
        bindWindowSizeUpdates()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(
        at origin: CGPoint,
        activatesApplication: Bool = true,
        presentsAutomaticContent: Bool = true
    ) {
        guard let window else { return }
        suppressInteraction()
        lastAppliedLayout = Self.windowLayout(
            for: viewModel,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: bubbleViewState.measuredCompletionBubbleHeight,
            guideBubbleSize: currentGuideBubbleSize
        )
        let initialFrame = NSRect(
            origin: origin,
            size: lastAppliedLayout.containerSize
        )
        window.setFrame(initialFrame, display: false)
        updateBubblePlacementForCurrentWindow()
        showWindow(
            window,
            activatesApplication: activatesApplication
        )
        if presentsAutomaticContent {
            presentFloatingSettingsHintIfNeeded()
        }
    }

    func present(
        atPetAnchor petAnchor: CGPoint,
        activatesApplication: Bool = true,
        presentsAutomaticContent: Bool = true
    ) {
        guard let window else { return }
        suppressInteraction()
        lastAppliedLayout = Self.windowLayout(
            for: viewModel,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: bubbleViewState.measuredCompletionBubbleHeight,
            guideBubbleSize: currentGuideBubbleSize,
            petAnchorScreen: petAnchor,
            availableFrame: availableFrame(for: petAnchor)
        )
        let origin = Self.windowOrigin(
            preservingPetAnchorAt: petAnchor,
            layout: lastAppliedLayout
        )
        let frame = NSRect(origin: origin, size: lastAppliedLayout.containerSize)
        window.setFrame(frame, display: false)
        updateBubblePlacementForCurrentWindow()
        showWindow(
            window,
            activatesApplication: activatesApplication
        )
        if presentsAutomaticContent {
            presentFloatingSettingsHintIfNeeded()
        }
    }

    private func showWindow(
        _ window: NSWindow,
        activatesApplication: Bool
    ) {
        if activatesApplication {
            NSApp.activate(ignoringOtherApps: false)
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    var currentPetAnchor: CGPoint? {
        guard let window else { return nil }
        return Self.petAnchorScreenPoint(for: window.frame, layout: lastAppliedLayout)
    }

    var currentExpandedRoute: IslandExpandedRoute? {
        guard let bubbleContentMode = interactionModel.bubbleContentMode else { return nil }
        return DetachedIslandContentModel.route(
            for: [],
            viewModel: viewModel,
            mode: bubbleContentMode,
        )
    }

    func activateInteraction() {
        interactionActivationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            self.interactionActivationWorkItem = nil
            window.ignoresMouseEvents = false
        }

        interactionActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func updateDragPosition(
        cursorLocation: CGPoint,
        cursorWindowOffset: CGPoint
    ) {
        guard let window else { return }
        suppressInteraction()
        interactionModel.resetForDragSuppression()
        hideBubbleRenderingImmediately()
        let contentSize = window.frame.size
        let origin = Self.windowOrigin(
            for: cursorLocation,
            cursorWindowOffset: cursorWindowOffset,
            windowSize: contentSize
        )
        window.setFrameOrigin(origin)
        updateBubblePlacementForCurrentWindow()
    }

    func beginFloatingDrag() {
        guard floatingDragStartOrigin == nil else { return }
        cancelInteractionActivation()
        interactionModel.resetForDragSuppression()
        interactionModel.setPetDragging(true)
        hideBubbleRenderingImmediately()
        floatingDragStartOrigin = window?.frame.origin
    }

    func updateFloatingDrag(translation: CGSize) {
        guard let window else { return }

        if floatingDragStartOrigin == nil {
            beginFloatingDrag()
        }

        guard let startOrigin = floatingDragStartOrigin else { return }
        let origin = CGPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y + translation.height
        )
        window.setFrameOrigin(origin)
        updateBubblePlacementForCurrentWindow()
    }

    func endFloatingDrag() {
        floatingDragStartOrigin = nil
        interactionModel.setPetDragging(false)
        if let currentPetAnchor {
            onPetAnchorChanged(currentPetAnchor)
        }
        activateInteraction()
    }

    func handlePetSecondaryClick() {
        dismissFloatingSettingsHint()
        SettingsWindowController.shared.present()
    }

    func presentHoverBubbleForTesting() {
        let canPresentBubble = DetachedIslandContentModel.canPresentBubble(
            from: [],
            mode: .hoverPreview,
        )
        applyBubbleStateChange {
            interactionModel.presentHoverPreview(canPresentBubble: canPresentBubble)
        }
    }

    func togglePinnedBubbleForTesting() {
        let canPresentBubble = DetachedIslandContentModel.canPresentBubble(
            from: [],
            mode: .pinnedList
        )
        applyBubbleStateChange {
            interactionModel.togglePinned(canPresentBubble: canPresentBubble)
        }
    }

    func hideBubbleForTesting() {
        applyBubbleStateChange {
            interactionModel.hidePinnedBubble()
        }
    }

    func simulatePetTapForTesting() {
        handlePetTap()
    }

    func simulateBubbleHoverForTesting(_ isHovering: Bool) {
        handleBubbleHoverChanged(isHovering)
    }

    func simulateOutsideBubbleClickForTesting(screenLocation: CGPoint) {
        handlePotentialOutsideClick(screenLocation: screenLocation)
    }

    func dismissAttentionBubble() {
        applyBubbleStateChange {
            interactionModel.hidePinnedBubble()
        }
    }

    var renderedBubbleStateForTesting: DetachedIslandBubbleState {
        bubbleViewState.renderedBubbleState
    }

    var isBubbleVisibleForTesting: Bool {
        bubbleViewState.isBubbleVisible
    }

    var isPetDraggingForTesting: Bool {
        interactionModel.isPetDragging
    }


    func dismiss() {
        interactionActivationWorkItem?.cancel()
        interactionActivationWorkItem = nil
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil
        bubbleHoverGraceWorkItem?.cancel()
        bubbleHoverGraceWorkItem = nil
        floatingSettingsHintDismissWorkItem?.cancel()
        floatingSettingsHintDismissWorkItem = nil
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
        floatingDragStartOrigin = nil
        interactionModel.setPetDragging(false)
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }

    private func bindWindowSizeUpdates() {
        viewModel.$contentType
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        bubbleViewState.$measuredAttentionBubbleHeight
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        bubbleViewState.$measuredCompletionBubbleHeight
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        interactionModel.$bubbleState
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bubbleState in
                self?.syncBubblePresentation(to: bubbleState)
                self?.syncOutsideClickMonitor()
            }
            .store(in: &cancellables)

        interactionModel.$bubblePlacement
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        AppSettings.shared.$notchDisplayMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileBubbleStateWithAvailableContent()
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

        AppSettings.shared.$floatingPetSizeMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleWindowSizeUpdate()
            }
            .store(in: &cancellables)

    }

    private func scheduleWindowSizeUpdate() {
        hasPendingWindowSizeUpdate = true
        guard !isWindowSizeUpdateScheduled else { return }
        isWindowSizeUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isWindowSizeUpdateScheduled = false
                self.applyPendingWindowSizeUpdate()
            }
        }
    }

    private func applyPendingWindowSizeUpdate() {
        applyPendingWindowSizeUpdate(renderedBubbleState: bubbleViewState.renderedBubbleState)
    }

    private func applyPendingWindowSizeUpdate(renderedBubbleState: DetachedIslandBubbleState) {
        guard let window else { return }
        guard hasPendingWindowSizeUpdate else { return }

        if isApplyingWindowSizeUpdate {
            scheduleWindowSizeUpdate()
            return
        }

        hasPendingWindowSizeUpdate = false
        let currentFrame = window.frame
        let petAnchorScreen = Self.petAnchorScreenPoint(
            for: currentFrame,
            layout: lastAppliedLayout
        )
        let newLayout = Self.windowLayout(
            for: viewModel,
            bubbleState: renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: bubbleViewState.measuredCompletionBubbleHeight,
            guideBubbleSize: currentGuideBubbleSize,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame(for: petAnchorScreen)
        )
        interactionModel.setBubblePlacement(newLayout.bubblePlacement)
        let newOrigin = Self.windowOrigin(
            preservingPetAnchorAt: petAnchorScreen,
            layout: newLayout
        )
        let targetFrame = NSRect(origin: newOrigin, size: newLayout.containerSize)

        guard !Self.framesMatch(currentFrame, targetFrame) else {
            lastAppliedLayout = newLayout
            return
        }

        isApplyingWindowSizeUpdate = true
        window.setFrame(targetFrame, display: false, animate: false)
        isApplyingWindowSizeUpdate = false
        lastAppliedLayout = newLayout

        if hasPendingWindowSizeUpdate {
            scheduleWindowSizeUpdate()
        }
    }

    static func windowLayout(
        for viewModel: NotchViewModel,
        bubbleState: DetachedIslandBubbleState = .hidden,
        bubblePlacement: DetachedIslandBubblePlacement = .topLeft,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        measuredCompletionBubbleHeight: CGFloat? = nil,
        guideBubbleSize: CGSize? = nil,
        petAnchorScreen: CGPoint? = nil,
        availableFrame: CGRect? = nil
    ) -> DetachedIslandWindowLayout {
        let additionalFooterHeight: CGFloat = 0

        return DetachedIslandContentModel.layout(
            for: [],
            viewModel: viewModel,
            bubbleState: bubbleState,
            bubblePlacement: bubblePlacement,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: measuredCompletionBubbleHeight,
            additionalFooterHeight: additionalFooterHeight,
            guideBubbleSize: guideBubbleSize,
            petScreenAnchor: petAnchorScreen,
            availableFrame: availableFrame
        )
    }

    static func windowSize(
        for viewModel: NotchViewModel,
        bubbleState: DetachedIslandBubbleState = .hidden,
        bubblePlacement: DetachedIslandBubblePlacement = .topLeft,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        measuredCompletionBubbleHeight: CGFloat? = nil,
        guideBubbleSize: CGSize? = nil,
        petAnchorScreen: CGPoint? = nil,
        availableFrame: CGRect? = nil
    ) -> CGSize {
        windowLayout(
            for: viewModel,
            bubbleState: bubbleState,
            bubblePlacement: bubblePlacement,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: measuredCompletionBubbleHeight,
            guideBubbleSize: guideBubbleSize,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame
        ).containerSize
    }

    static func windowOrigin(
        for cursorLocation: CGPoint,
        cursorWindowOffset: CGPoint,
        windowSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: cursorLocation.x - cursorWindowOffset.x,
            y: cursorLocation.y - min(cursorWindowOffset.y, windowSize.height)
        )
    }

    static func defaultPetAnchor(
        in visibleFrame: CGRect,
        alignedTo activeWindowFrame: CGRect? = nil
    ) -> CGPoint {
        let halfPet = DetachedIslandPanelMetrics.petMetrics(for: visibleFrame).petHitFrame / 2
        let referenceFrame = activeWindowFrame?
            .intersection(visibleFrame)
            .nilIfEmpty ?? visibleFrame

        return CGPoint(
            x: referenceFrame.maxX - defaultTrailingInset - halfPet,
            y: referenceFrame.minY + defaultBottomInset + halfPet
        )
    }

    static func clampedPetAnchor(
        _ petAnchor: CGPoint,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let halfPet = DetachedIslandPanelMetrics.petMetrics(for: visibleFrame).petHitFrame / 2
        let minX = visibleFrame.minX + halfPet
        let maxX = visibleFrame.maxX - halfPet
        let minY = visibleFrame.minY + halfPet
        let maxY = visibleFrame.maxY - halfPet

        let resolvedX = minX <= maxX
            ? min(max(petAnchor.x, minX), maxX)
            : visibleFrame.midX
        let resolvedY = minY <= maxY
            ? min(max(petAnchor.y, minY), maxY)
            : visibleFrame.midY

        return CGPoint(x: resolvedX, y: resolvedY)
    }

    static func floatingPetAnchor(
        from petAnchor: CGPoint,
        in visibleFrame: CGRect
    ) -> FloatingPetAnchor {
        let clampedAnchor = clampedPetAnchor(petAnchor, in: visibleFrame)
        let xRatio = visibleFrame.width > 0
            ? (clampedAnchor.x - visibleFrame.minX) / visibleFrame.width
            : 0.5
        let yRatio = visibleFrame.height > 0
            ? (clampedAnchor.y - visibleFrame.minY) / visibleFrame.height
            : 0.5

        return FloatingPetAnchor(
            xRatio: Double(xRatio),
            yRatio: Double(yRatio)
        )
    }

    static func petAnchor(
        from storedAnchor: FloatingPetAnchor?,
        in visibleFrame: CGRect,
        defaultWindowFrame: CGRect? = nil
    ) -> CGPoint {
        guard let storedAnchor else {
            return clampedPetAnchor(
                defaultPetAnchor(
                    in: visibleFrame,
                    alignedTo: defaultWindowFrame
                ),
                in: visibleFrame
            )
        }

        let rawAnchor = CGPoint(
            x: visibleFrame.minX + (CGFloat(storedAnchor.xRatio) * visibleFrame.width),
            y: visibleFrame.minY + (CGFloat(storedAnchor.yRatio) * visibleFrame.height)
        )
        return clampedPetAnchor(rawAnchor, in: visibleFrame)
    }

    static func petAnchorScreenPoint(
        for frame: NSRect,
        layout: DetachedIslandWindowLayout
    ) -> CGPoint {
        CGPoint(
            x: frame.minX + layout.petAnchorInWindow.x,
            y: frame.maxY - layout.petAnchorInWindow.y
        )
    }

    static func windowOrigin(
        preservingPetAnchorAt petAnchorScreen: CGPoint,
        layout: DetachedIslandWindowLayout
    ) -> CGPoint {
        CGPoint(
            x: petAnchorScreen.x - layout.petAnchorInWindow.x,
            y: petAnchorScreen.y - (layout.containerSize.height - layout.petAnchorInWindow.y)
        )
    }

    static func petInteractionFrame(
        for layout: DetachedIslandWindowLayout
    ) -> CGRect {
        CGRect(
            x: layout.petFrame.minX,
            y: layout.containerSize.height - layout.petFrame.maxY,
            width: layout.petFrame.width,
            height: layout.petFrame.height
        )
    }

    static func floatingDragTranslation(
        from start: CGPoint,
        to current: CGPoint
    ) -> CGSize {
        CGSize(
            width: current.x - start.x,
            height: current.y - start.y
        )
    }

    private static func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
        abs(lhs.size.width - rhs.size.width) < 0.5 &&
        abs(lhs.size.height - rhs.size.height) < 0.5
    }

    private func suppressInteraction() {
        cancelInteractionActivation()
        window?.ignoresMouseEvents = true
    }

    private func cancelInteractionActivation() {
        interactionActivationWorkItem?.cancel()
        interactionActivationWorkItem = nil
    }

    private func handlePetMouseDown(_ event: NSEvent) -> Bool {
        let point = event.locationInWindow
        guard isPointInsidePet(point) else { return false }
        petMouseDownPoint = point
        petMouseDownScreenPoint = screenPoint(for: event)
        isPetDragActive = false
        return true
    }

    private func handlePetMouseDragged(_ event: NSEvent) -> Bool {
        guard petMouseDownPoint != nil,
              let petMouseDownScreenPoint else { return false }

        let currentScreenPoint = screenPoint(for: event)
        let translation = Self.floatingDragTranslation(
            from: petMouseDownScreenPoint,
            to: currentScreenPoint
        )

        if !isPetDragActive,
           hypot(translation.width, translation.height) >= 3 {
            isPetDragActive = true
            dismissFloatingSettingsHint()
            beginFloatingDrag()
        }

        guard isPetDragActive else { return true }
        updateFloatingDrag(translation: translation)
        return true
    }

    private func handlePetMouseUp(_ event: NSEvent) -> Bool {
        defer {
            petMouseDownPoint = nil
            petMouseDownScreenPoint = nil
            isPetDragActive = false
        }

        guard petMouseDownPoint != nil else { return false }

        if isPetDragActive {
            endFloatingDrag()
            return true
        }

        guard isPointInsidePet(event.locationInWindow) else { return true }
        dismissFloatingSettingsHint()
        detachedViewController.onPetTap()
        return true
    }

    private func handlePetRightMouseDown(_ event: NSEvent) -> Bool {
        guard isPointInsidePet(event.locationInWindow) else {
            isPetSecondaryClickArmed = false
            return false
        }

        isPetSecondaryClickArmed = true
        return true
    }

    private func handlePetRightMouseUp(_ event: NSEvent) -> Bool {
        defer { isPetSecondaryClickArmed = false }
        guard isPetSecondaryClickArmed else { return false }
        guard isPointInsidePet(event.locationInWindow) else { return true }

        handlePetSecondaryClick()
        return true
    }

    private func isPointInsidePet(_ point: CGPoint) -> Bool {
        Self.petInteractionFrame(for: lastAppliedLayout).contains(point)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        // Window movement and hit-testing use AppKit screen coordinates (origin at bottom-left).
        MouseEventReplay.appKitScreenLocation(
            for: event,
            fallbackScreenLocation: NSEvent.mouseLocation
        )
    }

    private func syncBubblePresentation(to targetState: DetachedIslandBubbleState) {
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil

        switch targetState {
        case .hidden:
            cancelBubbleHoverGraceTimer()
            hideBubblePresentation()
        case .hoverPreview, .pinned:
            showBubblePresentation(targetState)
        }
    }

    private func showBubblePresentation(_ targetState: DetachedIslandBubbleState) {
        bubbleViewState.prepareLayout(for: targetState)
        applyWindowSizeUpdateImmediately()
        withAnimation(.easeInOut(duration: bubbleViewState.bubbleFadeDuration)) {
            bubbleViewState.setBubbleVisible(true)
        }
    }

    private func hideBubbleRenderingImmediately() {
        bubbleVisibilityWorkItem?.cancel()
        bubbleVisibilityWorkItem = nil
        cancelBubbleHoverGraceTimer()
        bubbleViewState.setBubbleVisible(false)
        applyWindowSizeUpdateImmediately(renderedBubbleState: .hidden)
        bubbleViewState.prepareLayout(for: .hidden)
    }

    private func hideBubblePresentation() {
        guard bubbleViewState.renderedBubbleState != .hidden else {
            hideBubbleRenderingImmediately()
            return
        }

        withAnimation(.easeInOut(duration: bubbleViewState.bubbleFadeDuration)) {
            bubbleViewState.setBubbleVisible(false)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bubbleVisibilityWorkItem = nil
            guard self.interactionModel.bubbleState == .hidden else { return }
            self.applyWindowSizeUpdateImmediately(renderedBubbleState: .hidden)
            self.bubbleViewState.prepareLayout(for: .hidden)
        }

        bubbleVisibilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + bubbleViewState.bubbleFadeDuration,
            execute: workItem
        )
    }

    private func applyWindowSizeUpdateImmediately(
        renderedBubbleState: DetachedIslandBubbleState? = nil
    ) {
        hasPendingWindowSizeUpdate = true
        applyPendingWindowSizeUpdate(
            renderedBubbleState: renderedBubbleState ?? bubbleViewState.renderedBubbleState
        )
    }

    private func applyBubbleStateChange(_ change: () -> Void) {
        let previousState = interactionModel.bubbleState
        change()
        syncBubblePresentation(to: interactionModel.bubbleState)
        syncOutsideClickMonitor()
        recordBubbleTelemetryTransition(from: previousState, to: interactionModel.bubbleState)
    }

    private func recordBubbleTelemetryTransition(
        from previousState: DetachedIslandBubbleState,
        to currentState: DetachedIslandBubbleState
    ) {
        guard previousState != currentState else { return }

        if previousState == .hidden, currentState != .hidden {
            let openSource = currentState == .hoverPreview ? "hover" : "click"
            let contentRoute = telemetryContentRoute(for: currentState)
            Task {
                await TelemetryService.shared.recordIslandOpened(
                    openSource: openSource,
                    contentRoute: contentRoute,
                    presentation: "detached"
                )
            }
            return
        }

        if previousState != .hidden, currentState == .hidden {
            let openSource = previousState == .hoverPreview ? "hover" : "click"
            let contentRoute = telemetryContentRoute(for: previousState)
            Task {
                await TelemetryService.shared.recordIslandClosed(
                    openSource: openSource,
                    contentRoute: contentRoute,
                    presentation: "detached"
                )
            }
        }
    }

    private func telemetryContentRoute(for bubbleState: DetachedIslandBubbleState) -> String {
        switch bubbleState {
        case .hidden:
            return "none"
        case .hoverPreview:
            return "plugin_preview"
        case .pinned:
            return "plugin_list"
        }
    }

    private func handlePetTap() {
        let canPresentPreview = DetachedIslandContentModel.canPresentBubble(
            from: [],
            mode: .hoverPreview,
        )
        let canPresentPinnedBubble = DetachedIslandContentModel.canPresentBubble(
            from: [],
            mode: .pinnedList
        )
        let previousBubbleState = interactionModel.bubbleState

        applyBubbleStateChange {
            interactionModel.togglePrimaryBubble(
                canPresentPreview: canPresentPreview,
                canPresentPinnedBubble: canPresentPinnedBubble
            )
        }

        handlePrimaryBubbleTapTransition(
            from: previousBubbleState,
            to: interactionModel.bubbleState
        )
    }

    private func reconcileBubbleStateWithAvailableContent() {
        switch interactionModel.bubbleState {
        case .hidden:
            return
        case .hoverPreview, .pinned:
            applyBubbleStateChange {
                interactionModel.hidePinnedBubble()
            }
        }
    }

    private func syncOutsideClickMonitor() {
        let shouldMonitorOutsideClicks = interactionModel.bubbleState == .pinned
            || interactionModel.bubbleState == .hoverPreview

        if shouldMonitorOutsideClicks {
            guard outsideClickMonitor == nil else { return }
            let monitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handlePotentialOutsideClick(event)
            }
            monitor.start()
            outsideClickMonitor = monitor
        } else {
            outsideClickMonitor?.stop()
            outsideClickMonitor = nil
        }
    }

    private func handlePotentialOutsideClick(_ event: NSEvent) {
        let eventLocation = MouseEventReplay.appKitScreenLocation(
            for: event,
            fallbackScreenLocation: NSEvent.mouseLocation
        )
        handlePotentialOutsideClick(screenLocation: eventLocation)
    }

    private func handlePotentialOutsideClick(screenLocation eventLocation: CGPoint) {
        guard interactionModel.bubbleState != .hidden,
              let window else { return }

        if screenBubbleFrame(for: window).contains(eventLocation) {
            return
        }

        if screenPetInteractionFrame(for: window).contains(eventLocation) {
            return
        }

        applyBubbleStateChange {
            interactionModel.hidePinnedBubble()
        }
    }

    private func handlePrimaryBubbleTapTransition(
        from previousState: DetachedIslandBubbleState,
        to currentState: DetachedIslandBubbleState
    ) {
        if currentState != .hidden {
            dismissFloatingSettingsHint()
        }

        guard previousState == .hidden else {
            cancelBubbleHoverGraceTimer()
            return
        }

        guard currentState != .hidden else {
            cancelBubbleHoverGraceTimer()
            return
        }

        scheduleBubbleHoverGraceTimer()
    }

    private func handleBubbleHoverChanged(_ isHovering: Bool) {
        guard isHovering else { return }
        cancelBubbleHoverGraceTimer()
    }

    private func scheduleBubbleHoverGraceTimer() {
        cancelBubbleHoverGraceTimer()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bubbleHoverGraceWorkItem = nil
            guard self.interactionModel.bubbleState != .hidden else { return }
            self.applyBubbleStateChange {
                self.interactionModel.hidePinnedBubble()
            }
        }

        bubbleHoverGraceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + bubbleHoverGraceDelay,
            execute: workItem
        )
    }

    private func cancelBubbleHoverGraceTimer() {
        bubbleHoverGraceWorkItem?.cancel()
        bubbleHoverGraceWorkItem = nil
    }

    private func presentFloatingSettingsHintIfNeeded() {
        guard AppSettings.floatingPetSettingsHintPending else { return }

        AppSettings.floatingPetSettingsHintPending = false
        floatingSettingsHintDismissWorkItem?.cancel()
        interactionModel.setSettingsHintVisible(true)
        scheduleWindowSizeUpdate()

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissFloatingSettingsHint()
        }
        floatingSettingsHintDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func dismissFloatingSettingsHint() {
        floatingSettingsHintDismissWorkItem?.cancel()
        floatingSettingsHintDismissWorkItem = nil
        guard interactionModel.isSettingsHintVisible else { return }
        interactionModel.setSettingsHintVisible(false)
        scheduleWindowSizeUpdate()
    }

    private func screenBubbleFrame(for window: NSWindow) -> CGRect {
        guard let bubbleFrame = lastAppliedLayout.bubbleFrame else { return .null }
        let bubbleWindowFrame = CGRect(
            x: bubbleFrame.minX,
            y: lastAppliedLayout.containerSize.height - bubbleFrame.maxY,
            width: bubbleFrame.width,
            height: bubbleFrame.height
        )
        return bubbleWindowFrame.offsetBy(
            dx: window.frame.origin.x,
            dy: window.frame.origin.y
        )
    }

    private func screenPetInteractionFrame(for window: NSWindow) -> CGRect {
        Self.petInteractionFrame(for: lastAppliedLayout).offsetBy(
            dx: window.frame.origin.x,
            dy: window.frame.origin.y
        )
    }

    private func updateBubblePlacementForCurrentWindow() {
        guard let window else { return }
        let petAnchorScreen = Self.petAnchorScreenPoint(
            for: window.frame,
            layout: lastAppliedLayout
        )
        let resolvedLayout = Self.windowLayout(
            for: viewModel,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: bubbleViewState.measuredCompletionBubbleHeight,
            guideBubbleSize: currentGuideBubbleSize,
            petAnchorScreen: petAnchorScreen,
            availableFrame: availableFrame(for: petAnchorScreen)
        )
        interactionModel.setBubblePlacement(resolvedLayout.bubblePlacement)
    }

    private func availableFrame(for petAnchor: CGPoint? = nil) -> CGRect {
        if let screen = window?.screen {
            return screen.visibleFrame
        }

        if let petAnchor,
           let matchingScreen = NSScreen.screens.first(where: {
               $0.frame.insetBy(dx: -1, dy: -1).contains(petAnchor)
           }) {
            return matchingScreen.visibleFrame
        }

        return viewModel.screenRect
    }
}

private extension CGRect {
    var nilIfEmpty: CGRect? {
        guard !isNull, !isEmpty, width > 0, height > 0 else {
            return nil
        }

        return self
    }
}
