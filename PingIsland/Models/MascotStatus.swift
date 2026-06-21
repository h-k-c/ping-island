import Foundation

/// Mascot animation states
enum MascotStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case working = "working"
    case warning = "warning"
    case dragging = "dragging"
    
    var displayName: String {
        switch self {
        case .idle: return "空闲中"
        case .working: return "运行中"
        case .warning: return "警告状态"
        case .dragging: return "拖拽中"
        }
    }
}

