import Foundation

// MARK: - Manifest

struct PluginManifest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let minIslandVersion: String?
    let executable: String
    let slots: [PluginSlot]
    let description: String?
    let iconPath: String?
    let subscriptions: [String]?
    let builtIn: Bool?
    let config: [PluginConfigItem]?   // declarative settings items

    var isBuiltIn: Bool { builtIn ?? false }
    var subscribesTo: [String] { subscriptions ?? [] }
    var configItems: [PluginConfigItem] { config ?? [] }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, minIslandVersion, executable, slots, description
        case iconPath = "icon"
        case subscriptions, builtIn, config
    }
}

// MARK: - Declarative config item

struct PluginConfigItem: Codable, Equatable, Sendable {
    enum ItemType: String, Codable, Sendable {
        case secret      // password/key input, stored in Keychain
        case text        // plain text input, stored in UserDefaults
        case toggle      // bool toggle, stored in UserDefaults
        case info        // read-only info row (e.g. file path status)
    }

    let key: String         // storage key (namespaced by plugin ID internally)
    let label: String       // display label
    let type: ItemType
    let hint: String?       // placeholder or help text
    let infoPath: String?   // for type=info: file path to check existence
}

enum PluginSlot: String, Codable, Equatable, Sendable {
    case compactLeft  = "compact-left"
    case compactRight = "compact-right"
    case compact                          // backward compat — treated as compactRight
    case notification
    case expanded
}

extension PluginSlot {
    /// Human-readable display name for Settings UI badges
    var displayName: String {
        switch self {
        case .compactLeft:              return "左耳"
        case .compactRight, .compact:   return "右耳"
        case .notification:             return "通知"
        case .expanded:                 return "展开"
        }
    }
}

// MARK: - Icon

enum PluginIcon: Codable, Equatable, Sendable {
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

enum PluginTint: String, Codable, Equatable, Sendable {
    case `default`, green, yellow, red, blue, orange, purple
}

// MARK: - Compact

enum CompactPosition: String, Codable, Equatable, Sendable {
    case left, right
}

struct PluginCompactContent: Codable, Equatable, Sendable {
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

struct PluginNotifyContent: Codable, Equatable, Sendable {
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

enum ExpandedSection: Codable, Equatable, Sendable {
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

struct StatSection: Equatable, Sendable {
    let label: String
    let value: String
    let icon: PluginIcon?
    let tint: PluginTint?
}

extension StatSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, label, value, icon, tint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        value = try c.decode(String.self, forKey: .value)
        icon  = try c.decodeIfPresent(PluginIcon.self, forKey: .icon)
        tint  = try c.decodeIfPresent(PluginTint.self, forKey: .tint)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("stat", forKey: .type)
        try c.encode(label, forKey: .label)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(tint, forKey: .tint)
    }
}

struct TextSection: Equatable, Sendable {
    enum Style: String, Codable, Equatable, Sendable { case heading, body, caption }
    let content: String
    let style: Style?
}

extension TextSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, content, style }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode(String.self, forKey: .content)
        style   = try c.decodeIfPresent(Style.self, forKey: .style)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("text", forKey: .type)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(style, forKey: .style)
    }
}

struct ListSection: Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let icon: PluginIcon?
        let label: String
        let value: String?
    }
    let items: [Item]
}

extension ListSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Item].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("list", forKey: .type)
        try c.encode(items, forKey: .items)
    }
}

struct ProgressSection: Equatable, Sendable {
    let label: String?
    /// Value in the range 0.0–1.0. Values outside this range are clamped by the renderer.
    let value: Double
    let tint: PluginTint?
}

extension ProgressSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, label, value, tint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        value = try c.decode(Double.self, forKey: .value)
        tint  = try c.decodeIfPresent(PluginTint.self, forKey: .tint)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("progress", forKey: .type)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(tint, forKey: .tint)
    }
}

struct ChartSection: Equatable, Sendable {
    enum Style: String, Codable, Equatable, Sendable { case line, bar }
    let label: String?
    let values: [Double]
    let style: Style?
}

extension ChartSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, label, values, style }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label  = try c.decodeIfPresent(String.self, forKey: .label)
        values = try c.decode([Double].self, forKey: .values)
        style  = try c.decodeIfPresent(Style.self, forKey: .style)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("chart", forKey: .type)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(values, forKey: .values)
        try c.encodeIfPresent(style, forKey: .style)
    }
}

struct ButtonSection: Equatable, Sendable {
    enum Style: String, Codable, Equatable, Sendable { case `default`, destructive }
    let label: String
    let actionId: String
    let style: Style?
}

extension ButtonSection: Codable {
    private enum CodingKeys: String, CodingKey { case type, label, actionId, style }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label    = try c.decode(String.self, forKey: .label)
        actionId = try c.decode(String.self, forKey: .actionId)
        style    = try c.decodeIfPresent(Style.self, forKey: .style)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("button", forKey: .type)
        try c.encode(label, forKey: .label)
        try c.encode(actionId, forKey: .actionId)
        try c.encodeIfPresent(style, forKey: .style)
    }
}

// MARK: - Process State

enum PluginProcessState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

// MARK: - Installed Plugin

struct InstalledPlugin: Identifiable, Equatable, Sendable {
    let manifest: PluginManifest
    let bundleURL: URL

    var id: String { manifest.id }
}
