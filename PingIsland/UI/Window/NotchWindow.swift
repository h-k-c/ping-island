//
//  NotchWindow.swift
//  PingIsland
//
//  Transparent window that overlays the notch area
//  Following NotchDrop's approach: window ignores mouse events,
//  we use global event monitors to detect clicks/hovers
//

import AppKit

// Use NSPanel subclass for non-activating behavior
class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Floating panel behavior
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Transparent configuration
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false

        // CRITICAL: Prevent window from moving during space switches
        isMovable = false

        // Window behavior - stays on all spaces, above menu bar
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Above the menu bar
        level = .mainMenu + 3

        // Enable tooltips even when app is inactive (needed for panel windows)
        allowsToolTipsWhenApplicationIsInactive = true

        // CRITICAL: Window ignores ALL mouse events
        // This allows clicks to pass through to the menu bar
        // We use global event monitors to detect hover/clicks on the notch area
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when a left mouse-down lands on an empty area of the panel (no
    /// SwiftUI view wants it). Used by the recorder's sticky peek to collapse the
    /// expanded panel back to the peek bar — driven by the authoritative hitTest
    /// so a real control click is never mistaken for an outside click.
    var onEmptyAreaMouseDown: (() -> Void)?

    // MARK: - Click-through for areas outside the panel content

    override func sendEvent(_ event: NSEvent) {
        // If the click lands in an empty area (no SwiftUI view claimed it), fire the
        // collapse callback and absorb the event. With the tight peek frame this
        // happens only in the rounded-corner dead-zone; clicks outside the window
        // frame reach the desktop/menu-bar directly without going through here.
        if event.type == .leftMouseDown,
           self.contentView?.hitTest(event.locationInWindow) == nil {
            onEmptyAreaMouseDown?()
            return
        }
        super.sendEvent(event)
    }


}
