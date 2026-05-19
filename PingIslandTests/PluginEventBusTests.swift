import XCTest
@testable import Ping_Island

@MainActor
final class PluginEventBusTests: XCTestCase {

    func testHookEventJSONStructure() {
        let bus = PluginEventBus()
        let json = bus.hookEventJSON(
            sessionId: "test-123",
            event: "PostToolUse",
            status: "success",
            provider: "claude",
            cwd: "/tmp",
            message: nil,
            phase: "processing"
        )
        XCTAssertEqual(json["method"] as? String, "hookEvent")
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        let params = json["params"] as? [String: Any]
        XCTAssertEqual(params?["sessionId"] as? String, "test-123")
        XCTAssertEqual(params?["phase"] as? String, "processing")
        XCTAssertEqual(params?["provider"] as? String, "claude")
    }

    func testHookEventJSONOmitsNilMessage() {
        let bus = PluginEventBus()
        let json = bus.hookEventJSON(
            sessionId: "s1", event: "e", status: "ok",
            provider: "claude", cwd: "/", message: nil, phase: "idle"
        )
        let params = json["params"] as? [String: Any]
        XCTAssertNil(params?["message"])
    }

    func testHookEventJSONIncludesMessage() {
        let bus = PluginEventBus()
        let json = bus.hookEventJSON(
            sessionId: "s1", event: "e", status: "ok",
            provider: "claude", cwd: "/", message: "Running tests", phase: "processing"
        )
        let params = json["params"] as? [String: Any]
        XCTAssertEqual(params?["message"] as? String, "Running tests")
    }
}
