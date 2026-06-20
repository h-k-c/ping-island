import SwiftUI

/// Renders plugin content using island-native design tokens.
enum IslandPluginRenderer {

    // MARK: - Compact slot

    @ViewBuilder
    static func compactView(content: PluginCompactContent) -> some View {
        HStack(spacing: 2.5) {
            if let icon = content.icon {
                iconView(icon, size: 8.8)
                    .foregroundStyle(tintColor(content.tint).opacity(0.86))
            }

            if let label = content.label {
                compactLabelView(label, hasIcon: content.icon != nil)
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

    private static func compactLabelFont(hasIcon: Bool) -> Font {
        .custom("AvenirNextCondensed-Medium", size: hasIcon ? 10.2 : 10.4)
    }

    @ViewBuilder
    private static func compactLabelView(_ label: String, hasIcon: Bool) -> some View {
        if label.hasSuffix("/s") {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(label.dropLast(2)))
                    .font(compactLabelFont(hasIcon: hasIcon))
                Text("/s")
                    .font(.custom("AvenirNextCondensed-Medium", size: hasIcon ? 8.0 : 7.8))
                    .baselineOffset(0.2)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .foregroundStyle(.white.opacity(0.84))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(label)
                .font(compactLabelFont(hasIcon: hasIcon))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    // MARK: - Expanded sections

    @ViewBuilder
    static func expandedView(sections: [ExpandedSection], pluginId: String? = nil) -> some View {
        let sections = displaySections(from: sections)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                sectionView(section, pluginId: pluginId)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.44))
        )
    }

    private static func displaySections(from sections: [ExpandedSection]) -> [ExpandedSection] {
        var trimmed = sections
        while let first = trimmed.first, isLeadingIntroSection(first) {
            trimmed.removeFirst()
        }
        return trimmed.isEmpty ? sections : trimmed
    }

    private static func isLeadingIntroSection(_ section: ExpandedSection) -> Bool {
        switch section {
        case .text(let text):
            switch text.style ?? .body {
            case .heading:
                return true
            case .body, .caption:
                return text.content.count <= 80
            }
        case .divider:
            return true
        default:
            return false
        }
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
        pluginCard(tint: s.tint, horizontalPadding: 8, verticalPadding: 7) {
            HStack(spacing: 8) {
                if let icon = s.icon {
                    iconBadge(icon, tint: s.tint, size: 24, iconSize: 11)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                    Text(s.value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 6)
                miniChip("STAT", tint: s.tint)
                    .opacity(s.tint == nil ? 0.72 : 1)
            }
        }
    }

    @ViewBuilder
    private static func textView(_ s: TextSection) -> some View {
        let style = s.style ?? .body
        let content = Text(s.content)
            .font(textFont(style))
            .foregroundStyle(textColor(style))
            .lineSpacing(style == .caption ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)

        if style == .heading {
            pluginCard(tint: .purple, horizontalPadding: 9, verticalPadding: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.purple.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .background(Color.purple.opacity(0.16), in: Circle())
                    content
                }
            }
        } else {
            content
                .padding(.horizontal, style == .caption ? 2 : 4)
        }
    }

    @ViewBuilder
    private static func listView(_ s: ListSection) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 7),
                GridItem(.flexible(), spacing: 7)
            ],
            alignment: .leading,
            spacing: 7
        ) {
            ForEach(Array(s.items.enumerated()), id: \.offset) { index, item in
                listTile(item, index: index)
            }
        }
    }

    @ViewBuilder
    private static func listTile(_ item: ListSection.Item, index: Int) -> some View {
        let tint = paletteTint(index)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                if let icon = item.icon {
                    iconBadge(icon, tint: tint, size: 24, iconSize: 10.5)
                } else {
                    Circle()
                        .fill(tintColor(tint).opacity(0.78))
                        .frame(width: 8, height: 8)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            Text(item.label)
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if let value = item.value {
                Text(value)
                    .font(.system(size: 12.4, weight: .bold, design: .rounded))
                    .foregroundStyle(tintColor(tint).opacity(0.98))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .aspectRatio(1, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tintColor(tint).opacity(0.16),
                            Color.white.opacity(0.065),
                            Color.black.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tintColor(tint).opacity(0.20), lineWidth: 0.8)
                )
        )
    }

    @ViewBuilder
    private static func progressView(_ s: ProgressSection) -> some View {
        let value = clamped(s.value)
        pluginCard(tint: s.tint, horizontalPadding: 8, verticalPadding: 7) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    iconBadge(.sf(name: "chart.bar.fill"), tint: s.tint, size: 22, iconSize: 10)
                    Text(s.label ?? "Progress")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    miniChip("\(Int(value * 100))%", tint: s.tint)
                }
                progressTrack(value: value, tint: s.tint, height: 6)
            }
        }
    }

    @ViewBuilder
    private static func chartView(_ s: ChartSection) -> some View {
        pluginCard(tint: .purple, horizontalPadding: 8, verticalPadding: 7) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    iconBadge(.sf(name: (s.style ?? .line) == .bar ? "chart.bar.xaxis" : "waveform.path.ecg"), tint: .purple, size: 22, iconSize: 10)
                    if let label = s.label {
                        Text(label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    miniChip((s.style ?? .line) == .bar ? "BAR" : "TREND", tint: .purple)
                }
                let normalized = normalizeValues(s.values)
                GeometryReader { geo in
                    let style = s.style ?? .line
                    ZStack(alignment: .bottomLeading) {
                        chartGrid()
                        if style == .bar {
                            barChart(values: normalized, in: geo)
                        } else {
                            lineChart(values: normalized, in: geo)
                        }
                    }
                }
                .frame(height: 34)
            }
        }
    }

    @ViewBuilder
    private static func buttonView(_ s: ButtonSection, pluginId: String?) -> some View {
        Button {
            var info: [String: Any] = ["actionId": s.actionId]
            // Support action types: callback (default), openURL, writeClipboard
            if let actionType = s.actionType {
                info["actionType"] = actionType
                if let actionValue = s.actionValue { info["value"] = actionValue }
            }
            postPluginAction(userInfo: info, pluginId: pluginId)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: actionIcon(actionType: s.actionType, destructive: s.style == .destructive))
                    .font(.system(size: 10.5, weight: .semibold))
                Text(s.label)
                    .font(.system(size: 10.8, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
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
            .stroke(
                LinearGradient(
                    colors: [tintColor(.blue), tintColor(.purple), tintColor(.green)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: tintColor(.blue).opacity(0.22), radius: 6, y: 1)
        }
    }

    @ViewBuilder
    private static func barChart(values: [Double], in geo: GeometryProxy) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, v in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tintColor(paletteTint(index)).opacity(0.88),
                                tintColor(paletteTint(index)).opacity(0.36)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: max(2, geo.size.height * CGFloat(v)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    // MARK: - New section renderers

    @ViewBuilder
    private static func checkboxView(_ s: CheckboxSection, pluginId: String?) -> some View {
        pluginCard(tint: s.checked ? .green : .default, horizontalPadding: 8, verticalPadding: 7) {
            HStack(spacing: 8) {
                Image(systemName: s.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(s.checked ? tintColor(.green) : Color.white.opacity(0.38))
                    .frame(width: 22, height: 22)
                    .background((s.checked ? tintColor(.green) : Color.white).opacity(0.12), in: Circle())
                Text(s.label)
                    .font(.system(size: 10.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                Spacer(minLength: 6)
                miniChip(s.checked ? "ON" : "OFF", tint: s.checked ? .green : .default)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                image.resizable()
                    .aspectRatio(s.aspectRatio ?? 1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
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
        pluginCard(tint: .blue, horizontalPadding: 8, verticalPadding: 8) {
            HStack(spacing: 9) {
                mediaArtwork(urlString: s.imageURL, isPlaying: s.isPlaying == true)
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        if let sub = s.subtitle {
                            Text(sub)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                    }
                    if let progress = s.progress {
                        progressTrack(value: clamped(progress), tint: .blue, height: 4)
                    }
                    if let actions = s.actions {
                        HStack(spacing: 7) {
                            if let prev = actions.previous {
                                mediaButton(systemName: "backward.fill", actionId: prev, pluginId: pluginId)
                            }
                            if let tog = actions.toggle {
                                mediaButton(
                                    systemName: s.isPlaying == true ? "pause.fill" : "play.fill",
                                    actionId: tog,
                                    pluginId: pluginId,
                                    prominent: true
                                )
                            }
                            if let nxt = actions.next {
                                mediaButton(systemName: "forward.fill", actionId: nxt, pluginId: pluginId)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private static func stepView(_ s: StepSection) -> some View {
        pluginCard(tint: .green, horizontalPadding: 8, verticalPadding: 7) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(s.steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 7) {
                        stepStatusIcon(step.status)
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(width: 21, height: 21)
                            .background(stepTint(step.status).opacity(0.12), in: Circle())
                        Text(step.label)
                            .font(.system(size: 10.8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.80))
                            .lineLimit(1)
                        Spacer(minLength: 5)
                        if let dur = step.duration {
                            Text(dur)
                                .font(.system(size: 9.3, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.50))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.07), in: Capsule())
                        }
                    }
                    if index < s.steps.count - 1 {
                        Divider()
                            .background(.white.opacity(0.06))
                            .padding(.leading, 29)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private static func stepStatusIcon(_ status: String) -> some View {
        switch status {
        case "success": Image(systemName: "checkmark").foregroundStyle(tintColor(.green))
        case "failed":  Image(systemName: "xmark").foregroundStyle(tintColor(.red))
        case "running": Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(tintColor(.blue))
        case "skipped": Image(systemName: "minus").foregroundStyle(.white.opacity(0.46))
        default:        Image(systemName: "circle.fill").foregroundStyle(.white.opacity(0.30))
        }
    }

    @ViewBuilder
    private static func actionToggleView(_ s: ActionToggleSection, pluginId: String?) -> some View {
        pluginCard(tint: s.active ? .green : .purple, horizontalPadding: 8, verticalPadding: 7) {
            HStack(spacing: 8) {
                iconBadge(.sf(name: s.active ? "bolt.fill" : "bolt.slash.fill"), tint: s.active ? .green : .purple, size: 23, iconSize: 10)
                Text(s.label)
                    .font(.system(size: 10.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                Spacer(minLength: 6)
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
                .tint(tintColor(s.active ? .green : .purple))
            }
        }
    }

    @ViewBuilder
    private static func pluginCard<Content: View>(
        tint: PluginTint?,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 7,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.095),
                                tintColor(tint).opacity(0.045),
                                Color.white.opacity(0.035)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        tintColor(tint).opacity(0.22),
                                        Color.white.opacity(0.055)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
            )
    }

    @ViewBuilder
    private static func iconBadge(_ icon: PluginIcon, tint: PluginTint?, size: CGFloat, iconSize: CGFloat) -> some View {
        iconView(icon, size: iconSize)
            .foregroundStyle(tintColor(tint).opacity(0.94))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(tintColor(tint).opacity(0.14))
                    .overlay(Circle().stroke(tintColor(tint).opacity(0.20), lineWidth: 0.8))
            )
    }

    @ViewBuilder
    private static func miniChip(_ label: String, tint: PluginTint?) -> some View {
        Text(label)
            .font(.system(size: 8.2, weight: .bold, design: .rounded))
            .foregroundStyle(tintColor(tint).opacity(0.94))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(tintColor(tint).opacity(0.13), in: Capsule())
            .overlay(Capsule().stroke(tintColor(tint).opacity(0.14), lineWidth: 0.7))
    }

    @ViewBuilder
    private static func progressTrack(value: Double, tint: PluginTint?, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tintColor(tint).opacity(0.95), tintColor(tint).opacity(0.48)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(height, geo.size.width * CGFloat(clamped(value))))
                    .shadow(color: tintColor(tint).opacity(0.24), radius: 5, y: 1)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private static func chartGrid() -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 0.7)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private static func mediaArtwork(urlString: String?, isPlaying: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let imgURL = urlString, let url = URL(string: imgURL) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
            Image(systemName: isPlaying ? "waveform" : "music.note")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 16, height: 16)
                .background(tintColor(isPlaying ? .green : .blue).opacity(0.92), in: Circle())
                .padding(3)
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private static var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tintColor(.purple).opacity(0.55), tintColor(.blue).opacity(0.28)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "play.square.stack.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
    }

    @ViewBuilder
    private static func mediaButton(systemName: String, actionId: String, pluginId: String?, prominent: Bool = false) -> some View {
        Button {
            postPluginAction(userInfo: ["actionId": actionId], pluginId: pluginId)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 11 : 9.5, weight: .bold))
                .foregroundStyle(prominent ? .black : .white.opacity(0.78))
                .frame(width: prominent ? 28 : 24, height: prominent ? 22 : 20)
                .background(prominent ? Color.white.opacity(0.92) : Color.white.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private static func clamped(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private static func paletteTint(_ index: Int) -> PluginTint {
        switch index % 6 {
        case 0: return .blue
        case 1: return .green
        case 2: return .purple
        case 3: return .orange
        case 4: return .yellow
        default: return .red
        }
    }

    private static func stepTint(_ status: String) -> Color {
        switch status {
        case "success": return tintColor(.green)
        case "failed": return tintColor(.red)
        case "running": return tintColor(.blue)
        case "skipped": return .white.opacity(0.55)
        default: return .white.opacity(0.35)
        }
    }

    private static func actionIcon(actionType: String?, destructive: Bool) -> String {
        if destructive { return "trash.fill" }
        switch actionType {
        case "openURL": return "arrow.up.right"
        case "writeClipboard": return "doc.on.clipboard"
        case "runShortcut": return "sparkles"
        case "emitEvent": return "bolt.horizontal.fill"
        default: return "cursorarrow.click.2"
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
        let tint = destructive ? Color.red : Color(red: 0.4, green: 0.7, blue: 1.0)
        configuration.label
            .foregroundStyle(destructive ? Color.red.opacity(0.95) : .white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(configuration.isPressed ? 0.24 : 0.16),
                                Color.white.opacity(configuration.isPressed ? 0.13 : 0.075)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.8))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
