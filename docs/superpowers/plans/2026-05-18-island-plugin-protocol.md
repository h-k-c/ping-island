# Island Plugin Protocol (IPP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.pingplugin` bundle-based plugin system that lets third-party macOS apps display content in PingIsland's Dynamic Island via JSON-RPC over stdin/stdout.

**Architecture:** PingIsland hosts and launches plugin executables as child processes. Plugins push structured JSON data; PingIsland renders everything using its own SwiftUI design tokens. A slot arbiter manages conflicts when multiple plugins claim the same display area.

**Tech Stack:** Swift 5.9, macOS 14+, SwiftUI, XCTest, Foundation.Process, AsyncStream, DispatchSource (FSEvents alternative)

**Spec:** `docs/superpowers/specs/2026-05-18-island-plugin-protocol-design.md`

---

## ⚠️ Before Starting

1. **Create the implementation branch:**
   ```bash
   git checkout main
   git pull
   git checkout -b feature/island-plugin-protocol
   ```

2. **All new Swift files must be added to the Xcode project target.** After creating each file, open `PingIsland.xcodeproj` in Xcode and use **File → Add Files to "PingIsland"** (or drag into the Project Navigator) to add it to the `PingIsland` target. Test files go into `PingIslandTests` target only.

3. **Test runner command** (run from repo root):
   ```bash
   xcodebuild test \
     -project PingIsland.xcodeproj \
     -scheme PingIsland \
     -destination 'platform=macOS,arch=arm64' \
     -only-testing:PingIslandTests/<TestClassName> \
     2>&1 | grep -E "Test (Case|Suite|passed|failed|error)|error:|warning:"
   ```

4. **Module import in tests:** `@testable import Ping_Island`

---

## File Map

### New Files

| Path | Target | Purpose |
|------|--------|---------|
| `PingIsland/Services/Plugin/PluginModels.swift` | PingIsland | All data models: manifest, content types, RPC structs |
| `PingIsland/Services/Plugin/PluginRegistry.swift` | PingIsland | Discover + persist installed plugins |
| `PingIsland/Services/Plugin/PluginProcess.swift` | PingIsland | Single plugin subprocess + JSON-RPC I/O |
| `PingIsland/Services/Plugin/PluginHost.swift` | PingIsland | Lifecycle orchestration for all plugin processes |
| `PingIsland/Services/Plugin/PluginSlotArbiter.swift` | PingIsland | Resolve compact/notification/expanded slot conflicts |
| `PingIsland/Services/Plugin/IslandPluginRenderer.swift` | PingIsland | SwiftUI views for plugin content sections |
| `PingIsland/UI/Views/PluginsSettingsView.swift` | PingIsland | Settings tab: list plugins, toggle enable/disable |
| `PingIslandTests/PluginModelsTests.swift` | PingIslandTests | Parse manifest + content JSON |
| `PingIslandTests/PluginRegistryTests.swift` | PingIslandTests | Scan temp dir, persist enabled state |
| `PingIslandTests/PluginProcessTests.swift` | PingIslandTests | Subprocess lifecycle with real shell script |
| `PingIslandTests/PluginSlotArbiterTests.swift` | PingIslandTests | Slot priority + carousel logic |

### Modified Files

| Path | Change |
|------|--------|
| `PingIsland/Core/IslandPresentation.swift` | Add `.plugin` case to `NotchContentType` and `NotchActivityType` |
| `PingIsland/Core/NotchActivityCoordinator.swift` | Handle `.plugin` activity type |
| `PingIsland/Core/NotchViewModel.swift` | Route plugin content type |
| `PingIsland/UI/Views/NotchView.swift` | Render plugin compact + expanded in `headerRow` and `contentView` |
| `PingIsland/UI/Views/SettingsWindowView.swift` | Add `.plugins` to `SettingsCategory` |
| `PingIsland/App/AppDelegate.swift` | Start/stop `PluginHost` in app lifecycle |

---

## Task 1: Plugin Data Models

**Files:**
- Create: `PingIsland/Services/Plugin/PluginModels.swift`
- Create: `PingIslandTests/PluginModelsTests.swift`

- [ ] **Step 1.1: Write the failing tests**

Create `PingIslandTests/PluginModelsTests.swift`:

```swift
import XCTest
@testable import Ping_Island

final class PluginModelsTests: XCTestCase {

    // MARK: - PluginManifest

    func testParsesMinimalManifest() throws {
        let json = """
        {
          "id": "com.test.plugin",
          "name": "Test",
          "version": "1.0.0",
          "executable": "Contents/MacOS/Test",
          "slots": ["compact"]
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.id, "com.test.plugin")
        XCTAssertEqual(manifest.name, "Test")
        XCTAssertEqual(manifest.slots, [.compact])
        XCTAssertNil(manifest.description)
        XCTAssertNil(manifest.icon)
    }

    func testParsesFullManifest() throws {
        let json = """
        {
          "id": "com.test.full",
          "name": "Full Plugin",
          "version": "2.1.0",
          "minIslandVersion": "0.15.0",
          "executable": "Contents/MacOS/Full",
          "slots": ["compact", "notification", "expanded"],
          "description": "A full plugin",
          "icon": "Contents/Resources/icon.png"
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.slots, [.compact, .notification, .expanded])
        XCTAssertEqual(manifest.description, "A full plugin")
        XCTAssertEqual(manifest.minIslandVersion, "0.15.0")
    }

    func testRejectsManifestWithMissingRequiredField() {
        let json = """
        {"name": "No ID", "version": "1.0.0", "executable": "test", "slots": ["compact"]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: json))
    }

    // MARK: - PluginIcon

    func testParsesSFIcon() throws {
        let json = """{"type":"sf","name":"sun.max.fill"}""".data(using: .utf8)!
        let icon = try JSONDecoder().decode(PluginIcon.self, from: json)
        if case .sf(let name) = icon {
            XCTAssertEqual(name, "sun.max.fill")
        } else {
            XCTFail("Expected .sf icon")
        }
    }

    func testParsesEmojiIcon() throws {
        let json = """{"type":"emoji","value":"🌤"}""".data(using: .utf8)!
        let icon = try JSONDecoder().decode(PluginIcon.self, from: json)
        if case .emoji(let value) = icon {
            XCTAssertEqual(value, "🌤")
        } else {
            XCTFail("Expected .emoji icon")
        }
    }

    func testRejectsUnknownIconType() {
        let json = """{"type":"unknown","name":"x"}""".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PluginIcon.self, from: json))
    }

    // MARK: - ExpandedSection

    func testParsesStatSection() throws {
        let json = """
        {"type":"stat","label":"CPU","value":"42%","tint":"blue"}
        """.data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .stat(let s) = section else { return XCTFail("Expected stat") }
        XCTAssertEqual(s.label, "CPU")
        XCTAssertEqual(s.value, "42%")
        XCTAssertEqual(s.tint, .blue)
    }

    func testParsesProgressSection() throws {
        let json = """{"type":"progress","value":0.72,"label":"RAM"}""".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .progress(let s) = section else { return XCTFail("Expected progress") }
        XCTAssertEqual(s.value, 0.72, accuracy: 0.001)
        XCTAssertEqual(s.label, "RAM")
    }

    func testParsesDividerSection() throws {
        let json = """{"type":"divider"}""".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .divider = section else { return XCTFail("Expected divider") }
    }

    func testParsesButtonSection() throws {
        let json = """{"type":"button","label":"Refresh","actionId":"refresh"}""".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .button(let s) = section else { return XCTFail("Expected button") }
        XCTAssertEqual(s.actionId, "refresh")
    }

    func testParsesListSection() throws {
        let json = """
        {"type":"list","items":[{"label":"Upload","value":"12 MB/s"},{"label":"Download","value":"3 MB/s"}]}
        """.data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .list(let s) = section else { return XCTFail("Expected list") }
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items[0].label, "Upload")
    }

    func testParsesChartSection() throws {
        let json = """{"type":"chart","values":[0.1,0.5,0.3],"style":"line"}""".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .chart(let s) = section else { return XCTFail("Expected chart") }
        XCTAssertEqual(s.values.count, 3)
        XCTAssertEqual(s.style, .line)
    }

    func testParsesTextSection() throws {
        let json = """{"type":"text","content":"Hello","style":"caption"}""".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .text(let s) = section else { return XCTFail("Expected text") }
        XCTAssertEqual(s.content, "Hello")
        XCTAssertEqual(s.style, .caption)
    }

    func testRejectsUnknownSectionType() {
        let json = """{"type":"unknown"}""".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ExpandedSection.self, from: json))
    }

    // MARK: - PluginCompactContent

    func testParsesCompactContent() throws {
        let json = """
        {"icon":{"type":"sf","name":"sun.max.fill"},"label":"23°","tint":"yellow"}
        """.data(using: .utf8)!
        let content = try JSONDecoder().decode(PluginCompactContent.self, from: json)
        XCTAssertEqual(content.label, "23°")
        XCTAssertEqual(content.tint, .yellow)
    }

    func testParsesNotifyContent() throws {
        let json = """
        {
          "icon":{"type":"sf","name":"checkmark.circle"},
          "title":"Build OK",
          "duration":4.0,
          "actionLabel":"View",
          "actionId":"open_log"
        }
        """.data(using: .utf8)!
        let content = try JSONDecoder().decode(PluginNotifyContent.self, from: json)
        XCTAssertEqual(content.title, "Build OK")
        XCTAssertEqual(content.duration, 4.0)
        XCTAssertEqual(content.actionId, "open_log")
    }
}
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginModelsTests \
  2>&1 | grep -E "error:|failed"
```

Expected: compile errors — types not defined yet.

- [ ] **Step 1.3: Create `PingIsland/Services/Plugin/PluginModels.swift`**

Create the directory first: `mkdir -p PingIsland/Services/Plugin`

```swift
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
```

- [ ] **Step 1.4: Add `PluginModels.swift` to PingIsland target in Xcode, add `PluginModelsTests.swift` to PingIslandTests target**

- [ ] **Step 1.5: Run tests to verify they pass**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginModelsTests \
  2>&1 | grep -E "Test (passed|failed)|error:"
```

Expected: `Test Suite 'PluginModelsTests' passed`

- [ ] **Step 1.6: Commit**

```bash
git add PingIsland/Services/Plugin/PluginModels.swift \
        PingIslandTests/PluginModelsTests.swift
git commit -m "feat(plugin): add core data models for IPP"
```

---

## Task 2: PluginRegistry

**Files:**
- Create: `PingIsland/Services/Plugin/PluginRegistry.swift`
- Create: `PingIslandTests/PluginRegistryTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `PingIslandTests/PluginRegistryTests.swift`:

```swift
import XCTest
@testable import Ping_Island

@MainActor
final class PluginRegistryTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginRegistryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: name)
        super.tearDown()
    }

    // Helpers

    private func writeFakePlugin(id: String, name pluginName: String, slots: [String] = ["compact"]) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("\(pluginName).pingplugin")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let manifest = """
        {
          "id": "\(id)",
          "name": "\(pluginName)",
          "version": "1.0.0",
          "executable": "Contents/MacOS/\(pluginName)",
          "slots": [\(slots.map { "\"\($0)\"" }.joined(separator: ","))]
        }
        """
        try manifest.data(using: .utf8)!
            .write(to: contentsURL.appendingPathComponent("manifest.json"))
        return bundleURL
    }

    private func makeRegistry() -> PluginRegistry {
        PluginRegistry(pluginsDirectoryURL: tempDir, defaults: defaults)
    }

    // Tests

    func testScansInstalledPlugins() throws {
        try writeFakePlugin(id: "com.test.a", name: "PluginA")
        try writeFakePlugin(id: "com.test.b", name: "PluginB")
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertEqual(registry.installedPlugins.count, 2)
        XCTAssertTrue(registry.installedPlugins.contains { $0.id == "com.test.a" })
        XCTAssertTrue(registry.installedPlugins.contains { $0.id == "com.test.b" })
    }

    func testIgnoresNonPingpluginDirectories() throws {
        try writeFakePlugin(id: "com.test.a", name: "PluginA")
        // A directory without .pingplugin extension
        let notPlugin = tempDir.appendingPathComponent("NotAPlugin")
        try FileManager.default.createDirectory(at: notPlugin, withIntermediateDirectories: true)
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertEqual(registry.installedPlugins.count, 1)
    }

    func testSkipsMalformedManifest() throws {
        let brokenBundle = tempDir.appendingPathComponent("Broken.pingplugin/Contents")
        try FileManager.default.createDirectory(at: brokenBundle, withIntermediateDirectories: true)
        try "not json at all".data(using: .utf8)!
            .write(to: brokenBundle.appendingPathComponent("manifest.json"))
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertTrue(registry.installedPlugins.isEmpty)
    }

    func testSkipsMissingManifest() throws {
        let emptyBundle = tempDir.appendingPathComponent("Empty.pingplugin/Contents")
        try FileManager.default.createDirectory(at: emptyBundle, withIntermediateDirectories: true)
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertTrue(registry.installedPlugins.isEmpty)
    }

    func testDefaultsToEnabledForNewPlugin() {
        let registry = makeRegistry()
        XCTAssertTrue(registry.isEnabled("com.brand.new"))
    }

    func testSetEnabledFalse() {
        let registry = makeRegistry()
        registry.setEnabled(false, for: "com.test.plugin")
        XCTAssertFalse(registry.isEnabled("com.test.plugin"))
    }

    func testEnabledStatePersistsAcrossInstances() {
        let registry = makeRegistry()
        registry.setEnabled(false, for: "com.test.plugin")
        let registry2 = PluginRegistry(pluginsDirectoryURL: tempDir, defaults: defaults)
        XCTAssertFalse(registry2.isEnabled("com.test.plugin"))
    }

    func testReenablingPlugin() {
        let registry = makeRegistry()
        registry.setEnabled(false, for: "com.test.plugin")
        registry.setEnabled(true, for: "com.test.plugin")
        XCTAssertTrue(registry.isEnabled("com.test.plugin"))
    }

    func testEmptyDirectoryReturnsEmptyList() {
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertTrue(registry.installedPlugins.isEmpty)
    }

    func testCreatesPluginDirectoryOnStart() {
        let nonExistent = tempDir.appendingPathComponent("SubDir/Plugins")
        let registry = PluginRegistry(pluginsDirectoryURL: nonExistent, defaults: defaults)
        registry.start()
        registry.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonExistent.path))
    }
}
```

- [ ] **Step 2.2: Run tests to verify they fail (type not found)**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginRegistryTests \
  2>&1 | grep -E "error:|failed"
```

- [ ] **Step 2.3: Create `PingIsland/Services/Plugin/PluginRegistry.swift`**

```swift
import Combine
import Foundation

@MainActor
final class PluginRegistry: ObservableObject {
    static let shared = PluginRegistry()

    @Published private(set) var installedPlugins: [InstalledPlugin] = []

    private let pluginsDirectoryURL: URL
    private let defaults: UserDefaults
    private let enabledKey = "PluginRegistry.enabled.v1"
    private var watchSource: DispatchSourceFileSystemObject?

    static var defaultPluginsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PingIsland/Plugins", isDirectory: true)
    }

    init(
        pluginsDirectoryURL: URL = PluginRegistry.defaultPluginsDirectoryURL,
        defaults: UserDefaults = .standard
    ) {
        self.pluginsDirectoryURL = pluginsDirectoryURL
        self.defaults = defaults
    }

    // MARK: - Lifecycle

    func start() {
        createDirectoryIfNeeded()
        rescan()
        startWatching()
    }

    func stop() {
        watchSource?.cancel()
        watchSource = nil
    }

    // MARK: - Discovery

    func rescan() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: pluginsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            installedPlugins = []
            return
        }

        installedPlugins = contents
            .filter { $0.pathExtension == "pingplugin" }
            .compactMap { bundleURL -> InstalledPlugin? in
                let manifestURL = bundleURL
                    .appendingPathComponent("Contents")
                    .appendingPathComponent("manifest.json")
                guard
                    let data = try? Data(contentsOf: manifestURL),
                    let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
                else { return nil }
                return InstalledPlugin(manifest: manifest, bundleURL: bundleURL)
            }
    }

    // MARK: - Enabled State

    func isEnabled(_ pluginId: String) -> Bool {
        enabledMap[pluginId] ?? true
    }

    func setEnabled(_ enabled: Bool, for pluginId: String) {
        var map = enabledMap
        map[pluginId] = enabled
        defaults.set(map, forKey: enabledKey)
    }

    // MARK: - Private

    private var enabledMap: [String: Bool] {
        (defaults.dictionary(forKey: enabledKey) as? [String: Bool]) ?? [:]
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: pluginsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func startWatching() {
        let path = pluginsDirectoryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .link, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.rescan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }
}
```

- [ ] **Step 2.4: Add both files to their respective Xcode targets**

- [ ] **Step 2.5: Run tests to verify they pass**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginRegistryTests \
  2>&1 | grep -E "Test (passed|failed)|error:"
```

Expected: `Test Suite 'PluginRegistryTests' passed`

- [ ] **Step 2.6: Commit**

```bash
git add PingIsland/Services/Plugin/PluginRegistry.swift \
        PingIslandTests/PluginRegistryTests.swift
git commit -m "feat(plugin): add PluginRegistry with directory scanning and FSWatch"
```

---

## Task 3: PluginProcess

**Files:**
- Create: `PingIsland/Services/Plugin/PluginProcess.swift`
- Create: `PingIslandTests/PluginProcessTests.swift`

- [ ] **Step 3.1: Write the failing tests**

The tests use a real shell script as the plugin executable. The test helper writes it to a temp dir.

Create `PingIslandTests/PluginProcessTests.swift`:

```swift
import XCTest
@testable import Ping_Island

final class PluginProcessTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginProcessTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a .pingplugin bundle whose executable is the provided shell script body.
    private func makePlugin(
        id: String = "com.test.plugin",
        name: String = "TestPlugin",
        slots: [String] = ["compact"],
        scriptBody: String
    ) throws -> (manifest: PluginManifest, bundleURL: URL) {
        let bundleURL = tempDir.appendingPathComponent("\(name).pingplugin")
        let macosDir = bundleURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        // Write executable script
        let scriptURL = macosDir.appendingPathComponent(name)
        let fullScript = "#!/bin/bash\n\(scriptBody)"
        try fullScript.data(using: .utf8)!.write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Write manifest
        let manifestJSON = """
        {
          "id": "\(id)",
          "name": "\(name)",
          "version": "1.0.0",
          "executable": "Contents/MacOS/\(name)",
          "slots": [\(slots.map { "\"\($0)\"" }.joined(separator: ","))]
        }
        """
        try manifestJSON.data(using: .utf8)!
            .write(to: bundleURL.appendingPathComponent("Contents/manifest.json"))

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: manifestJSON.data(using: .utf8)!
        )
        return (manifest, bundleURL)
    }

    // MARK: - Tests

    func testStartsAndReachesReadyState() async throws {
        // Plugin: reads initialize, responds ready, then waits
        let script = """
        while IFS= read -r line; do
          echo '{"jsonrpc":"2.0","id":1,"result":{"name":"TestPlugin","ready":true}}'
          # stay alive for shutdown
          while IFS= read -r line2; do exit 0; done
        done
        """
        let (manifest, bundleURL) = try makePlugin(scriptBody: script)
        let process = PluginProcess(manifest: manifest, bundleURL: bundleURL)

        await process.start()

        let state = await process.state
        XCTAssertEqual(state, .ready)

        await process.stop()
    }

    func testFailsWhenExecutableNotFound() async throws {
        let manifest = PluginManifest(
            id: "com.test.missing",
            name: "Missing",
            version: "1.0.0",
            minIslandVersion: nil,
            executable: "Contents/MacOS/DoesNotExist",
            slots: [.compact],
            description: nil,
            icon: nil
        )
        let bundleURL = tempDir.appendingPathComponent("Missing.pingplugin")
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )

        let process = PluginProcess(manifest: manifest, bundleURL: bundleURL)
        await process.start()

        let state = await process.state
        if case .failed = state { /* expected */ } else {
            XCTFail("Expected failed state, got \(state)")
        }
    }

    func testTimesOutWhenPluginNeverResponds() async throws {
        // Plugin that never writes anything
        let script = "sleep 60"
        let (manifest, bundleURL) = try makePlugin(scriptBody: script)
        let process = PluginProcess(
            manifest: manifest,
            bundleURL: bundleURL,
            initializeTimeoutSeconds: 0.5  // short timeout for test speed
        )

        await process.start()

        let state = await process.state
        if case .failed(let reason) = state {
            XCTAssertTrue(reason.lowercased().contains("timeout"), "Expected timeout in: \(reason)")
        } else {
            XCTFail("Expected .failed state, got \(state)")
        }
    }

    func testReceivesCompactUpdate() async throws {
        let script = """
        while IFS= read -r line; do
          echo '{"jsonrpc":"2.0","id":1,"result":{"name":"WeatherPlugin","ready":true}}'
          echo '{"jsonrpc":"2.0","method":"island/compact","params":{"position":"right","content":{"icon":{"type":"sf","name":"sun.max.fill"},"label":"23°"}}}'
          while IFS= read -r line2; do exit 0; done
        done
        """
        let (manifest, bundleURL) = try makePlugin(id: "com.test.weather", scriptBody: script)
        let process = PluginProcess(manifest: manifest, bundleURL: bundleURL)

        await process.start()
        XCTAssertEqual(await process.state, .ready)

        // Collect one compact update (with timeout)
        let update = await withTimeout(seconds: 3) { [process] () async -> PluginCompactUpdate? in
            for await update in await process.compactUpdates {
                return update
            }
            return nil
        }

        XCTAssertNotNil(update)
        XCTAssertEqual(update?.position, .right)
        XCTAssertEqual(update?.content?.label, "23°")

        await process.stop()
    }

    func testSendsActionToPlugin() async throws {
        // Plugin writes its received action to stdout as a notify message (for testability)
        let script = #"""
        while IFS= read -r line; do
          echo '{"jsonrpc":"2.0","id":1,"result":{"name":"TestPlugin","ready":true}}'
          while IFS= read -r line2; do
            # Echo any action back as a notify
            method=$(echo "$line2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('method',''))" 2>/dev/null)
            if [ "$method" = "action" ]; then
              echo '{"jsonrpc":"2.0","method":"island/notify","params":{"icon":{"type":"sf","name":"checkmark"},"title":"action-received"}}'
            fi
            if [ "$method" = "shutdown" ]; then exit 0; fi
          done
        done
        """#
        let (manifest, bundleURL) = try makePlugin(slots: ["notification"], scriptBody: script)
        let process = PluginProcess(manifest: manifest, bundleURL: bundleURL)

        await process.start()
        XCTAssertEqual(await process.state, .ready)

        await process.sendAction(actionId: "test-action")

        let notify = await withTimeout(seconds: 3) { [process] () async -> PluginNotifyUpdate? in
            for await update in await process.notifyUpdates {
                return update
            }
            return nil
        }

        XCTAssertEqual(notify?.content.title, "action-received")
        await process.stop()
    }
}

// MARK: - Test helper

func withTimeout<T: Sendable>(seconds: Double, operation: @Sendable @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
```

- [ ] **Step 3.2: Run to verify compile failure**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginProcessTests \
  2>&1 | grep "error:"
```

- [ ] **Step 3.3: Create `PingIsland/Services/Plugin/PluginProcess.swift`**

```swift
import Foundation
import os.log

actor PluginProcess {
    // MARK: - Public

    let manifest: PluginManifest
    nonisolated let compactUpdates: AsyncStream<PluginCompactUpdate>
    nonisolated let notifyUpdates: AsyncStream<PluginNotifyUpdate>
    nonisolated let expandedUpdates: AsyncStream<PluginExpandedUpdate>

    private(set) var state: PluginProcessState = .stopped

    // MARK: - Private

    private let bundleURL: URL
    private let islandVersion: String
    private let initializeTimeoutSeconds: Double
    private let logger: Logger

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var retryCount = 0
    private static let maxRetries = 3
    private static let retryDelaysNanos: [UInt64] = [1_000_000_000, 2_000_000_000, 4_000_000_000]

    private var readyContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    private let compactCont: AsyncStream<PluginCompactUpdate>.Continuation
    private let notifyCont: AsyncStream<PluginNotifyUpdate>.Continuation
    private let expandedCont: AsyncStream<PluginExpandedUpdate>.Continuation

    // MARK: - Init

    init(
        manifest: PluginManifest,
        bundleURL: URL,
        islandVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        initializeTimeoutSeconds: Double = 5.0
    ) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.islandVersion = islandVersion
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.logger = Logger(subsystem: "com.wudanwu.pingisland", category: "Plugin")

        var cc: AsyncStream<PluginCompactUpdate>.Continuation!
        var nc: AsyncStream<PluginNotifyUpdate>.Continuation!
        var ec: AsyncStream<PluginExpandedUpdate>.Continuation!

        let compact = AsyncStream<PluginCompactUpdate> { cc = $0 }
        let notify = AsyncStream<PluginNotifyUpdate> { nc = $0 }
        let expanded = AsyncStream<PluginExpandedUpdate> { ec = $0 }

        compactUpdates = compact
        notifyUpdates = notify
        expandedUpdates = expanded
        compactCont = cc
        notifyCont = nc
        expandedCont = ec
    }

    // MARK: - Public API

    func start() async {
        guard state == .stopped else { return }
        await launchWithRetry()
    }

    func stop() {
        timeoutTask?.cancel()
        readTask?.cancel()
        readyContinuation?.resume(returning: false)
        readyContinuation = nil
        sendRawMessage(["jsonrpc": "2.0", "method": "shutdown"])
        let proc = process
        Task.detached {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if proc?.isRunning == true { proc?.terminate() }
        }
        process = nil
        stdinHandle = nil
        state = .stopped
    }

    func sendAction(actionId: String) {
        sendRawMessage(["jsonrpc": "2.0", "method": "action", "params": ["actionId": actionId]])
    }

    // MARK: - Launch

    private func launchWithRetry() async {
        let success = await launch()
        guard !success, retryCount < Self.maxRetries else { return }
        let delay = Self.retryDelaysNanos[min(retryCount, Self.retryDelaysNanos.count - 1)]
        retryCount += 1
        try? await Task.sleep(nanoseconds: delay)
        await launchWithRetry()
    }

    private func launch() async -> Bool {
        state = .starting

        let execURL = bundleURL.appendingPathComponent(manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            state = .failed("Executable not found: \(execURL.lastPathComponent)")
            return false
        }

        let proc = Process()
        proc.executableURL = execURL
        proc.currentDirectoryURL = bundleURL.appendingPathComponent("Contents")
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "PING_ISLAND_VERSION": islandVersion,
            "PING_ISLAND_PLUGIN_ID": manifest.id
        ]) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do { try proc.run() } catch {
            state = .failed("Process launch error: \(error.localizedDescription)")
            return false
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        startStdoutReader(stdoutPipe.fileHandleForReading)
        forwardStderr(stderrPipe.fileHandleForReading)

        // Send initialize
        sendRawMessage([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["islandVersion": islandVersion, "pluginId": manifest.id, "config": [:] as [String: Any]]
        ])

        // Await ready with timeout
        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            readyContinuation = cont
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(initializeTimeoutSeconds * 1_000_000_000))
                if let c = self.readyContinuation {
                    self.readyContinuation = nil
                    c.resume(returning: false)
                }
            }
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        if ready {
            state = .ready
            retryCount = 0
        } else {
            proc.terminate()
            state = .failed("Initialize timeout after \(initializeTimeoutSeconds)s")
        }
        return ready
    }

    // MARK: - I/O

    private func startStdoutReader(_ handle: FileHandle) {
        readTask = Task {
            var buffer = Data()
            do {
                for try await byte in handle.bytes {
                    if byte == UInt8(ascii: "\n") {
                        if !buffer.isEmpty {
                            await processLine(Data(buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch { }
        }
    }

    private func forwardStderr(_ handle: FileHandle) {
        let pluginId = manifest.id
        Task.detached(priority: .background) {
            let logDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ping-island-debug/plugins")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logURL = logDir.appendingPathComponent("\(pluginId).log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                try? Data().write(to: logURL)
            }
            guard let writer = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? writer.close() }
            try? writer.seekToEnd()
            do {
                for try await byte in handle.bytes {
                    try? writer.write(contentsOf: Data([byte]))
                }
            } catch { }
        }
    }

    private func processLine(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Response to initialize (has "id" + "result")
        if json["id"] != nil, let result = json["result"] as? [String: Any] {
            let ready = result["ready"] as? Bool ?? false
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: ready)
            }
            return
        }

        guard let method = json["method"] as? String else { return }
        guard let params = json["params"],
              let paramsData = try? JSONSerialization.data(withJSONObject: params) else { return }

        let decoder = JSONDecoder()

        switch method {
        case "island/compact":
            struct Params: Decodable {
                let position: CompactPosition
                let content: PluginCompactContent?
            }
            if let p = try? decoder.decode(Params.self, from: paramsData) {
                compactCont.yield(PluginCompactUpdate(
                    pluginId: manifest.id,
                    position: p.position,
                    content: p.content
                ))
            }

        case "island/notify":
            if let content = try? decoder.decode(PluginNotifyContent.self, from: paramsData) {
                notifyCont.yield(PluginNotifyUpdate(pluginId: manifest.id, content: content))
            }

        case "island/expanded":
            struct Params: Decodable { let sections: [ExpandedSection] }
            if let p = try? decoder.decode(Params.self, from: paramsData) {
                expandedCont.yield(PluginExpandedUpdate(pluginId: manifest.id, sections: p.sections))
            }

        default:
            logger.debug("Unknown method from plugin \(self.manifest.id, privacy: .public): \(method, privacy: .public)")
        }
    }

    private func sendRawMessage(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let handle = stdinHandle else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        try? handle.write(contentsOf: line)
    }
}
```

- [ ] **Step 3.4: Add both files to Xcode targets**

- [ ] **Step 3.5: Run tests to verify they pass**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginProcessTests \
  2>&1 | grep -E "Test (passed|failed)|error:"
```

Expected: `Test Suite 'PluginProcessTests' passed`

Note: `testTimesOutWhenPluginNeverResponds` will take ~0.5 seconds by design.

- [ ] **Step 3.6: Commit**

```bash
git add PingIsland/Services/Plugin/PluginProcess.swift \
        PingIslandTests/PluginProcessTests.swift
git commit -m "feat(plugin): add PluginProcess with JSON-RPC over stdin/stdout"
```

---

## Task 4: PluginSlotArbiter

**Files:**
- Create: `PingIsland/Services/Plugin/PluginSlotArbiter.swift`
- Create: `PingIslandTests/PluginSlotArbiterTests.swift`

- [ ] **Step 4.1: Write the failing tests**

Create `PingIslandTests/PluginSlotArbiterTests.swift`:

```swift
import XCTest
@testable import Ping_Island

@MainActor
final class PluginSlotArbiterTests: XCTestCase {

    private func makeArbiter() -> PluginSlotArbiter {
        PluginSlotArbiter()
    }

    private func makeCompact(
        pluginId: String,
        position: CompactPosition,
        label: String? = nil
    ) -> PluginCompactUpdate {
        PluginCompactUpdate(
            pluginId: pluginId,
            position: position,
            content: PluginCompactContent(
                icon: .sf(name: "circle"),
                label: label,
                badge: nil,
                tint: nil
            )
        )
    }

    // MARK: - Compact slot

    func testSinglePluginAppearsOnRight() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        XCTAssertEqual(arbiter.activeRight?.label, "A")
        XCTAssertNil(arbiter.activeLeft)
    }

    func testSinglePluginAppearsOnLeft() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .left, label: "L"))
        XCTAssertEqual(arbiter.activeLeft?.label, "L")
        XCTAssertNil(arbiter.activeRight)
    }

    func testClearingContentRemovesFromSlot() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.handleCompact(PluginCompactUpdate(pluginId: "com.a", position: .right, content: nil))
        XCTAssertNil(arbiter.activeRight)
    }

    func testCoreActivitySuppressesRightPlugin() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.setCoreActive(true, side: .right)
        XCTAssertNil(arbiter.activeRight)
    }

    func testCoreActivityReleasedRestoresPlugin() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.setCoreActive(true, side: .right)
        arbiter.setCoreActive(false, side: .right)
        XCTAssertEqual(arbiter.activeRight?.label, "A")
    }

    func testMultiplePluginsSameSideCarousel() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.handleCompact(makeCompact(pluginId: "com.b", position: .right, label: "B"))

        // First plugin shows first
        let first = arbiter.activeRight?.label
        XCTAssertNotNil(first)

        // After advancing carousel, second shows
        arbiter.advanceCarousel(side: .right)
        let second = arbiter.activeRight?.label
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testLabelIsTruncatedToFourCharacters() {
        let arbiter = makeArbiter()
        arbiter.handleCompact(PluginCompactUpdate(
            pluginId: "com.a",
            position: .right,
            content: PluginCompactContent(icon: .sf(name: "circle"), label: "12345678", badge: nil, tint: nil)
        ))
        XCTAssertEqual(arbiter.activeRight?.label?.count, 4)
    }

    // MARK: - Notification

    func testEnqueuesNotification() {
        let arbiter = makeArbiter()
        let update = PluginNotifyUpdate(
            pluginId: "com.a",
            content: PluginNotifyContent(
                icon: .sf(name: "bell"), title: "Hello",
                subtitle: nil, duration: 4, actionLabel: nil, actionId: nil
            )
        )
        arbiter.handleNotify(update)
        XCTAssertEqual(arbiter.pendingNotifications.count, 1)
        XCTAssertEqual(arbiter.pendingNotifications.first?.content.title, "Hello")
    }

    func testDurationIsClampedToMaximum() {
        let arbiter = makeArbiter()
        let update = PluginNotifyUpdate(
            pluginId: "com.a",
            content: PluginNotifyContent(
                icon: .sf(name: "bell"), title: "Hi",
                subtitle: nil, duration: 99, actionLabel: nil, actionId: nil
            )
        )
        arbiter.handleNotify(update)
        XCTAssertEqual(arbiter.pendingNotifications.first?.content.duration, 10.0)
    }

    // MARK: - Expanded

    func testExpandedContentStoredByPluginId() {
        let arbiter = makeArbiter()
        arbiter.handleExpanded(PluginExpandedUpdate(
            pluginId: "com.a",
            sections: [.divider]
        ))
        XCTAssertEqual(arbiter.expandedContent["com.a"]?.count, 1)
    }

    func testEmptyExpandedSectionsClearsEntry() {
        let arbiter = makeArbiter()
        arbiter.handleExpanded(PluginExpandedUpdate(pluginId: "com.a", sections: [.divider]))
        arbiter.handleExpanded(PluginExpandedUpdate(pluginId: "com.a", sections: []))
        XCTAssertNil(arbiter.expandedContent["com.a"])
    }
}
```

- [ ] **Step 4.2: Run to verify compile failure**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginSlotArbiterTests \
  2>&1 | grep "error:"
```

- [ ] **Step 4.3: Create `PingIsland/Services/Plugin/PluginSlotArbiter.swift`**

```swift
import Combine
import Foundation

@MainActor
final class PluginSlotArbiter: ObservableObject {
    static let shared = PluginSlotArbiter()

    // MARK: - Published state consumed by NotchView

    @Published private(set) var activeLeft: PluginCompactContent?
    @Published private(set) var activeLeftPluginId: String?
    @Published private(set) var activeRight: PluginCompactContent?
    @Published private(set) var activeRightPluginId: String?
    @Published private(set) var pendingNotifications: [PluginNotifyUpdate] = []
    @Published private(set) var expandedContent: [String: [ExpandedSection]] = [:]

    // MARK: - Private state

    private var leftSlots: [(pluginId: String, content: PluginCompactContent)] = []
    private var rightSlots: [(pluginId: String, content: PluginCompactContent)] = []
    private var leftCarouselIndex = 0
    private var rightCarouselIndex = 0
    private var coreLeftActive = false
    private var coreRightActive = false

    // MARK: - Public API

    func handleCompact(_ update: PluginCompactUpdate) {
        switch update.position {
        case .left:
            leftSlots.removeAll { $0.pluginId == update.pluginId }
            if let content = update.content {
                let sanitized = sanitize(content)
                leftSlots.append((update.pluginId, sanitized))
            }
            leftCarouselIndex = 0
        case .right:
            rightSlots.removeAll { $0.pluginId == update.pluginId }
            if let content = update.content {
                let sanitized = sanitize(content)
                rightSlots.append((update.pluginId, sanitized))
            }
            rightCarouselIndex = 0
        }
        recompute()
    }

    func handleNotify(_ update: PluginNotifyUpdate) {
        var sanitized = update
        if let d = update.content.duration {
            let clamped = min(max(d, 0.5), 10.0)
            sanitized = PluginNotifyUpdate(
                pluginId: update.pluginId,
                content: PluginNotifyContent(
                    icon: update.content.icon,
                    title: update.content.title,
                    subtitle: update.content.subtitle,
                    duration: clamped,
                    actionLabel: update.content.actionLabel,
                    actionId: update.content.actionId
                )
            )
        }
        pendingNotifications.append(sanitized)
    }

    func dequeueNotification() -> PluginNotifyUpdate? {
        guard !pendingNotifications.isEmpty else { return nil }
        return pendingNotifications.removeFirst()
    }

    func handleExpanded(_ update: PluginExpandedUpdate) {
        if update.sections.isEmpty {
            expandedContent.removeValue(forKey: update.pluginId)
        } else {
            expandedContent[update.pluginId] = update.sections
        }
    }

    func setCoreActive(_ active: Bool, side: CompactPosition) {
        switch side {
        case .left:  coreLeftActive = active
        case .right: coreRightActive = active
        }
        recompute()
    }

    func removePlugin(_ pluginId: String) {
        leftSlots.removeAll { $0.pluginId == pluginId }
        rightSlots.removeAll { $0.pluginId == pluginId }
        expandedContent.removeValue(forKey: pluginId)
        pendingNotifications.removeAll { $0.pluginId == pluginId }
        recompute()
    }

    /// Exposed for testing without waiting 10 seconds
    func advanceCarousel(side: CompactPosition) {
        switch side {
        case .left:
            guard leftSlots.count > 1 else { return }
            leftCarouselIndex = (leftCarouselIndex + 1) % leftSlots.count
        case .right:
            guard rightSlots.count > 1 else { return }
            rightCarouselIndex = (rightCarouselIndex + 1) % rightSlots.count
        }
        recompute()
    }

    // MARK: - Private

    private func recompute() {
        if coreLeftActive || leftSlots.isEmpty {
            activeLeft = nil
            activeLeftPluginId = nil
        } else {
            let idx = leftCarouselIndex % leftSlots.count
            activeLeft = leftSlots[idx].content
            activeLeftPluginId = leftSlots[idx].pluginId
        }

        if coreRightActive || rightSlots.isEmpty {
            activeRight = nil
            activeRightPluginId = nil
        } else {
            let idx = rightCarouselIndex % rightSlots.count
            activeRight = rightSlots[idx].content
            activeRightPluginId = rightSlots[idx].pluginId
        }
    }

    private func sanitize(_ content: PluginCompactContent) -> PluginCompactContent {
        let label = content.label.map { String($0.prefix(4)) }
        let badge = content.badge.map { max(0, $0) }
        return PluginCompactContent(icon: content.icon, label: label, badge: badge, tint: content.tint)
    }
}
```

- [ ] **Step 4.4: Add both files to Xcode targets**

- [ ] **Step 4.5: Run tests**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PingIslandTests/PluginSlotArbiterTests \
  2>&1 | grep -E "Test (passed|failed)|error:"
```

Expected: `Test Suite 'PluginSlotArbiterTests' passed`

- [ ] **Step 4.6: Commit**

```bash
git add PingIsland/Services/Plugin/PluginSlotArbiter.swift \
        PingIslandTests/PluginSlotArbiterTests.swift
git commit -m "feat(plugin): add PluginSlotArbiter with carousel and core priority"
```

---

## Task 5: PluginHost

**Files:**
- Create: `PingIsland/Services/Plugin/PluginHost.swift`

No isolated unit tests for PluginHost (it orchestrates processes, covered by integration). Add to Xcode target only.

- [ ] **Step 5.1: Create `PingIsland/Services/Plugin/PluginHost.swift`**

```swift
import Combine
import Foundation
import os.log

@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    @Published private(set) var processStates: [String: PluginProcessState] = [:]

    private let registry: PluginRegistry
    private let arbiter: PluginSlotArbiter
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PluginHost")

    private var processes: [String: PluginProcess] = [:]
    private var listenerTasks: [String: Task<Void, Never>] = [:]
    private var registryCancellable: AnyCancellable?
    private var hasStarted = false

    init(registry: PluginRegistry = .shared, arbiter: PluginSlotArbiter = .shared) {
        self.registry = registry
        self.arbiter = arbiter
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        registry.start()

        for plugin in registry.installedPlugins where registry.isEnabled(plugin.id) {
            await startPlugin(plugin)
        }

        // Observe registry changes (new plugins installed or enabled/disabled)
        registryCancellable = registry.$installedPlugins
            .dropFirst()
            .sink { [weak self] plugins in
                Task { [weak self] in
                    await self?.reconcilePlugins(plugins)
                }
            }
    }

    func stop() async {
        guard hasStarted else { return }
        hasStarted = false
        registryCancellable = nil

        for task in listenerTasks.values { task.cancel() }
        listenerTasks.removeAll()

        for process in processes.values { await process.stop() }
        processes.removeAll()
        processStates.removeAll()

        registry.stop()
    }

    // MARK: - Plugin management

    private func startPlugin(_ plugin: InstalledPlugin) async {
        guard processes[plugin.id] == nil else { return }

        let process = PluginProcess(manifest: plugin.manifest, bundleURL: plugin.bundleURL)
        processes[plugin.id] = process

        logger.info("Starting plugin \(plugin.id, privacy: .public)")
        await process.start()

        let state = await process.state
        processStates[plugin.id] = state
        logger.info("Plugin \(plugin.id, privacy: .public) state: \(String(describing: state), privacy: .public)")

        listenerTasks[plugin.id] = Task { [weak self] in
            await self?.listenToPlugin(process)
        }
    }

    private func stopPlugin(_ pluginId: String) async {
        listenerTasks[pluginId]?.cancel()
        listenerTasks.removeValue(forKey: pluginId)

        if let process = processes[pluginId] {
            await process.stop()
            processes.removeValue(forKey: pluginId)
        }

        processStates.removeValue(forKey: pluginId)
        arbiter.removePlugin(pluginId)
    }

    private func reconcilePlugins(_ plugins: [InstalledPlugin]) async {
        let installedIds = Set(plugins.map(\.id))
        let runningIds = Set(processes.keys)

        // Stop removed plugins
        for id in runningIds.subtracting(installedIds) {
            await stopPlugin(id)
        }

        // Start newly installed enabled plugins
        for plugin in plugins
            where !runningIds.contains(plugin.id) && registry.isEnabled(plugin.id) {
            await startPlugin(plugin)
        }
    }

    private func listenToPlugin(_ process: PluginProcess) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await update in process.compactUpdates {
                    await MainActor.run { PluginSlotArbiter.shared.handleCompact(update) }
                }
            }
            group.addTask {
                for await update in process.notifyUpdates {
                    await MainActor.run { PluginSlotArbiter.shared.handleNotify(update) }
                }
            }
            group.addTask {
                for await update in process.expandedUpdates {
                    await MainActor.run { PluginSlotArbiter.shared.handleExpanded(update) }
                }
            }
        }
    }
}
```

- [ ] **Step 5.2: Add `PluginHost.swift` to PingIsland target in Xcode**

- [ ] **Step 5.3: Verify project compiles cleanly**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5.4: Commit**

```bash
git add PingIsland/Services/Plugin/PluginHost.swift
git commit -m "feat(plugin): add PluginHost lifecycle orchestrator"
```

---

## Task 6: IslandPluginRenderer

**Files:**
- Create: `PingIsland/Services/Plugin/IslandPluginRenderer.swift`

This file is pure SwiftUI. No unit tests — verify by building and visual review.

- [ ] **Step 6.1: Create `PingIsland/Services/Plugin/IslandPluginRenderer.swift`**

```swift
import SwiftUI

/// Renders plugin content using island-native design tokens.
/// All colors, fonts, and spacing mirror the existing NotchView system.
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

    // MARK: - Individual section views

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
        // Buttons dispatch via NotificationCenter so the view doesn't need a direct
        // reference to the PluginHost. The host observes PluginButtonAction notifications.
        Button(s.label) {
            NotificationCenter.default.post(
                name: .pluginButtonTapped,
                object: nil,
                userInfo: ["actionId": s.actionId]
            )
        }
        .buttonStyle(IslandPluginButtonStyle(destructive: s.style == .destructive))
    }

    // MARK: - Chart helpers

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

    // MARK: - Icon

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

    // MARK: - Helpers

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

// MARK: - Button style

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

// MARK: - Notification name

extension Notification.Name {
    static let pluginButtonTapped = Notification.Name("PluginButtonTapped")
}
```

- [ ] **Step 6.2: Add `IslandPluginRenderer.swift` to PingIsland target in Xcode**

- [ ] **Step 6.3: Verify build succeeds**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 6.4: Commit**

```bash
git add PingIsland/Services/Plugin/IslandPluginRenderer.swift
git commit -m "feat(plugin): add IslandPluginRenderer with island-native SwiftUI components"
```

---

## Task 7: Core Model Changes

**Files:**
- Modify: `PingIsland/Core/IslandPresentation.swift`
- Modify: `PingIsland/Core/NotchActivityCoordinator.swift`
- Modify: `PingIsland/Core/NotchViewModel.swift`

- [ ] **Step 7.1: Add `.plugin` to `NotchContentType` in `IslandPresentation.swift`**

Find the `NotchContentType` enum (around line 1 of `IslandPresentation.swift`) and add the new case:

```swift
// Before:
enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

// After:
enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)
    case plugin(pluginId: String)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .chat(let session): return "chat-\(session.sessionId)"
        case .plugin(let id): return "plugin-\(id)"
        }
    }
}
```

- [ ] **Step 7.2: Add `.plugin` to `NotchActivityType` in `NotchActivityCoordinator.swift`**

```swift
// Before:
enum NotchActivityType: Equatable {
    case claude
    case none
}

// After:
enum NotchActivityType: Equatable {
    case claude
    case plugin(pluginId: String)
    case none
}
```

- [ ] **Step 7.3: Update `NotchActivityCoordinator.showActivity` to accept plugin type**

In `NotchActivityCoordinator.swift`, the `showActivity` method already takes `type: NotchActivityType`. No signature change needed — callers can now pass `.plugin(pluginId:)`.

- [ ] **Step 7.4: Verify build**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

If the compiler reports exhaustive switch errors for `NotchActivityType` or `NotchContentType`, add the new cases to any existing switch statements. For `NotchActivityType.plugin`, add `case .plugin: break` (plugins use the arbiter, not the coordinator) or treat it the same as `.none` in coordinator logic.

- [ ] **Step 7.5: Fix any exhaustive switch errors**

Search for all switches on `NotchActivityType`:

```bash
grep -rn "switch.*activityType\|case .claude\|case .none" PingIsland/ --include="*.swift"
```

For each switch on `NotchActivityType`, add:
```swift
case .plugin:
    break  // plugin activities are handled by PluginSlotArbiter, not here
```

Search for all switches on `NotchContentType`:
```bash
grep -rn "case .instances\|case .chat" PingIsland/ --include="*.swift"
```

For each switch on `NotchContentType`, add:
```swift
case .plugin:
    break  // plugin content is rendered separately
```

- [ ] **Step 7.6: Run all existing tests to verify no regressions**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "Test Suite '(All|PingIslandTests)' (passed|failed)"
```

- [ ] **Step 7.7: Commit**

```bash
git add PingIsland/Core/IslandPresentation.swift \
        PingIsland/Core/NotchActivityCoordinator.swift \
        PingIsland/Core/NotchViewModel.swift
git commit -m "feat(plugin): extend NotchContentType and NotchActivityType for plugins"
```

---

## Task 8: NotchView Integration

**Files:**
- Modify: `PingIsland/UI/Views/NotchView.swift`

This task wires `PluginSlotArbiter` into the existing `NotchView` rendering. The island's compact "ears" gain plugin content; the expanded view gains a plugin panel.

- [ ] **Step 8.1: Add `PluginSlotArbiter` observation to `NotchView`**

In `NotchView.swift`, add to the existing `@ObservedObject` declarations at the top of `struct NotchView`:

```swift
@ObservedObject private var pluginArbiter = PluginSlotArbiter.shared
```

- [ ] **Step 8.2: Add plugin compact content to the right ear**

In `NotchView.headerRow`, find the right-side `ZStack` (around line 670–690). This ZStack currently shows `BellIndicatorIcon`, usage indicator, or session count. Add plugin content as a lower-priority fallback when none of those are present:

```swift
// In the right-side ZStack, add after the existing else-if chain:
} else if let pluginContent = pluginArbiter.activeRight {
    IslandPluginRenderer.compactView(content: pluginContent)
}
```

The full ZStack should look like:
```swift
ZStack {
    if hasManualAttentionIndicator {
        BellIndicatorIcon(size: 12, color: closedIndicatorTone.emphasisColor)
    } else if let usageWindow = closedTrailingUsageWindow {
        ClosedNotchUsageRemainingIndicator(
            providerTitle: closedTrailingUsageProviderTitle,
            window: usageWindow
        )
    } else if activeSessionCount > 0 {
        SessionCountIndicator(count: activeSessionCount)
    } else if let pluginContent = pluginArbiter.activeRight {
        IslandPluginRenderer.compactView(content: pluginContent)
    }
}
.frame(width: closedTrailingWidth, alignment: .trailing)
```

- [ ] **Step 8.3: Add plugin compact content to the left ear**

In `NotchView.headerRow`, find the left-side `MascotView` block. Plugin left content appears when the mascot has nothing to show (no active session). After the existing mascot rendering, add:

```swift
// After the MascotView block, when there's no mascot activity and there's plugin content:
if viewModel.status != .opened && !showsClosedLeadingIcon,
   let pluginContent = pluginArbiter.activeLeft {
    IslandPluginRenderer.compactView(content: pluginContent)
        .frame(width: sideWidth)
}
```

- [ ] **Step 8.4: Add plugin expanded panel to `IslandExpandedRoute.swift`**

Open `PingIsland/UI/Views/IslandExpandedRoute.swift` and add a plugin route. Find where `NotchContentType` is switched (likely a `switch contentType` or similar). Add:

```swift
case .plugin(let pluginId):
    PluginExpandedPanelView(pluginId: pluginId)
```

- [ ] **Step 8.5: Create `PluginExpandedPanelView` inline in `IslandExpandedRoute.swift`**

Add this view to the bottom of `IslandExpandedRoute.swift`:

```swift
private struct PluginExpandedPanelView: View {
    let pluginId: String
    @ObservedObject private var arbiter = PluginSlotArbiter.shared

    var body: some View {
        if let sections = arbiter.expandedContent[pluginId] {
            ScrollView {
                IslandPluginRenderer.expandedView(sections: sections)
            }
        } else {
            Text("Loading…")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .padding()
        }
    }
}
```

- [ ] **Step 8.6: Wire `PluginSlotArbiter.coreRightActive` to existing activity states**

In `NotchView`, find where `isAnyProcessing` drives the right indicator. Add a `.onChange` to sync core activity state to the arbiter. Add this modifier to an appropriate view (e.g., the root `notchLayout`):

```swift
.onChange(of: isAnyProcessing) { _, active in
    PluginSlotArbiter.shared.setCoreActive(active, side: .right)
}
```

- [ ] **Step 8.7: Build and verify no new compile errors**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 8.8: Commit**

```bash
git add PingIsland/UI/Views/NotchView.swift \
        PingIsland/UI/Views/IslandExpandedRoute.swift
git commit -m "feat(plugin): wire PluginSlotArbiter into NotchView compact and expanded slots"
```

---

## Task 9: PluginsSettingsView + SettingsCategory

**Files:**
- Create: `PingIsland/UI/Views/PluginsSettingsView.swift`
- Modify: `PingIsland/UI/Views/SettingsWindowView.swift`

- [ ] **Step 9.1: Create `PingIsland/UI/Views/PluginsSettingsView.swift`**

```swift
import SwiftUI

struct PluginsSettingsView: View {
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var host = PluginHost.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if registry.installedPlugins.isEmpty {
                emptyState
            } else {
                pluginList
            }

            Divider()
                .padding(.vertical, 8)

            HStack {
                Button("打开插件文件夹") {
                    NSWorkspace.shared.open(PluginRegistry.defaultPluginsDirectoryURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Subviews

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("没有已安装的插件")
                .font(.headline)
            Text("将 .pingplugin 文件放入插件文件夹即可安装。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var pluginList: some View {
        VStack(spacing: 0) {
            // Built-in Claude entry (always shown, not toggleable)
            builtInRow

            Divider()

            ForEach(registry.installedPlugins) { plugin in
                pluginRow(plugin)
                Divider()
                    .padding(.leading, 52)
            }
        }
    }

    private var builtInRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Claude 会话")
                        .font(.system(size: 13, weight: .medium))
                    Text("内置")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
                Text("任务进度、通知与对话管理")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("始终开启")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func pluginRow(_ plugin: InstalledPlugin) -> some View {
        HStack(spacing: 12) {
            pluginIcon(plugin)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(plugin.manifest.version)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if case .failed(let reason) = host.processStates[plugin.id] {
                        Text("崩溃")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.red, in: Capsule())
                            .help(reason)
                    }
                }

                if let desc = plugin.manifest.description {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { registry.isEnabled(plugin.id) },
                set: { registry.setEnabled($0, for: plugin.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func pluginIcon(_ plugin: InstalledPlugin) -> some View {
        if let iconPath = plugin.manifest.icon,
           let image = NSImage(contentsOfFile: plugin.bundleURL.appendingPathComponent(iconPath).path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 9.2: Add `.plugins` case to `SettingsCategory`**

In `SettingsWindowView.swift`, add to the `SettingsCategory` enum before `.integration`:

```swift
case plugins
```

Add corresponding cases to `title`, `subtitle`, and `icon` switches:

```swift
// In title:
case .plugins: return "插件"

// In subtitle:
case .plugins: return "已安装的岛插件"

// In icon:
case .plugins: return "puzzlepiece.extension.fill"
```

- [ ] **Step 9.3: Wire `PluginsSettingsView` into the settings content switch**

In `SettingsWindowView.swift`, find the `switch` on `SettingsCategory` that renders content views. Add:

```swift
case .plugins:
    PluginsSettingsView()
```

- [ ] **Step 9.4: Add both files to Xcode targets**

`PluginsSettingsView.swift` → PingIsland target only.

- [ ] **Step 9.5: Build and verify**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 9.6: Commit**

```bash
git add PingIsland/UI/Views/PluginsSettingsView.swift \
        PingIsland/UI/Views/SettingsWindowView.swift
git commit -m "feat(plugin): add Plugins settings tab with enable/disable toggles"
```

---

## Task 10: AppDelegate Integration

**Files:**
- Modify: `PingIsland/App/AppDelegate.swift`

- [ ] **Step 10.1: Start `PluginHost` in `applicationDidFinishLaunching`**

In `AppDelegate.swift`, find the block that starts services like `UpdateManager`, `UserIdleAutoProtection`, and `TelemetryService`. Add `PluginHost` alongside them:

```swift
// After the existing Task { await TelemetryService.shared.start() }:
Task {
    await PluginHost.shared.start()
}
```

- [ ] **Step 10.2: Stop `PluginHost` in `applicationWillTerminate`**

Check if `AppDelegate` has an `applicationWillTerminate` method. If yes, add to it; if not, create it:

```swift
func applicationWillTerminate(_ notification: Notification) {
    Task {
        await PluginHost.shared.stop()
    }
}
```

- [ ] **Step 10.3: Observe `pluginButtonTapped` notification in `AppDelegate`**

The button action in `IslandPluginRenderer` posts a `Notification.Name.pluginButtonTapped` notification. Wire this to `PluginHost` so the correct plugin receives the `action` RPC. Add to `applicationDidFinishLaunching`:

```swift
NotificationCenter.default.addObserver(
    forName: .pluginButtonTapped,
    object: nil,
    queue: .main
) { notification in
    guard let actionId = notification.userInfo?["actionId"] as? String else { return }
    // Find which plugin's expanded content is currently showing and send the action
    // Use the activeExpandedPluginId from NotchViewModel or PluginSlotArbiter
    // For v1: broadcast to all running plugins (they ignore unknown actionIds)
    Task { @MainActor in
        for process in PluginHost.shared.runningProcesses {
            await process.sendAction(actionId: actionId)
        }
    }
}
```

This requires `PluginHost` to expose `runningProcesses`. Add to `PluginHost.swift`:

```swift
var runningProcesses: [PluginProcess] {
    Array(processes.values)
}
```

- [ ] **Step 10.4: Build and verify**

```bash
xcodebuild build \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```

- [ ] **Step 10.5: Run full test suite to check for regressions**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "Test Suite '(All|PingIslandTests)' (passed|failed)"
```

- [ ] **Step 10.6: Commit**

```bash
git add PingIsland/App/AppDelegate.swift \
        PingIsland/Services/Plugin/PluginHost.swift
git commit -m "feat(plugin): integrate PluginHost into app lifecycle"
```

---

## Task 11: Example Plugin + End-to-End Verification

**Files:**
- Create: `Prototype/WeatherDemo.pingplugin/Contents/manifest.json`
- Create: `Prototype/WeatherDemo.pingplugin/Contents/MacOS/WeatherDemo`

This creates a minimal shell-script plugin for manual end-to-end testing.

- [ ] **Step 11.1: Create directory structure**

```bash
mkdir -p Prototype/WeatherDemo.pingplugin/Contents/MacOS
```

- [ ] **Step 11.2: Create `Prototype/WeatherDemo.pingplugin/Contents/manifest.json`**

```json
{
  "id": "com.example.weatherdemo",
  "name": "天气Demo",
  "version": "0.1.0",
  "executable": "Contents/MacOS/WeatherDemo",
  "slots": ["compact", "notification", "expanded"],
  "description": "演示用天气插件，每 30 秒更新一次温度"
}
```

- [ ] **Step 11.3: Create `Prototype/WeatherDemo.pingplugin/Contents/MacOS/WeatherDemo`**

```bash
#!/bin/bash
# Island Plugin Protocol demo — weather simulation

send() {
  printf '%s\n' "$1"
}

handle_init() {
  local id="$1"
  send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"name\":\"天气Demo\",\"ready\":true}}"

  # Send initial compact slot
  send '{"jsonrpc":"2.0","method":"island/compact","params":{"position":"right","content":{"icon":{"type":"sf","name":"sun.max.fill"},"label":"23°","tint":"yellow"}}}'

  # Send expanded content
  send '{"jsonrpc":"2.0","method":"island/expanded","params":{"sections":[{"type":"stat","label":"气温","value":"23°C","icon":{"type":"sf","name":"thermometer.medium"}},{"type":"divider"},{"type":"progress","label":"湿度","value":0.65,"tint":"blue"},{"type":"stat","label":"风速","value":"12 km/h","icon":{"type":"sf","name":"wind"}},{"type":"button","label":"刷新","actionId":"refresh"}]}}'
}

TEMPS=(21 22 23 24 23 22 21)
IDX=0

update_weather() {
  local temp="${TEMPS[$IDX]}"
  IDX=$(( (IDX + 1) % ${#TEMPS[@]} ))
  send "{\"jsonrpc\":\"2.0\",\"method\":\"island/compact\",\"params\":{\"position\":\"right\",\"content\":{\"icon\":{\"type\":\"sf\",\"name\":\"sun.max.fill\"},\"label\":\"${temp}°\",\"tint\":\"yellow\"}}}"
}

# Main loop
while IFS= read -r line; do
  method=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('method',''))" 2>/dev/null)
  id=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id','1'))" 2>/dev/null)

  case "$method" in
    initialize)
      handle_init "$id"
      # Start background update loop
      (while true; do sleep 30; update_weather; done) &
      BG_PID=$!
      ;;
    action)
      action_id=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('params',{}).get('actionId',''))" 2>/dev/null)
      if [ "$action_id" = "refresh" ]; then
        update_weather
        send '{"jsonrpc":"2.0","method":"island/notify","params":{"icon":{"type":"sf","name":"arrow.clockwise"},"title":"天气已更新","duration":2.0}}'
      fi
      ;;
    shutdown)
      kill "$BG_PID" 2>/dev/null
      exit 0
      ;;
  esac
done
```

- [ ] **Step 11.4: Make the script executable**

```bash
chmod +x Prototype/WeatherDemo.pingplugin/Contents/MacOS/WeatherDemo
```

- [ ] **Step 11.5: Copy to plugins directory for testing**

```bash
PLUGINS_DIR="$HOME/Library/Application Support/PingIsland/Plugins"
mkdir -p "$PLUGINS_DIR"
cp -r Prototype/WeatherDemo.pingplugin "$PLUGINS_DIR/"
```

- [ ] **Step 11.6: Manual verification checklist**

Launch PingIsland from Xcode (or build and run). Verify:

1. **Compact slot:** Island closed state shows `23°` with sun icon on the right ear
2. **No core conflict:** When Claude is processing (right indicator active), plugin content disappears; when Claude is idle, `23°` returns
3. **Expanded panel:** Click island → open → plugin expanded view shows temperature stat, humidity progress bar, and "刷新" button
4. **Button action:** Tap "刷新" → notification bubble appears saying "天气已更新"
5. **Settings:** Open PingIsland settings → Plugins tab → WeatherDemo appears with toggle
6. **Disable:** Toggle WeatherDemo off → compact content disappears. Re-enable → content returns (requires app restart for process lifecycle to reconcile)
7. **Crash recovery:** Kill the WeatherDemo process externally → PingIsland retries up to 3 times (check Console.app for `com.wudanwu.pingisland` category `Plugin` log messages)

- [ ] **Step 11.7: Run full test suite one final time**

```bash
xcodebuild test \
  -project PingIsland.xcodeproj \
  -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -E "Test Suite '(All|PingIslandTests)' (passed|failed)"
```

Expected: all pass.

- [ ] **Step 11.8: Commit**

```bash
git add Prototype/WeatherDemo.pingplugin/
git commit -m "feat(plugin): add WeatherDemo example plugin for IPP end-to-end verification"
```

---

## Final: Create PR

```bash
git push -u origin feature/island-plugin-protocol
gh pr create \
  --title "feat: Island Plugin Protocol (IPP) — third-party Dynamic Island plugins" \
  --body "$(cat <<'EOF'
## Summary

- Adds `.pingplugin` bundle format — any macOS executable can become a Dynamic Island plugin
- JSON-RPC over stdin/stdout (`island/compact`, `island/notify`, `island/expanded`)
- PingIsland hosts all plugins as child processes, manages lifecycle and crash recovery
- Island-native component library (stat, progress, chart, list, text, button) preserves visual consistency
- Slot arbitration: core Claude activity takes priority; multiple plugins carousel every 10s
- Settings → Plugins tab for per-plugin enable/disable
- Includes `WeatherDemo.pingplugin` shell-script example for end-to-end verification

## Test plan

- [ ] `PluginModelsTests` — all JSON parsing tests pass
- [ ] `PluginRegistryTests` — scanning, persistence, hot-reload tests pass
- [ ] `PluginProcessTests` — subprocess lifecycle, timeout, compact/notify updates pass
- [ ] `PluginSlotArbiterTests` — slot priority, carousel, sanitization tests pass
- [ ] Full test suite passes with no regressions
- [ ] WeatherDemo manual checklist (Task 11.6) verified
EOF
)"
```
