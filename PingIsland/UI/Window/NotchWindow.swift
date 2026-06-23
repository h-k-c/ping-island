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
        // For mouse events, check if we should pass through
        if event.type == .leftMouseDown || event.type == .leftMouseUp ||
           event.type == .rightMouseDown || event.type == .rightMouseUp {

            // Replayed events (ones we reposted while ignoresMouseEvents was
            // temporarily true) arrive here if ignoresMouseEvents was already
            // restored to false. Deliver them normally — they've already been
            // dispatched to windows behind us, so no further pass-through needed.
            if MouseEventReplay.isReplayed(event) {
                NSLog("[NotchPanel] REPLAYED type=\(event.type.rawValue) → super.sendEvent")
                super.sendEvent(event)
                return
            }

            // Get the location in window coordinates
            let locationInWindow = event.locationInWindow
            let hitResult = self.contentView?.hitTest(locationInWindow)
            NSLog("[NotchPanel] type=\(event.type.rawValue) loc=\(locationInWindow) hit=\(hitResult != nil ? "HIT(\(type(of: hitResult!)))" : "MISS") ignores=\(ignoresMouseEvents)")

            // Check if any view wants to handle this event
            if let contentView = self.contentView,
               contentView.hitTest(locationInWindow) == nil {
                if event.type == .leftMouseDown {
                    onEmptyAreaMouseDown?()
                }
                // No view wants this event - pass it through to windows behind
                // by temporarily ignoring mouse events and re-posting
                let screenLocation = convertPoint(toScreen: locationInWindow)
                ignoresMouseEvents = true
                NSLog("[NotchPanel] MISS → set ignoresMouseEvents=true, will repost")

                // Re-post the event, then restore interactivity so subsequent
                // button clicks aren't permanently blocked. cgEvent.post to
                // cghidEventTap is synchronous: routing to the window behind
                // completes inside repostMouseEvent before we return.
                DispatchQueue.main.async { [weak self] in
                    self?.repostMouseEvent(event, at: screenLocation)
                    self?.ignoresMouseEvents = false
                    NSLog("[NotchPanel] async: reposted + ignoresMouseEvents=false")
                }
                return
            }
        }

        super.sendEvent(event)
    }

    private func repostMouseEvent(_ event: NSEvent, at screenLocation: NSPoint) {
        let cgPoint = MouseEventReplay.repostLocation(
            for: event,
            fallbackScreenLocation: screenLocation
        )

        let mouseType: CGEventType
        switch event.type {
        case .leftMouseDown: mouseType = .leftMouseDown
        case .leftMouseUp: mouseType = .leftMouseUp
        case .rightMouseDown: mouseType = .rightMouseDown
        case .rightMouseUp: mouseType = .rightMouseUp
        default: return
        }

        let mouseButton: CGMouseButton = event.type == .rightMouseDown || event.type == .rightMouseUp ? .right : .left

        if let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: mouseType,
            mouseCursorPosition: cgPoint,
            mouseButton: mouseButton
        ) {
            MouseEventReplay.mark(cgEvent)
            cgEvent.post(tap: .cghidEventTap)
        }
    }
}
