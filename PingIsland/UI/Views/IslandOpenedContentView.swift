import SwiftUI

struct IslandOpenedContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    let surface: IslandExpandedSurface
    let trigger: IslandExpandedTrigger
    let style: IslandOpenedPresentationStyle
    var activePluginNotification: PluginNotifyUpdate? = nil
    var contentWidthOverride: CGFloat? = nil
    let onDismissPluginNotification: () -> Void

    var body: some View {
        routeContent
            .frame(width: contentWidth)
    }

    private var route: IslandExpandedRoute {
        IslandExpandedRouteResolver.resolve(
            surface: surface,
            trigger: trigger,
            contentType: viewModel.contentType,
            activePluginNotification: activePluginNotification
        )
    }

    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .pluginNotification(let notification):
            PluginNotificationPanelView(
                notification: notification,
                onDismiss: onDismissPluginNotification
            )
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OpenedPanelContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
        case .plugin(let pluginId):
            if pluginId == PluginSlotArbiter.stickyPeekPluginId {
                // The recorder is always a single compact row — no scrolling, so it
                // never turns into a vertically draggable surface when collapsing.
                PluginExpandedPanelView(pluginId: pluginId)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    PluginExpandedPanelView(pluginId: pluginId)
                }
                .frame(maxHeight: pluginContentMaxHeight)
            }
        case .empty:
            EmptyView()
        }
    }

    private var contentWidth: CGFloat {
        if let contentWidthOverride {
            return contentWidthOverride
        }

        switch style {
        case .docked:
            return viewModel.openedSize.width - 24
        case .detached:
            return viewModel.detachedSize.width - 24
        }
    }

    private var pluginContentMaxHeight: CGFloat {
        // Floor kept low so SHORT panels (e.g. the recorder's peek bar) don't get
        // forced taller than the notch frame — which would overflow the frame and
        // make controls in the overflow region untappable. Tall panels (procmonitor
        // etc.) are unaffected since their measured height far exceeds the floor.
        switch style {
        case .docked:
            return max(36, viewModel.openedSize.height - viewModel.closedHeight)
        case .detached:
            return max(36, viewModel.detachedSize.height - viewModel.closedHeight)
        }
    }
}
