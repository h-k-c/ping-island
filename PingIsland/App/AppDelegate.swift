import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowManager: WindowManager?
    private var screenObserver: ScreenObserver?
    private let launchConfiguration = AppLaunchConfiguration()
    private let globalShortcutManager = GlobalShortcutManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)

        if launchConfiguration.shouldEnforceSingleInstance && !ensureSingleInstance() {
            NSApplication.shared.terminate(nil)
            return
        }

        _ = AppSettings.shared

        if !launchConfiguration.isRunningTests {
            UpdateManager.shared.start()
            UserIdleAutoProtection.shared.start()
            Task {
                await TelemetryService.shared.start()
            }
            Task {
                await PluginHost.shared.start()
            }
            NotificationCenter.default.addObserver(
                forName: .pluginButtonTapped,
                object: nil,
                queue: .main
            ) { notification in
                guard let actionId = notification.userInfo?["actionId"] as? String else { return }
                let value = notification.userInfo?["value"]
                let actionType = notification.userInfo?["actionType"] as? String ?? "callback"
                Task { @MainActor in
                    switch actionType {
                    case "openURL":
                        if let urlStr = value as? String, let url = URL(string: urlStr) {
                            NSWorkspace.shared.open(url)
                        }
                    case "writeClipboard":
                        if let str = value as? String {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(str, forType: .string)
                        }
                    default:
                        guard let pluginId = notification.userInfo?["pluginId"] as? String
                            ?? PluginSlotArbiter.shared.currentlyDisplayedExpandedPluginId else { return }
                        await PluginHost.shared.sendAction(actionId: actionId, value: value, to: pluginId)
                    }
                }
            }
        }

        if launchConfiguration.shouldInstallIntegrations {
            NotchDetachmentHintExperience.prepareForLaunch(
                previousVersion: nil,
                markHintsPending: {
                    AppSettings.notchDetachmentHintPending = true
                    AppSettings.floatingPetSettingsHintPending = true
                }
            )
        }

        NSApplication.shared.setActivationPolicy(launchConfiguration.activationPolicy)

        let launchFlow = AppLaunchFlow(
            configuration: launchConfiguration,
            presentationModeOnboardingPending: AppSettings.presentationModeOnboardingPending
        )

        if launchFlow.shouldCreateInitialIslandWindow {
            startWindowManagerIfNeeded()
        }

        if launchConfiguration.shouldObserveScreens {
            screenObserver = ScreenObserver { [weak self] in
                self?.handleScreenChange()
            }
        }

        globalShortcutManager.start()

        if launchFlow.shouldPresentSurfaceModeOnboarding {
            PresentationModeWelcomeWindowController.shared.present { [weak self] selectedMode in
                self?.completePresentationModeOnboarding(with: selectedMode)
            }
        } else if launchFlow.shouldPresentSettingsWindowImmediately {
            SettingsWindowController.shared.present()
        }

        Task { @MainActor in
            AppSettings.playClientStartupSound()
        }

        if !launchConfiguration.isRunningTests {
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await TelemetryService.shared.recordAppLaunch()
                await TelemetryService.shared.recordIntegrationSnapshot()
            }
        }
    }

    @MainActor
    private func handleScreenChange() {
        guard !AppSettings.presentationModeOnboardingPending else { return }
        startWindowManagerIfNeeded()
    }

    @MainActor
    private func completePresentationModeOnboarding(with selectedMode: IslandSurfaceMode) {
        AppSettings.surfaceMode = selectedMode
        AppSettings.presentationModeOnboardingPending = false
        AppSettings.notchDetachmentHintPending = false
        AppSettings.floatingPetSettingsHintPending = false
        startWindowManagerIfNeeded()

        SettingsWindowController.shared.present()
    }

    @MainActor
    private func startWindowManagerIfNeeded() {
        if windowManager == nil {
            windowManager = WindowManager()
        }
        _ = windowManager?.setupNotchWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenObserver = nil
        UserIdleAutoProtection.shared.stop()
        Task {
            await TelemetryService.shared.stop()
        }
        Task {
            await PluginHost.shared.stop()
        }
    }

    private func ensureSingleInstance() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.wudanwu.PingIsland"
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID
        }

        if runningApps.count > 1 {
            if let existingApp = runningApps.first(where: { $0.processIdentifier != getpid() }) {
                existingApp.activate()
            }
            return false
        }

        return true
    }
}
