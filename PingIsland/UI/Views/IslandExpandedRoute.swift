import Foundation
import SwiftUI

enum IslandExpandedSurface: Equatable {
    case docked
    case floating
}

enum IslandExpandedTrigger: Equatable {
    case click
    case hover
    case notification
    case pinnedList
}

enum IslandExpandedRoute: Equatable {
    case sessionList
    case hoverDashboard
    case attentionNotification(SessionState)
    case completionNotification(SessionCompletionNotification)
    case pluginNotification(PluginNotifyUpdate)
    case chat(SessionState)
    case plugin(pluginId: String)
}

enum IslandExpandedRouteResolver {
    nonisolated static func resolve(
        surface: IslandExpandedSurface,
        trigger: IslandExpandedTrigger,
        contentType: NotchContentType,
        sessions: [SessionState],
        activeCompletionNotification: SessionCompletionNotification? = nil,
        activePluginNotification: PluginNotifyUpdate? = nil
    ) -> IslandExpandedRoute {
        switch trigger {
        case .notification:
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
        case .click, .hover, .pinnedList:
            break
        }

        if case .plugin(let id) = contentType {
            return .plugin(pluginId: id)
        }

        if case .chat(let session) = contentType {
            return .chat(session)
        }

        switch (surface, trigger) {
        case (.docked, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
            return .sessionList
        case (.docked, .hover), (.floating, .hover):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .hoverDashboard
        case (.floating, .notification):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            if let activeCompletionNotification {
                return .completionNotification(activeCompletionNotification)
            }
            if let activePluginNotification {
                return .pluginNotification(activePluginNotification)
            }
            return .hoverDashboard
        case (_, .click):
            if let session = highestPriorityAttentionSession(from: sessions) {
                return .attentionNotification(session)
            }
            return .sessionList
        case (_, .pinnedList):
            return .sessionList
        }
    }

    nonisolated static func orderedSessions(from sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { $0.shouldSortBeforeInQueue($1) }
    }

    nonisolated static func activePreviewSessions(from sessions: [SessionState]) -> [SessionState] {
        orderedSessions(from: sessions).filter(\.phase.isActive)
    }

    nonisolated static func highestPriorityAttentionSession(from sessions: [SessionState]) -> SessionState? {
        orderedSessions(from: sessions)
            .filter { $0.needsApprovalResponse || $0.needsQuestionResponse }
            .sorted(by: attentionSort)
            .first
    }

    nonisolated private static func attentionSort(_ lhs: SessionState, _ rhs: SessionState) -> Bool {
        let lhsDate = lhs.attentionRequestedAt ?? lhs.lastUserMessageDate ?? lhs.lastActivity
        let rhsDate = rhs.attentionRequestedAt ?? rhs.lastUserMessageDate ?? rhs.lastActivity
        return lhsDate > rhsDate
    }
}

struct PluginExpandedPanelView: View {
    let pluginId: String
    @ObservedObject private var arbiter = PluginSlotArbiter.shared

    var body: some View {
        Group {
            if let sections = arbiter.expandedContent[pluginId] {
                ScrollView {
                    IslandPluginRenderer.expandedView(sections: sections, pluginId: pluginId)
                }
            } else {
                Text("加载中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding()
            }
        }
        .onAppear { arbiter.currentlyDisplayedExpandedPluginId = pluginId }
        .onDisappear {
            if arbiter.currentlyDisplayedExpandedPluginId == pluginId {
                arbiter.currentlyDisplayedExpandedPluginId = nil
            }
        }
    }
}

struct PluginNotificationPanelView: View {
    let notification: PluginNotifyUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                IslandPluginRenderer.iconView(notification.content.icon, size: 18)
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.content.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = notification.content.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            if let actionLabel = notification.content.actionLabel,
               let actionId = notification.content.actionId {
                Button {
                    NotificationCenter.default.post(
                        name: .pluginButtonTapped,
                        object: nil,
                        userInfo: [
                            "pluginId": notification.pluginId,
                            "actionId": actionId
                        ]
                    )
                } label: {
                    Text(actionLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
        )
    }
}
