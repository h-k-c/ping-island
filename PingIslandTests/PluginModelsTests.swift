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
        XCTAssertNil(manifest.iconPath)
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
        let json = "{\"type\":\"sf\",\"name\":\"sun.max.fill\"}".data(using: .utf8)!
        let icon = try JSONDecoder().decode(PluginIcon.self, from: json)
        if case .sf(let name) = icon {
            XCTAssertEqual(name, "sun.max.fill")
        } else {
            XCTFail("Expected .sf icon")
        }
    }

    func testParsesEmojiIcon() throws {
        let json = "{\"type\":\"emoji\",\"value\":\"🌤\"}".data(using: .utf8)!
        let icon = try JSONDecoder().decode(PluginIcon.self, from: json)
        if case .emoji(let value) = icon {
            XCTAssertEqual(value, "🌤")
        } else {
            XCTFail("Expected .emoji icon")
        }
    }

    func testRejectsUnknownIconType() {
        let json = "{\"type\":\"unknown\",\"name\":\"x\"}".data(using: .utf8)!
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
        let json = "{\"type\":\"progress\",\"value\":0.72,\"label\":\"RAM\"}".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .progress(let s) = section else { return XCTFail("Expected progress") }
        XCTAssertEqual(s.value, 0.72, accuracy: 0.001)
        XCTAssertEqual(s.label, "RAM")
    }

    func testParsesDividerSection() throws {
        let json = "{\"type\":\"divider\"}".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .divider = section else { return XCTFail("Expected divider") }
    }

    func testParsesButtonSection() throws {
        let json = "{\"type\":\"button\",\"label\":\"Refresh\",\"actionId\":\"refresh\"}".data(using: .utf8)!
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
        let json = "{\"type\":\"chart\",\"values\":[0.1,0.5,0.3],\"style\":\"line\"}".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .chart(let s) = section else { return XCTFail("Expected chart") }
        XCTAssertEqual(s.values.count, 3)
        XCTAssertEqual(s.style, .line)
    }

    func testParsesTextSection() throws {
        let json = "{\"type\":\"text\",\"content\":\"Hello\",\"style\":\"caption\"}".data(using: .utf8)!
        let section = try JSONDecoder().decode(ExpandedSection.self, from: json)
        guard case .text(let s) = section else { return XCTFail("Expected text") }
        XCTAssertEqual(s.content, "Hello")
        XCTAssertEqual(s.style, .caption)
    }

    func testRejectsUnknownSectionType() {
        let json = "{\"type\":\"unknown\"}".data(using: .utf8)!
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

    // MARK: - subscriptions + builtIn

    func testParsesSubscriptionsField() throws {
        let json = """
        {
          "id": "com.test.hook",
          "name": "Hook",
          "version": "1.0.0",
          "executable": "Contents/MacOS/Hook",
          "slots": ["compact-right"],
          "subscriptions": ["hookEvent"]
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.subscriptions, ["hookEvent"])
        XCTAssertNil(manifest.builtIn)
    }

    func testParsesBuiltInField() throws {
        let json = """
        {
          "id": "com.test.builtin",
          "name": "BuiltIn",
          "version": "1.0.0",
          "executable": "Contents/MacOS/BuiltIn",
          "slots": ["compact-right"],
          "builtIn": true
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertEqual(manifest.builtIn, true)
    }

    func testMissingSubscriptionsDefaultsToNil() throws {
        let json = """
        {"id":"com.test.x","name":"X","version":"1.0.0","executable":"x","slots":["compact-right"]}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: json)
        XCTAssertNil(manifest.subscriptions)
    }

    // MARK: - ExpandedSection roundtrip

    func testExpandedSectionRoundtrip() throws {
        let original: ExpandedSection = .stat(StatSection(
            label: "CPU",
            value: "42%",
            icon: .sf(name: "cpu"),
            tint: .blue
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExpandedSection.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
