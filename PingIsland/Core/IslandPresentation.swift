import CoreGraphics
import Foundation

enum IslandPresentationMode: Equatable {
    case docked
    case detached
}

enum IslandOpenedPresentationStyle: Equatable {
    case docked
    case detached
}

enum IslandPresentationActivationPolicy: Equatable {
    case interactive
    case silent

    var activatesApplication: Bool {
        self == .interactive
    }

    var presentsAutomaticContent: Bool {
        self == .interactive
    }
}

enum DetachedIslandDisplayMode: Equatable {
    case compact
    case hoverExpanded
}

enum DetachedIslandBubbleState: Equatable {
    case hidden
    case hoverPreview
    case pinned
}

enum IslandDetachmentSource: Equatable {
    case closed
    case opened
}

struct IslandDetachmentRequest: Equatable {
    let source: IslandDetachmentSource
    let dragStartScreenLocation: CGPoint
    let currentScreenLocation: CGPoint
}

struct IslandDetachmentPayload: Equatable {
    let contentType: NotchContentType?
    let dragStartScreenLocation: CGPoint
    let initialCursorScreenLocation: CGPoint
    let cursorWindowOffset: CGPoint
}

struct IslandDetachmentGestureGate {
    static let defaultThreshold: CGFloat = 20
    static let defaultLongPressDuration: TimeInterval = 0.35

    static func qualifies(
        start startLocation: CGPoint,
        current currentLocation: CGPoint,
        hasSatisfiedLongPress: Bool,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        guard hasSatisfiedLongPress else { return false }
        let horizontalDistance = abs(currentLocation.x - startLocation.x)
        let downwardDistance = startLocation.y - currentLocation.y
        return downwardDistance >= threshold && downwardDistance > horizontalDistance
    }
}

struct IslandDetachedContentResolver {
    static func resolve(
        status: NotchStatus,
        openReason: NotchOpenReason,
        contentType: NotchContentType?,
        sessions: [Any]
    ) -> NotchContentType? {
        contentType
    }
}

enum IslandMascotResolver {
}
