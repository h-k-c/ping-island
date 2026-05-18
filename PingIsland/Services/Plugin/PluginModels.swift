import Foundation

// MARK: - Manifest

struct PluginManifest: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let minIslandVersion: String?
    let executable: String
    let slots: [PluginSlot]
    let description: String?
    let icon: String?
}

enum PluginSlot: String, Codable, Equatable {
    case compact
    case notification
    case expanded
}

// MARK: - Icon

enum PluginIcon: Codable, Equatable {
    case sf(name: String)
    case emoji(value: String)

    private enum CodingKeys: String, CodingKey { case type, name, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "sf":    self = .sf(name: try c.decode(String.self, forKey: .name))
        case "emoji": self = .emoji(value: try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown icon type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sf(let name):
            try c.encode("sf", forKey: .type)
            try c.encode(name, forKey: .name)
        case .emoji(let value):
            try c.encode("emoji", forKey: .type)
            try c.encode(value, forKey: .value)
        }
    }
}

// MARK: - Tint

enum PluginTint: String, Codable, Equatable {
    case `default`, green, yellow, red, blue, orange, purple
}

// MARK: - Compact

enum CompactPosition: String, Codable, Equatable {
    case left, right
}

struct PluginCompactContent: Codable, Equatable {
    let icon: PluginIcon
    let label: String?
    let badge: Int?
    let tint: PluginTint?
}

struct PluginCompactUpdate: Equatable, Sendable {
    let pluginId: String
    let position: CompactPosition
    let content: PluginCompactContent?
}

// MARK: - Notification

struct PluginNotifyContent: Codable, Equatable {
    let icon: PluginIcon
    let title: String
    let subtitle: String?
    let duration: Double?
    let actionLabel: String?
    let actionId: String?
}

struct PluginNotifyUpdate: Equatable, Sendable {
    let pluginId: String
    let content: PluginNotifyContent
}

// MARK: - Expanded Sections

struct PluginExpandedUpdate: Equatable, Sendable {
    let pluginId: String
    let sections: [ExpandedSection]
}

enum ExpandedSection: Codable, Equatable {
    case stat(StatSection)
    case text(TextSection)
    case list(ListSection)
    case progress(ProgressSection)
    case chart(ChartSection)
    case button(ButtonSection)
    case divider

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let t = try decoder.container(keyedBy: TypeKey.self)
        switch try t.decode(String.self, forKey: .type) {
        case "stat":     self = .stat(try StatSection(from: decoder))
        case "text":     self = .text(try TextSection(from: decoder))
        case "list":     self = .list(try ListSection(from: decoder))
        case "progress": self = .progress(try ProgressSection(from: decoder))
        case "chart":    self = .chart(try ChartSection(from: decoder))
        case "button":   self = .button(try ButtonSection(from: decoder))
        case "divider":  self = .divider
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: t,
                debugDescription: "Unknown section type")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .stat(let s):     try s.encode(to: encoder)
        case .text(let s):     try s.encode(to: encoder)
        case .list(let s):     try s.encode(to: encoder)
        case .progress(let s): try s.encode(to: encoder)
        case .chart(let s):    try s.encode(to: encoder)
        case .button(let s):   try s.encode(to: encoder)
        case .divider:
            var c = encoder.container(keyedBy: TypeKey.self)
            try c.encode("divider", forKey: .type)
        }
    }
}

struct StatSection: Codable, Equatable {
    let type: String
    let label: String
    let value: String
    let icon: PluginIcon?
    let tint: PluginTint?
}

struct TextSection: Codable, Equatable {
    enum Style: String, Codable, Equatable { case heading, body, caption }
    let type: String
    let content: String
    let style: Style?
}

struct ListSection: Codable, Equatable {
    struct Item: Codable, Equatable {
        let icon: PluginIcon?
        let label: String
        let value: String?
    }
    let type: String
    let items: [Item]
}

struct ProgressSection: Codable, Equatable {
    let type: String
    let label: String?
    let value: Double
    let tint: PluginTint?
}

struct ChartSection: Codable, Equatable {
    enum Style: String, Codable, Equatable { case line, bar }
    let type: String
    let label: String?
    let values: [Double]
    let style: Style?
}

struct ButtonSection: Codable, Equatable {
    enum Style: String, Codable, Equatable { case `default`, destructive }
    let type: String
    let label: String
    let actionId: String
    let style: Style?
}

// MARK: - Process State

enum PluginProcessState: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)
}

// MARK: - Installed Plugin

struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let bundleURL: URL

    var id: String { manifest.id }
}
