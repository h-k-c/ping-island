import Combine
import Foundation

@MainActor
final class PluginSlotArbiter: ObservableObject {
    static let shared = PluginSlotArbiter()

    @Published private(set) var activeLeft: PluginCompactContent?
    @Published private(set) var activeLeftPluginId: String?
    @Published private(set) var activeRight: PluginCompactContent?
    @Published private(set) var activeRightPluginId: String?
    @Published private(set) var pendingNotifications: [PluginNotifyUpdate] = []
    @Published private(set) var expandedContent: [String: [ExpandedSection]] = [:]
    @Published var currentlyDisplayedExpandedPluginId: String?

    private var leftSlots: [(pluginId: String, content: PluginCompactContent)] = []
    private var rightSlots: [(pluginId: String, content: PluginCompactContent)] = []
    private var leftCarouselIndex = 0
    private var rightCarouselIndex = 0
    private var coreLeftActive = false
    private var coreRightActive = false
    private var carouselTimer: Timer?

    init() {
        startCarouselTimer()
    }

    private func startCarouselTimer() {
        carouselTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickCarousel()
            }
        }
    }

    private func tickCarousel() {
        var changed = false
        if leftSlots.count > 1 {
            leftCarouselIndex = (leftCarouselIndex + 1) % leftSlots.count
            changed = true
        }
        if rightSlots.count > 1 {
            rightCarouselIndex = (rightCarouselIndex + 1) % rightSlots.count
            changed = true
        }
        if changed { recompute() }
    }

    func handleCompact(_ update: PluginCompactUpdate) {
        switch update.position {
        case .left:
            leftSlots.removeAll { $0.pluginId == update.pluginId }
            if let content = update.content {
                leftSlots.append((update.pluginId, sanitize(content)))
            }
            leftCarouselIndex = 0
        case .right:
            rightSlots.removeAll { $0.pluginId == update.pluginId }
            if let content = update.content {
                rightSlots.append((update.pluginId, sanitize(content)))
            }
            rightCarouselIndex = 0
        }
        recompute()
    }

    func handleNotify(_ update: PluginNotifyUpdate) {
        var sanitized = update
        if let d = update.content.duration {
            let clamped = min(max(d, 0.5), 10.0)
            sanitized = PluginNotifyUpdate(
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
        }
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
        leftSlots.removeAll { $0.pluginId == pluginId }
        rightSlots.removeAll { $0.pluginId == pluginId }
        expandedContent.removeValue(forKey: pluginId)
        pendingNotifications.removeAll { $0.pluginId == pluginId }
        recompute()
    }

    func advanceCarousel(side: CompactPosition) {
        switch side {
        case .left:
            guard leftSlots.count > 1 else { return }
            leftCarouselIndex = (leftCarouselIndex + 1) % leftSlots.count
        case .right:
            guard rightSlots.count > 1 else { return }
            rightCarouselIndex = (rightCarouselIndex + 1) % rightSlots.count
        }
        recompute()
    }

    private func recompute() {
        if coreLeftActive || leftSlots.isEmpty {
            activeLeft = nil
            activeLeftPluginId = nil
        } else {
            let idx = leftCarouselIndex % leftSlots.count
            activeLeft = leftSlots[idx].content
            activeLeftPluginId = leftSlots[idx].pluginId
        }

        if coreRightActive || rightSlots.isEmpty {
            activeRight = nil
            activeRightPluginId = nil
        } else {
            let idx = rightCarouselIndex % rightSlots.count
            activeRight = rightSlots[idx].content
            activeRightPluginId = rightSlots[idx].pluginId
        }
    }

    private func sanitize(_ content: PluginCompactContent) -> PluginCompactContent {
        let label = content.label.map { String($0.prefix(4)) }
        let badge = content.badge.map { max(0, $0) }
        return PluginCompactContent(icon: content.icon, label: label, badge: badge, tint: content.tint)
    }
}
