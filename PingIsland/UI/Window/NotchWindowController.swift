//
//  NotchWindowController.swift
//  PingIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import Combine
import SwiftUI

class NotchWindowController: NSWindowController {
    let viewModel: NotchViewModel
    private let fullWindowFrame: NSRect
    private var cancellables = Set<AnyCancellable>()
    /// While the settings window is open, the full-width notch window must not
    /// intercept clicks (it would block the settings UI underneath it).
    private var settingsWindowVisible = false

    /// Invisible click-absorber that sits exactly over the recorder peek card. The
    /// main notch window stays full-size + click-through so the island can animate
    /// freely (no resize judder, no clipping); this tiny transparent panel is the
    /// ONLY thing that intercepts clicks on the island, so taps on the controls are
    /// absorbed (and dispatched by the mouse monitor) instead of leaking through to
    /// the desktop/app behind. It renders nothing, so resizing it per state is
    /// instantaneous and never visible.
    private let clickAbsorber: NotchPanel

    init(
        screen: NSScreen,
        viewModel: NotchViewModel,
        performBootAnimation: Bool
    ) {
        self.viewModel = viewModel

        let screenFrame = screen.frame

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight
        )
        self.fullWindowFrame = windowFrame

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Create the invisible click-absorber (sits just above the main window so it
        // catches taps on the recorder card). Starts hidden + zero-sized.
        let absorber = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        absorber.ignoresMouseEvents = false
        absorber.level = .mainMenu + 4
        absorber.hasShadow = false
        absorber.backgroundColor = .clear
        self.clickAbsorber = absorber

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(
            viewModel: viewModel
        )
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Dynamically toggle mouse event handling based on notch state:
        // - Closed: ignoresMouseEvents = true (clicks pass through to menu bar/apps)
        // - Opened: ignoresMouseEvents = false (buttons inside panel work)
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$openReason
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        // Resize the window when the recorder peek content is remeasured (height
        // changes on expand/collapse) or when expand state changes (width changes).
        viewModel.$openedMeasuredHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = viewModel.contentType {
                    self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
                }
            }
            .store(in: &cancellables)

        // Keep the click-absorber glued to the actual reported card bounds as the
        // recorder's controls/layout change (e.g. recording → finished result).
        viewModel.$recorderButtonFrames
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = viewModel.contentType {
                    self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
                }
            }
            .store(in: &cancellables)

        PluginSlotArbiter.shared.$stickyPeekExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = viewModel.contentType {
                    self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
                }
            }
            .store(in: &cancellables)

        viewModel.$isFullscreenEdgeRevealActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$isFullscreenBrowserHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$isIdleAutoHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$presentationMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$isFullscreenBrowserHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        viewModel.$isIdleAutoHiddenActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak notchWindow, weak viewModel] _ in
                guard let self, let notchWindow, let viewModel else { return }
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
            .store(in: &cancellables)

        // Collapse the recorder's expanded panel back to the peek bar when the
        // user clicks an empty area of the panel. Driven by the window's hitTest
        // so real control clicks are never eaten.
        notchWindow.onEmptyAreaMouseDown = { [weak viewModel] in
            viewModel?.collapseStickyPeekIfNeeded()
        }

        // Yield click interception while the settings window is open.
        NotificationCenter.default.addObserver(
            forName: .settingsWindowVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak notchWindow, weak viewModel] note in
            MainActor.assumeIsolated {
                guard let self, let notchWindow, let viewModel else { return }
                self.settingsWindowVisible =
                    note.userInfo?[SettingsWindowVisibilityNotification.isVisibleKey] as? Bool ?? false
                self.updateWindowPresentation(window: notchWindow, viewModel: viewModel)
            }
        }

        // Start with ignoring mouse events (closed state)
        notchWindow.ignoresMouseEvents = true
        updateWindowPresentation(window: notchWindow, viewModel: viewModel)

        // Perform boot animation after a brief delay
        if performBootAnimation {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.viewModel.performBootAnimation()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Window frame that tightly wraps the recorder peek (notch header + card).
    /// Sized to openedSize and centered at the top, so clicks on the island are
    /// caught by this window while clicks anywhere else fall straight through to the
    /// desktop (there is no window there to absorb them).
    private func recorderPeekWindowFrame(viewModel: NotchViewModel) -> NSRect {
        let size = viewModel.openedSize
        let screenRect = viewModel.screenRect
        return NSRect(
            x: screenRect.midX - size.width / 2,
            y: screenRect.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Show the invisible click-absorber over the recorder card, or hide it.
    private func updateClickAbsorber(viewModel: NotchViewModel, visible: Bool) {
        guard visible else {
            if clickAbsorber.isVisible { clickAbsorber.orderOut(nil) }
            return
        }
        // Prefer the actual reported card bounds (covers the taller finished card);
        // fall back to the openedSize-based frame until SwiftUI has reported.
        let frame = viewModel.recorderCardScreenFrame ?? recorderPeekWindowFrame(viewModel: viewModel)
        if clickAbsorber.frame != frame {
            clickAbsorber.setFrame(frame, display: false)
        }
        if !clickAbsorber.isVisible {
            clickAbsorber.orderFront(nil)
        }
    }

    private func updateWindowPresentation(window: NotchPanel, viewModel: NotchViewModel) {
        let shouldHideWindow = viewModel.shouldHideWindowPresentation

        if shouldHideWindow {
            window.ignoresMouseEvents = true
            updateClickAbsorber(viewModel: viewModel, visible: false)
            if window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        if !window.isVisible {
            window.orderFront(nil)
        }

        // The settings window sits underneath the full-width notch window; never
        // intercept clicks while it's open, or its UI becomes unclickable.
        if settingsWindowVisible {
            if window.frame != fullWindowFrame {
                window.setFrame(fullWindowFrame, display: false)
            }
            window.ignoresMouseEvents = true
            updateClickAbsorber(viewModel: viewModel, visible: false)
            return
        }

        switch viewModel.status {
        case .opened:
            if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = viewModel.contentType {
                // Recorder peek: keep the full-size window click-through so the island
                // can animate freely (no resize judder / clipping). Pass-through is
                // prevented ONLY over the card by the invisible click-absorber, whose
                // taps the global mouse monitor dispatches (handleRecorderClick). No
                // makeKey/activate — the recorder must never steal foreground focus.
                if window.frame != fullWindowFrame {
                    window.setFrame(fullWindowFrame, display: false)
                }
                window.ignoresMouseEvents = true
                updateClickAbsorber(viewModel: viewModel, visible: true)
            } else {
                if window.frame != fullWindowFrame {
                    window.setFrame(fullWindowFrame, display: true)
                }
                window.ignoresMouseEvents = false
                updateClickAbsorber(viewModel: viewModel, visible: false)
                if viewModel.openReason != .notification {
                    NSApp.activate(ignoringOtherApps: false)
                    window.makeKey()
                }
            }
        case .closed, .popping:
            if window.frame != fullWindowFrame {
                window.setFrame(fullWindowFrame, display: false)
            }
            window.ignoresMouseEvents = true
            updateClickAbsorber(viewModel: viewModel, visible: false)
        }
    }
}
