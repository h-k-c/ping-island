import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let settingsWindowVisibilityDidChange = Notification.Name("settingsWindowVisibilityDidChange")
    static let settingsWindowCategorySelectionRequested = Notification.Name("settingsWindowCategorySelectionRequested")
}

enum SettingsWindowVisibilityNotification {
    static let isVisibleKey = "isVisible"
}

enum SettingsWindowCategorySelectionRequest {
    static let categoryKey = "category"
}

final class SettingsPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let defaultContentSize = NSSize(
        width: SettingsWindowDefaults.defaultContentSize.width,
        height: SettingsWindowDefaults.defaultContentSize.height
    )
    private let minimumContentSize = NSSize(
        width: AppSettings.minimumSettingsWindowSize.width,
        height: AppSettings.minimumSettingsWindowSize.height
    )
    private let maximumContentSize = NSSize(
        width: AppSettings.maximumSettingsWindowSize.width,
        height: AppSettings.maximumSettingsWindowSize.height
    )

    private init() {
        let hostingController = NSHostingController(
            rootView: SettingsWindowView()
        )
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.minSize = minimumContentSize
        window.maxSize = maximumContentSize
        window.setContentSize(defaultContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.center()
        window.toolbar = nil
        window.showsToolbarButton = false
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)

        self.window?.delegate = self
        hostingController.rootView = SettingsWindowView(
            onClose: { [weak self] in
                self?.dismiss()
            },
            onMinimize: { [weak self] in
                self?.window?.miniaturize(nil)
            }
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }

        window.minSize = minimumContentSize
        window.maxSize = maximumContentSize
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        publishVisibilityDidChange(isVisible: true)
    }

    func present(category: SettingsCategory) {
        present()
        NotificationCenter.default.post(
            name: .settingsWindowCategorySelectionRequested,
            object: self,
            userInfo: [SettingsWindowCategorySelectionRequest.categoryKey: category.rawValue]
        )
    }

    func dismiss() {
        window?.orderOut(nil)
        publishVisibilityDidChange(isVisible: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        publishVisibilityDidChange(isVisible: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        publishVisibilityDidChange(isVisible: window?.isVisible == true)
    }

    private func publishVisibilityDidChange(isVisible: Bool) {
        NotificationCenter.default.post(
            name: .settingsWindowVisibilityDidChange,
            object: self,
            userInfo: [SettingsWindowVisibilityNotification.isVisibleKey: isVisible]
        )
    }
}

@MainActor
final class PresentationModeWelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PresentationModeWelcomeWindowController()

    private let fixedContentSize = NSSize(width: 760, height: 560)
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private let presentationAnimationDuration: TimeInterval = 0.22
    private let dismissalAnimationDuration: TimeInterval = 0.16
    private var completion: ((IslandSurfaceMode) -> Void)?
    private var isDismissing = false

    private init() {
        let window = SettingsPanelWindow(
            contentRect: NSRect(origin: .zero, size: fixedContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = hostingController
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = fixedContentSize
        window.maxSize = fixedContentSize
        window.setContentSize(fixedContentSize)
        window.identifier = NSUserInterfaceItemIdentifier("presentation-mode-welcome.window")
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        self.window?.delegate = self
        hostingController.view.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(onComplete: @escaping (IslandSurfaceMode) -> Void) {
        isDismissing = false
        completion = onComplete
        hostingController.rootView = AnyView(
            AppLocalizedRootView {
                PresentationModeWelcomeView(initialMode: AppSettings.surfaceMode) { [weak self] mode, analyticsOptIn in
                    AppSettings.analyticsEnabled = analyticsOptIn
                    AppSettings.analyticsConsentPromptCompleted = true
                    self?.finish(with: mode)
                }
            }
        )

        guard let window else { return }
        window.setContentSize(fixedContentSize)
        if !window.isVisible {
            window.center()
        }
        window.alphaValue = 0
        setContentScale(0.965)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        animateContentScale(from: 0.965, to: 1, duration: presentationAnimationDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = presentationAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func dismiss() {
        dismissAnimated()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    private func finish(with mode: IslandSurfaceMode) {
        let completion = completion
        self.completion = nil
        dismissAnimated {
            completion?(mode)
        }
    }

    private func dismissAnimated(completion: (() -> Void)? = nil) {
        guard let window else {
            completion?()
            return
        }
        guard window.isVisible else {
            completion?()
            return
        }
        guard !isDismissing else { return }

        isDismissing = true
        animateContentScale(from: 1, to: 0.985, duration: dismissalAnimationDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = dismissalAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                self.setContentScale(1)
                self.isDismissing = false
                completion?()
            }
        }
    }

    private func setContentScale(_ scale: CGFloat) {
        guard let layer = hostingController.view.layer else { return }
        layer.removeAnimation(forKey: "presentationModeWelcomeScale")
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func animateContentScale(from startScale: CGFloat, to endScale: CGFloat, duration: TimeInterval) {
        guard let layer = hostingController.view.layer else { return }
        layer.removeAnimation(forKey: "presentationModeWelcomeScale")
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = startScale
        animation.toValue = endScale
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: endScale >= startScale ? .easeOut : .easeIn)
        layer.transform = CATransform3DMakeScale(endScale, endScale, 1)
        layer.add(animation, forKey: "presentationModeWelcomeScale")
    }
}

private struct PresentationModeWelcomeView: View {
    let onComplete: (IslandSurfaceMode, Bool) -> Void

    @State private var analyticsOptIn = true

    init(
        initialMode: IslandSurfaceMode,
        onComplete: @escaping (IslandSurfaceMode, Bool) -> Void
    ) {
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.15),
                    Color(red: 0.08, green: 0.11, blue: 0.20),
                    Color(red: 0.16, green: 0.10, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
                .padding(16)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(appLocalized: "首次使用 Auralink")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(.white)

                    Text(appLocalized: "Auralink 会固定使用刘海屏方式，停靠在屏幕顶部中央展示会话、工具和通知。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(appLocalized: "之后可以在设置中调整显示器、默认宠物形象和刘海展示细节。")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $analyticsOptIn) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appLocalized: "帮助提升 Auralink 体验")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.88))
                        Text(appLocalized: "发送匿名使用统计，帮助改进常用功能。不会包含会话内容、代码、路径或主机信息。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .tint(.white)

                HStack {
                    Text(appLocalized: "稍后可在 设置 -> 显示 中调整位置与展示细节")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.56))

                    Spacer(minLength: 16)

                    Button(action: {
                        onComplete(.notch, analyticsOptIn)
                    }) {
                        Text(appLocalized: "开始使用")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.black.opacity(0.86))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
        .frame(width: 760, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 28, y: 16)
        .preferredColorScheme(.dark)
    }
}
