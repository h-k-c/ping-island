import SwiftUI

/// Renders plugin content using island-native design tokens.
enum IslandPluginRenderer {

    // MARK: - Compact slot

    @ViewBuilder
    static func compactView(content: PluginCompactContent) -> some View {
        HStack(spacing: 3) {
            iconView(content.icon, size: 11)
                .foregroundStyle(tintColor(content.tint).opacity(0.9))

            if let label = content.label {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }

            if let badge = content.badge, badge > 0 {
                Text("\(min(badge, 99))")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
        }
    }

    // MARK: - Expanded sections

    @ViewBuilder
    static func expandedView(sections: [ExpandedSection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    static func sectionView(_ section: ExpandedSection) -> some View {
        switch section {
        case .stat(let s):     statView(s)
        case .text(let s):     textView(s)
        case .list(let s):     listView(s)
        case .progress(let s): progressView(s)
        case .chart(let s):    chartView(s)
        case .button(let s):   buttonView(s)
        case .divider:         Divider().background(.white.opacity(0.1))
        }
    }

    @ViewBuilder
    private static func statView(_ s: StatSection) -> some View {
        HStack {
            if let icon = s.icon {
                iconView(icon, size: 12)
                    .foregroundStyle(tintColor(s.tint).opacity(0.8))
            }
            Text(s.label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(s.value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private static func textView(_ s: TextSection) -> some View {
        Text(s.content)
            .font(textFont(s.style))
            .foregroundStyle(textColor(s.style))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private static func listView(_ s: ListSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(s.items.enumerated()), id: \.offset) { _, item in
                HStack {
                    if let icon = item.icon {
                        iconView(icon, size: 11)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(item.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if let value = item.value {
                        Text(value)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private static func progressView(_ s: ProgressSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = s.label {
                HStack {
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(s.value * 100))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tintColor(s.tint))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, s.value))))
                }
            }
            .frame(height: 4)
        }
    }

    @ViewBuilder
    private static func chartView(_ s: ChartSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = s.label {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            let normalized = normalizeValues(s.values)
            GeometryReader { geo in
                let style = s.style ?? .line
                if style == .bar {
                    barChart(values: normalized, in: geo)
                } else {
                    lineChart(values: normalized, in: geo)
                }
            }
            .frame(height: 28)
        }
    }

    @ViewBuilder
    private static func buttonView(_ s: ButtonSection) -> some View {
        Button(s.label) {
            var info: [String: Any] = ["actionId": s.actionId]
            // Support action types: callback (default), openURL, writeClipboard
            if let actionType = s.actionType {
                info["actionType"] = actionType
                if let actionValue = s.actionValue { info["value"] = actionValue }
            }
            NotificationCenter.default.post(name: .pluginButtonTapped, object: nil, userInfo: info)
        }
        .buttonStyle(IslandPluginButtonStyle(destructive: s.style == .destructive))
    }

    @ViewBuilder
    private static func lineChart(values: [Double], in geo: GeometryProxy) -> some View {
        if values.count >= 2 {
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let step = w / Double(values.count - 1)
                path.move(to: CGPoint(x: 0, y: h * (1 - values[0])))
                for (i, v) in values.enumerated().dropFirst() {
                    path.addLine(to: CGPoint(x: Double(i) * step, y: h * (1 - v)))
                }
            }
            .stroke(.white.opacity(0.7), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private static func barChart(values: [Double], in geo: GeometryProxy) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.6))
                    .frame(height: max(2, geo.size.height * CGFloat(v)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    static func iconView(_ icon: PluginIcon, size: CGFloat) -> some View {
        switch icon {
        case .sf(let name):
            Image(systemName: name)
                .font(.system(size: size))
        case .emoji(let value):
            Text(value)
                .font(.system(size: size))
        }
    }

    private static func tintColor(_ tint: PluginTint?) -> Color {
        switch tint ?? .default {
        case .default: return .white
        case .green:   return .green
        case .yellow:  return .yellow
        case .red:     return .red
        case .blue:    return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .orange:  return .orange
        case .purple:  return .purple
        }
    }

    private static func textFont(_ style: TextSection.Style?) -> Font {
        switch style ?? .body {
        case .heading: return .system(size: 13, weight: .semibold)
        case .body:    return .system(size: 11)
        case .caption: return .system(size: 10, weight: .light)
        }
    }

    private static func textColor(_ style: TextSection.Style?) -> Color {
        switch style ?? .body {
        case .heading: return .white
        case .body:    return .white.opacity(0.8)
        case .caption: return .white.opacity(0.5)
        }
    }

    private static func normalizeValues(_ values: [Double]) -> [Double] {
        guard let max = values.max(), max > 0 else { return values.map { _ in 0 } }
        return values.map { $0 / max }
    }
}

private struct IslandPluginButtonStyle: ButtonStyle {
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(destructive ? .red : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(configuration.isPressed ? 0.2 : 0.1))
            )
    }
}

extension Notification.Name {
    static let pluginButtonTapped = Notification.Name("PluginButtonTapped")
}
