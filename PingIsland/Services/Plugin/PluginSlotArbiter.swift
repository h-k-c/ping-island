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
            let normalized = Self.normalizedPluginId(rightEarAssignment)
            if normalized != rightEarAssignment {
                rightEarAssignment = normalized
                return
            }
            defaults.set(rightEarAssignment, forKey: Keys.rightEar)
            recompute()
        }
    }

    /// plugin ID assigned to left ear, or nil = none
    @Published var leftEarAssignment: String? {
        didSet {
            let normalized = Self.normalizedPluginId(leftEarAssignment)
            if normalized != leftEarAssignment {
                leftEarAssignment = normalized
                return
            }
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
    private static let legacyPluginIdMap: [String: String] = [
        "com.wudanwu.pingisland.claude": "com.auralink.claude",
        "com.wudanwu.pingisland.codex": "com.auralink.codex",
        "com.wudanwu.pingisland.usage": "com.auralink.usage",
        "com.wudanwu.pingisland.procmonitor": "com.auralink.procmonitor",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawRight = defaults.string(forKey: Keys.rightEar)
        let rawLeft = defaults.string(forKey: Keys.leftEar)
        let normalizedRight = Self.normalizedPluginId(rawRight)
        let normalizedLeft = Self.normalizedPluginId(rawLeft)
        rightEarAssignment = normalizedRight
        leftEarAssignment  = normalizedLeft
        if rawRight != normalizedRight {
            defaults.set(normalizedRight, forKey: Keys.rightEar)
        }
        if rawLeft != normalizedLeft {
            defaults.set(normalizedLeft, forKey: Keys.leftEar)
        }
    }

    // MARK: - Public API

    func handleCompact(_ update: PluginCompactUpdate) {
        let pluginId = Self.normalizedPluginId(update.pluginId) ?? update.pluginId
        if let content = update.content {
            latestCompact[pluginId] = sanitize(content)
        } else {
            latestCompact.removeValue(forKey: pluginId)
        }
        recompute()
    }

    func handleNotify(_ update: PluginNotifyUpdate) {
        let pluginId = Self.normalizedPluginId(update.pluginId) ?? update.pluginId
        let clamped = update.content.duration.map { min(max($0, 0.5), 10.0) }
        let sanitized = PluginNotifyUpdate(
            pluginId: pluginId,
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
        let pluginId = Self.normalizedPluginId(update.pluginId) ?? update.pluginId
        if update.sections.isEmpty {
            expandedContent.removeValue(forKey: pluginId)
        } else {
            expandedContent[pluginId] = update.sections
        }
    }

    func removePlugin(_ pluginId: String) {
        let normalizedPluginId = Self.normalizedPluginId(pluginId) ?? pluginId
        latestCompact.removeValue(forKey: normalizedPluginId)
        expandedContent.removeValue(forKey: normalizedPluginId)
        pendingNotifications.removeAll { $0.pluginId == normalizedPluginId }
        // If the removed plugin was assigned, clear the assignment
        if rightEarAssignment == normalizedPluginId { rightEarAssignment = nil }
        if leftEarAssignment  == normalizedPluginId { leftEarAssignment  = nil }
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

    private static func normalizedPluginId(_ pluginId: String?) -> String? {
        guard let pluginId else { return nil }
        return legacyPluginIdMap[pluginId] ?? pluginId
    }
}
