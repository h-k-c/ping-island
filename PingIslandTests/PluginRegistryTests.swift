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

    @discardableResult
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
        PluginRegistry(pluginsDirectoryURL: tempDir, defaults: defaults, includeBuiltInPlugins: false)
    }

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
        let notPlugin = tempDir.appendingPathComponent("NotAPlugin")
        try FileManager.default.createDirectory(at: notPlugin, withIntermediateDirectories: true)
        let registry = makeRegistry()
        registry.rescan()
        XCTAssertEqual(registry.installedPlugins.count, 1)
    }

    func testSkipsMalformedManifest() throws {
        let brokenBundle = tempDir.appendingPathComponent("Broken.pingplugin/Contents")
        try FileManager.default.createDirectory(at: brokenBundle, withIntermediateDirectories: true)
        try "not json".data(using: .utf8)!
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
        let registry2 = PluginRegistry(pluginsDirectoryURL: tempDir, defaults: defaults, includeBuiltInPlugins: false)
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
        let registry = PluginRegistry(pluginsDirectoryURL: nonExistent, defaults: defaults, includeBuiltInPlugins: false)
        registry.start()
        registry.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonExistent.path))
    }
}
