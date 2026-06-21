import Combine
import Foundation

enum BridgeRuntimeConfigWriter {
    static func write(routePromptsToTerminal: Bool) {}
}

enum HookInstaller {
    struct CustomHookInstallation: Identifiable {
        let id: String
        let profileID: String
        let directoryPath: String
    }

    struct BridgeHealthStatus {
        var isHealthy: Bool
        var message: String
    }

    enum QoderCLIHookRefreshStatus {
        case upToDate
        case needsRefresh
    }

    static func installIfNeeded(
        markPresentationOnboardingPending: @escaping () -> Void,
        markHookInstallOnboardingPending: @escaping () -> Void
    ) {}

    static func performFirstRunDefaultInstall() {}
    static func performFirstRunDefaultInstallWithUserAuthorization() -> Bool { false }
    static func getVersionMetadata() -> [String: Any]? { nil }
    static func loadSelection(for profile: ManagedHookClientProfile) -> HookInstallSelection {
        .defaultSelection(for: profile)
    }
    static func installCustom(profileID: String, directoryPath: String) {}
    static func uninstall() {}
    static func uninstallAllWithUserAuthorization() -> Bool { true }
    static func uninstallCustom(id: String) {}
    static func customInstallations() -> [CustomHookInstallation] { [] }
    static func bridgeHealthStatus() -> BridgeHealthStatus {
        BridgeHealthStatus(isHealthy: false, message: "Bridge 已移除")
    }
    static func qoderCLIHookRefreshStatus() -> QoderCLIHookRefreshStatus? { nil }
    static func defaultEnabledManageableProfiles() -> [ManagedHookClientProfile] { [] }

    #if APP_STORE
    static func restoreAppStoreHookDirectoryAuthorizationIfAvailable() {}
    #endif
}

@MainActor
class HookWalkthroughDemoRunner {
    static let shared = HookWalkthroughDemoRunner()
    func start() {}
}

enum IDEExtensionInstaller {
    static func cleanupLegacyTraeExtension() {}
}

struct HookEvent: Codable, Sendable {
    let type: String
    let payload: [String: AnyCodable]?
    var sessionId: String { "" }
    var event: String { type }
    var status: String { "" }
    var provider: SessionProvider { .unknown }
    var cwd: String { "" }
    var message: String? { nil }
}

@MainActor
class SessionStore {
    static let shared = SessionStore()
    var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func diagnosticsSnapshot() -> [String: Any] { [:] }
}

@MainActor
class SessionAssociationStore {
    static let shared = SessionAssociationStore()
    static var diagnosticsFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-associations-stub.json")
    }
    func export() -> [String: Any] { [:] }
}

class CodexAppServerMonitor {
    static let shared = CodexAppServerMonitor()
    var isActive: Bool { false }
    func diagnosticsSnapshot() -> [String: Any] { [:] }
}

@MainActor
class RemoteConnectorManager {
    static let shared = RemoteConnectorManager()
    func diagnosticsSnapshot() -> [String: Any] { [:] }
}

extension NSNotification.Name {
    static let bridgeRuntimeConfigDidChange = NSNotification.Name("bridgeRuntimeConfigDidChange")
}
