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

    // MARK: - Slot assignment (explicit — no carousel)

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

    // MARK: - Per-plugin latest compact content (position-agnostic)

    /// Latest compact content each plugin has pushed, regardless of the position
    /// the plugin declared in `island/compact`. The user's ear assignment decides
    /// where it renders, so a plugin that only pushes `right` can still be placed
    /// on the left ear.
    private var latestCompact: [String: PluginCompactContent] = [:]

    private let defaults: UserDefaults
    private enum Keys {
        static let rightEar = "PluginSlotArbiter.rightEar.v1"
        static let leftEar  = "PluginSlotArbiter.leftEar.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rightEarAssignment = defaults.string(forKey: Keys.rightEar)
        leftEarAssignment  = defaults.string(forKey: Keys.leftEar)
    }

    // MARK: - Public API

    func handleCompact(_ update: PluginCompactUpdate) {
        if let content = update.content {
            latestCompact[update.pluginId] = sanitize(content)
        } else {
            latestCompact.removeValue(forKey: update.pluginId)
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

    func removePlugin(_ pluginId: String) {
        latestCompact.removeValue(forKey: pluginId)
        expandedContent.removeValue(forKey: pluginId)
        pendingNotifications.removeAll { $0.pluginId == pluginId }
        // If the removed plugin was assigned, clear the assignment
        if rightEarAssignment == pluginId { rightEarAssignment = nil }
        if leftEarAssignment  == pluginId { leftEarAssignment  = nil }
        recompute()
    }

    // MARK: - Private

    private func recompute() {
        // Right ear
        if let id = rightEarAssignment, let content = latestCompact[id] {
            activeRight = content
            activeRightPluginId = id
        } else {
            activeRight = nil
            activeRightPluginId = nil
        }

        // Left ear
        if let id = leftEarAssignment, let content = latestCompact[id] {
            activeLeft = content
            activeLeftPluginId = id
        } else {
            activeLeft = nil
            activeLeftPluginId = nil
        }
    }

    private func sanitize(_ content: PluginCompactContent) -> PluginCompactContent {
        let labelLimit = content.icon == nil ? 5 : 4
        let label = content.label.map { String($0.prefix(labelLimit)) }
        let badge = content.badge.map { max(0, $0) }
        return PluginCompactContent(icon: content.icon, label: label, badge: badge, tint: content.tint)
    }
}
