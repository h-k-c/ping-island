//
//  NotchViewController.swift
//  PingIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureTransparency()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept hits within the panel rect
        guard hitTestRect().contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureTransparency()
    }

    /// The notch panel is a non-activating panel that never becomes key, so without
    /// this the FIRST click on the island is swallowed as a window-activation poke
    /// and never reaches the SwiftUI buttons/gestures — the recorder peek's controls
    /// appear dead until a second click. Accepting first mouse delivers the click
    /// straight to SwiftUI.
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

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: PassThroughHostingView<AppLocalizedRootView<NotchView>>!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        hostingView = PassThroughHostingView(
            rootView: AppLocalizedRootView {
                NotchView(
                    viewModel: viewModel
                )
            }
        )

        // Calculate the hit-test rect based on panel state
        hostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window coordinates: origin at bottom-left, Y increases upward.
            // The hit-test `point` arrives in the hosting view's LOCAL coordinate
            // space, so this rect must be local too. Use the view's ACTUAL bounds
            // (not geometry.windowHeight / screenRect.width): the recorder peek
            // shrinks the window to tightly wrap the island and offsets it from the
            // screen origin. Using full-screen dimensions placed the rect far
            // outside the short, offset window — so every click, even directly on a
            // button, registered as "outside the island" and passed through. The
            // panel is centered in the window and anchored to its top.
            let bounds = self.hostingView?.bounds ?? CGRect(
                x: 0, y: 0, width: geometry.screenRect.width, height: geometry.windowHeight
            )
            let windowHeight = bounds.height
            let viewWidth = bounds.width

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                // Panel is centered horizontally, anchored to top
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                // Add a downward safety margin so a brief height-measurement
                // undershoot (e.g. right after a content change) can't push the
                // panel's controls below the hit-test region and make them
                // untappable. super.hitTest still gates precisely on the real
                // SwiftUI views, so a slightly larger rect is safe.
                let panelHeight = panelSize.height + 60
                return CGRect(
                    x: (viewWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .closed, .popping:
                let closedSize = vm.closedSize
                // Add some padding for easier interaction
                return CGRect(
                    x: (viewWidth - closedSize.width) / 2 - 10,
                    y: windowHeight - closedSize.height - 5,
                    width: closedSize.width + 20,
                    height: closedSize.height + 10
                )
            }
        }

        self.view = hostingView
    }
}
