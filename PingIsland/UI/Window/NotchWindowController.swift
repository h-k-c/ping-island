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

        // The recorder peek stays open for the whole recording. Its full-width
        // window would block the menu bar / desktop underneath, so for the recorder
        // we only intercept clicks while the cursor is actually over the panel.
        viewModel.$isHovering
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

    private func updateWindowPresentation(window: NotchPanel, viewModel: NotchViewModel) {
        let shouldHideWindow = viewModel.shouldHideWindowPresentation

        if shouldHideWindow {
            window.ignoresMouseEvents = true
            if window.isVisible {
                window.orderOut(nil)
            }
            return
        }

        if window.frame != fullWindowFrame {
            window.setFrame(fullWindowFrame, display: true)
        }

        if !window.isVisible {
            window.orderFront(nil)
        }

        // The settings window sits underneath the full-width notch window; never
        // intercept clicks while it's open, or its UI becomes unclickable.
        if settingsWindowVisible {
            window.ignoresMouseEvents = true
            return
        }

        switch viewModel.status {
        case .opened:
            if case .plugin(PluginSlotArbiter.stickyPeekPluginId) = viewModel.contentType {
                // Recorder peek: only grab clicks when the cursor is over the panel,
                // so the rest of the screen (menu bar, desktop) stays usable while
                // recording. Don't steal focus — the non-activating panel still
                // receives control clicks.
                window.ignoresMouseEvents = !viewModel.isHovering
            } else {
                window.ignoresMouseEvents = false
                if viewModel.openReason != .notification {
                    NSApp.activate(ignoringOtherApps: false)
                    window.makeKey()
                }
            }
        case .closed, .popping:
            window.ignoresMouseEvents = true
        }
    }
}
