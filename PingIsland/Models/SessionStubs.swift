import Combine
import Foundation

enum SessionProvider: String, Codable, Hashable, CaseIterable {
    case claude
    case codex
    case copilot
    case kimi
    case gemini
    case unknown
}

enum SessionClientKind: String, Codable, Hashable {
    case hook
    case plugin
    case claudeCode
    case qoder
    case custom
    case codexApp
    case codexCLI
    case unknown
}

enum SessionPhase: String, Codable, Hashable {
    case idle
    case active
    case processing
    case compacting
    case completed
    case ended
    case error
    case waitingForInput
    case waitingForApproval
    case unknown

    var isActive: Bool { self == .active || self == .processing }
    var isCompleted: Bool { self == .completed || self == .ended }
}

struct SessionClientInfo: Equatable, Hashable {
    var provider: SessionProvider = .unknown
    var clientKind: SessionClientKind = .unknown
    var brand: SessionClientBrand = .neutral
    var profileID: String?
    var kind: SessionClientKind = .unknown
    var tmuxPaneIdentifier: String?
    var tmuxSessionIdentifier: String?

    func resolvedProfile(for provider: SessionProvider) -> ManagedHookClientProfile? { nil }
}

struct SessionState: Identifiable, Equatable, Hashable {
    let id: String
    var sessionId: String { id }
    var phase: SessionPhase = .idle
    var lastActivity: Date = Date()
    var attentionRequestedAt: Date?
    var intervention: String?
    var provider: SessionProvider = .unknown
    var clientInfo: SessionClientInfo = SessionClientInfo()
    var needsManualAttention: Bool { false }
    var needsQuestionResponse: Bool { false }
    var needsApprovalResponse: Bool { false }
    var needsAttention: Bool { false }
    var shouldHideFromPrimaryUI: Bool { true }
    var shouldUseMinimalCompactPresentation: Bool { false }
    var usesTitleOnlySubagentPresentation: Bool { false }
    var isInTmux: Bool { false }

    static func == (lhs: SessionState, rhs: SessionState) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct SessionCompletionNotification: Identifiable, Equatable {
    let id: String
}

struct SessionIntervention: Equatable {
    let message: String
}

@MainActor
class SessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    static var isRunningUnderXCTest: Bool { false }
    func startMonitoring() {}
    func stopMonitoring() {}
}
