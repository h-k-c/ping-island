import Combine
import Foundation

@MainActor
final class PluginSlotArbiter: ObservableObject {
    static let shared = PluginSlotArbiter()

    // MARK: - Active display state (consumed by NotchView)

    @Published private(set) var activeLeft: PluginCompactContent?
    @Published private(set) var activeLeftPluginId: String?
    @Published private(set) var activeRight: PluginCompactContent?
    @Published private(set) var activeRightPluginId: String?
    @Published private(set) var pendingNotifications: [PluginNotifyUpdate] = []
    @Published private(set) var expandedContent: [String: [ExpandedSection]] = [:]
    @Published var currentlyDisplayedExpandedPluginId: String?

    // MARK: - Slot assignment (explicit — no more carousel)

    /// plugin ID assigned to right ear, or nil = none
    @Published var rightEarAssignment: String? {
        didSet {
            defaults.set(rightEarAssignment, forKey: Keys.rightEar)
            recompute()
        }
    }

    /// plugin ID assigned to left ear, or nil = none
    @Published var leftEarAssignment: String? {
        didSet {
            defaults.set(leftEarAssignment, forKey: Keys.leftEar)
            recompute()
        }
    }

    // MARK: - Per-plugin latest content cache

    private var rightContents: [String: PluginCompactContent] = [:]
    private var leftContents:  [String: PluginCompactContent] = [:]
    private var coreLeftActive  = false
    private var coreRightActive = false

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let rightEar = "PluginSlotArbiter.rightEar.v1"
        static let leftEar  = "PluginSlotArbiter.leftEar.v1"
    }

    init() {
        rightEarAssignment = defaults.string(forKey: Keys.rightEar)
        leftEarAssignment  = defaults.string(forKey: Keys.leftEar)
    }

    // MARK: - Public API

    func handleCompact(_ update: PluginCompactUpdate) {
        switch update.position {
        case .right:
            if let content = update.content {
                rightContents[update.pluginId] = sanitize(content)
            } else {
                rightContents.removeValue(forKey: update.pluginId)
            }
        case .left:
            if let content = update.content {
                leftContents[update.pluginId] = sanitize(content)
            } else {
                leftContents.removeValue(forKey: update.pluginId)
            }
        }
        recompute()
    }

    func handleNotify(_ update: PluginNotifyUpdate) {
        let clamped = update.content.duration.map { min(max($0, 0.5), 10.0) }
        let sanitized = PluginNotifyUpdate(
            pluginId: update.pluginId,
            content: PluginNotifyContent(
                icon: update.content.icon,
                title: update.content.title,
                subtitle: update.content.subtitle,
                duration: clamped,
                actionLabel: update.content.actionLabel,
                actionId: update.content.actionId
            )
        )
        pendingNotifications.append(sanitized)
    }

    func dequeueNotification() -> PluginNotifyUpdate? {
        guard !pendingNotifications.isEmpty else { return nil }
        return pendingNotifications.removeFirst()
    }

    func handleExpanded(_ update: PluginExpandedUpdate) {
        if update.sections.isEmpty {
            expandedContent.removeValue(forKey: update.pluginId)
        } else {
            expandedContent[update.pluginId] = update.sections
        }
    }

    func setCoreActive(_ active: Bool, side: CompactPosition) {
        switch side {
        case .left:  coreLeftActive = active
        case .right: coreRightActive = active
        }
        recompute()
    }

    func removePlugin(_ pluginId: String) {
        rightContents.removeValue(forKey: pluginId)
        leftContents.removeValue(forKey: pluginId)
        expandedContent.removeValue(forKey: pluginId)
        pendingNotifications.removeAll { $0.pluginId == pluginId }
        // If the removed plugin was assigned, clear the assignment
        if rightEarAssignment == pluginId { rightEarAssignment = nil }
        if leftEarAssignment  == pluginId { leftEarAssignment  = nil }
        recompute()
    }

    /// All plugin IDs that have pushed compact-right content (for slot picker)
    var availableRightPlugins: [String] {
        Array(rightContents.keys).sorted()
    }

    /// All plugin IDs that have pushed compact-left content (for slot picker)
    var availableLeftPlugins: [String] {
        Array(leftContents.keys).sorted()
    }

    // MARK: - Private

    private func recompute() {
        // Right ear
        if coreRightActive {
            activeRight = nil
            activeRightPluginId = nil
        } else if let id = rightEarAssignment, let content = rightContents[id] {
            activeRight = content
            activeRightPluginId = id
        } else {
            activeRight = nil
            activeRightPluginId = nil
        }

        // Left ear
        if coreLeftActive {
            activeLeft = nil
            activeLeftPluginId = nil
        } else if let id = leftEarAssignment, let content = leftContents[id] {
            activeLeft = content
            activeLeftPluginId = id
        } else {
            activeLeft = nil
            activeLeftPluginId = nil
        }
    }

    private func sanitize(_ content: PluginCompactContent) -> PluginCompactContent {
        let label = content.label.map { String($0.prefix(4)) }
        let badge = content.badge.map { max(0, $0) }
        return PluginCompactContent(icon: content.icon, label: label, badge: badge, tint: content.tint)
    }
}
