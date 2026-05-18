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

    private func makePlugin(
        id: String = "com.test.plugin",
        name: String = "TestPlugin",
        slots: [String] = ["compact"],
        scriptBody: String
    ) throws -> (manifest: PluginManifest, bundleURL: URL) {
        let bundleURL = tempDir.appendingPathComponent("\(name).pingplugin")
        let macosDir = bundleURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        let scriptURL = macosDir.appendingPathComponent(name)
        let fullScript = "#!/bin/bash\n\(scriptBody)"
        try fullScript.data(using: .utf8)!.write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

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

        let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestJSON.data(using: .utf8)!)
        return (manifest, bundleURL)
    }

    func testStartsAndReachesReadyState() async throws {
        let script = """
        while IFS= read -r line; do
          echo '{"jsonrpc":"2.0","id":1,"result":{"name":"TestPlugin","ready":true}}'
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
            iconPath: nil
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
        let script = "sleep 60"
        let (manifest, bundleURL) = try makePlugin(scriptBody: script)
        let process = PluginProcess(
            manifest: manifest,
            bundleURL: bundleURL,
            initializeTimeoutSeconds: 0.5
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
          echo '{"jsonrpc":"2.0","method":"island/compact","params":{"position":"right","content":{"icon":{"type":"sf","name":"sun.max.fill"},"label":"23"}}}'
          while IFS= read -r line2; do exit 0; done
        done
        """
        let (manifest, bundleURL) = try makePlugin(id: "com.test.weather", scriptBody: script)
        let process = PluginProcess(manifest: manifest, bundleURL: bundleURL)

        await process.start()
        let stateBeforeStream = await process.state
        XCTAssertEqual(stateBeforeStream, .ready)

        let stream = process.compactUpdates
        let update = await withTimeout(seconds: 3) { () async -> PluginCompactUpdate? in
            for await u in stream { return u }
            return nil
        }

        XCTAssertNotNil(update)
        XCTAssertEqual(update?.position, .right)
        XCTAssertEqual(update?.content?.label, "23")
        await process.stop()
    }
}

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
