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
    static func expandedView(sections: [ExpandedSection], pluginId: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                sectionView(section, pluginId: pluginId)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    static func sectionView(_ section: ExpandedSection, pluginId: String? = nil) -> some View {
        switch section {
        case .stat(let s):         statView(s)
        case .text(let s):         textView(s)
        case .list(let s):         listView(s)
        case .progress(let s):     progressView(s)
        case .chart(let s):        chartView(s)
        case .button(let s):       buttonView(s, pluginId: pluginId)
        case .divider:             Divider().background(.white.opacity(0.1))
        case .checkbox(let s):     checkboxView(s, pluginId: pluginId)
        case .input(let s):        inputView(s, pluginId: pluginId)
        case .image(let s):        imageView(s)
        case .slider(let s):       sliderView(s, pluginId: pluginId)
        case .media(let s):        mediaView(s, pluginId: pluginId)
        case .step(let s):         stepView(s)
        case .actionToggle(let s): actionToggleView(s, pluginId: pluginId)
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
    private static func buttonView(_ s: ButtonSection, pluginId: String?) -> some View {
        Button(s.label) {
            var info: [String: Any] = ["actionId": s.actionId]
            // Support action types: callback (default), openURL, writeClipboard
            if let actionType = s.actionType {
                info["actionType"] = actionType
                if let actionValue = s.actionValue { info["value"] = actionValue }
            }
            postPluginAction(userInfo: info, pluginId: pluginId)
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

    // MARK: - New section renderers

    @ViewBuilder
    private static func checkboxView(_ s: CheckboxSection, pluginId: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(s.checked ? Color.blue : Color.white.opacity(0.4))
            Text(s.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            postPluginAction(
                userInfo: ["actionId": s.actionId, "value": !s.checked],
                pluginId: pluginId
            )
        }
    }

    @ViewBuilder
    private static func inputView(_ s: InputSection, pluginId: String?) -> some View {
        _InputSectionView(section: s, pluginId: pluginId)
    }

    @ViewBuilder
    private static func imageView(_ s: ImageSection) -> some View {
        if let url = URL(string: s.url) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(s.aspectRatio ?? 1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                    .frame(height: 80)
            }
        }
    }

    @ViewBuilder
    private static func sliderView(_ s: SliderSection, pluginId: String?) -> some View {
        _SliderSectionView(section: s, pluginId: pluginId)
    }

    @ViewBuilder
    private static func mediaView(_ s: MediaSection, pluginId: String?) -> some View {
        VStack(spacing: 6) {
            if let imgURL = s.imageURL, let url = URL(string: imgURL) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(1, contentMode: .fill)
                        .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)).frame(width: 48, height: 48)
                }
            }
            Text(s.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            if let sub = s.subtitle {
                Text(sub).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let actions = s.actions {
                HStack(spacing: 16) {
                    if let prev = actions.previous {
                        Button { postPluginAction(userInfo: ["actionId": prev], pluginId: pluginId) } label: {
                            Image(systemName: "backward.fill").font(.system(size: 14))
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                    }
                    if let tog = actions.toggle {
                        Button { postPluginAction(userInfo: ["actionId": tog], pluginId: pluginId) } label: {
                            Image(systemName: s.isPlaying == true ? "pause.fill" : "play.fill").font(.system(size: 18))
                        }.buttonStyle(.plain).foregroundStyle(.white)
                    }
                    if let nxt = actions.next {
                        Button { postPluginAction(userInfo: ["actionId": nxt], pluginId: pluginId) } label: {
                            Image(systemName: "forward.fill").font(.system(size: 14))
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            if let progress = s.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.15))
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.7))
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))))
                    }
                }.frame(height: 3)
            }
        }
    }

    @ViewBuilder
    private static func stepView(_ s: StepSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(s.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    stepStatusIcon(step.status)
                    Text(step.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if let dur = step.duration {
                        Text(dur).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private static func stepStatusIcon(_ status: String) -> some View {
        switch status {
        case "success": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":  Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "running": Image(systemName: "arrow.clockwise").foregroundStyle(.blue)
        case "skipped": Image(systemName: "minus.circle").foregroundStyle(.secondary)
        default:        Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private static func actionToggleView(_ s: ActionToggleSection, pluginId: String?) -> some View {
        HStack(spacing: 8) {
            Text(s.label).font(.system(size: 11)).foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { s.active },
                set: { newVal in
                    postPluginAction(
                        userInfo: ["actionId": s.actionId, "value": newVal],
                        pluginId: pluginId
                    )
                }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }

    private static func postPluginAction(userInfo: [String: Any], pluginId: String?) {
        var resolved = userInfo
        if let pluginId {
            resolved["pluginId"] = pluginId
        }
        NotificationCenter.default.post(name: .pluginButtonTapped, object: nil, userInfo: resolved)
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

// MARK: - Stateful helper views for Input and Slider sections

private struct _InputSectionView: View {
    let section: InputSection
    let pluginId: String?
    @State private var text = ""
    var body: some View {
        HStack(spacing: 6) {
            Group {
                if section.secure == true {
                    SecureField(section.placeholder ?? "输入…", text: $text)
                } else {
                    TextField(section.placeholder ?? "输入…", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            Button("→") {
                var info: [String: Any] = ["actionId": section.actionId, "value": text]
                if let pluginId {
                    info["pluginId"] = pluginId
                }
                NotificationCenter.default.post(name: .pluginButtonTapped, object: nil, userInfo: info)
                text = ""
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .font(.system(size: 12, weight: .semibold))
        }
    }
}

private struct _SliderSectionView: View {
    let section: SliderSection
    let pluginId: String?
    @State private var value: Double
    init(section: SliderSection, pluginId: String?) {
        self.section = section
        self.pluginId = pluginId
        _value = State(initialValue: section.value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = section.label {
                HStack {
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f", value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Slider(value: $value, in: (section.min ?? 0)...(section.max ?? 1))
                .accentColor(.white)
                .onChange(of: value) { _, newVal in
                    var info: [String: Any] = ["actionId": section.actionId, "value": newVal]
                    if let pluginId {
                        info["pluginId"] = pluginId
                    }
                    NotificationCenter.default.post(name: .pluginButtonTapped, object: nil, userInfo: info)
                }
        }
    }
}
