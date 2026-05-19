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

    func testSinglePluginAppearsOnRight() {
        let arbiter = makeArbiter()
        arbiter.rightEarAssignment = "com.a"
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        XCTAssertEqual(arbiter.activeRight?.label, "A")
        XCTAssertNil(arbiter.activeLeft)
    }

    func testSinglePluginAppearsOnLeft() {
        let arbiter = makeArbiter()
        arbiter.leftEarAssignment = "com.a"
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .left, label: "L"))
        XCTAssertEqual(arbiter.activeLeft?.label, "L")
        XCTAssertNil(arbiter.activeRight)
    }

    func testClearingContentRemovesFromSlot() {
        let arbiter = makeArbiter()
        arbiter.rightEarAssignment = "com.a"
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.handleCompact(PluginCompactUpdate(pluginId: "com.a", position: .right, content: nil))
        XCTAssertNil(arbiter.activeRight)
    }

    func testCoreActivitySuppressesRightPlugin() {
        let arbiter = makeArbiter()
        arbiter.rightEarAssignment = "com.a"
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.setCoreActive(true, side: .right)
        XCTAssertNil(arbiter.activeRight)
    }

    func testCoreActivityReleasedRestoresPlugin() {
        let arbiter = makeArbiter()
        arbiter.rightEarAssignment = "com.a"
        arbiter.handleCompact(makeCompact(pluginId: "com.a", position: .right, label: "A"))
        arbiter.setCoreActive(true, side: .right)
        arbiter.setCoreActive(false, side: .right)
        XCTAssertEqual(arbiter.activeRight?.label, "A")
    }


    func testLabelIsTruncatedToFourCharacters() {
        let arbiter = makeArbiter()
        arbiter.rightEarAssignment = "com.a"
        arbiter.handleCompact(PluginCompactUpdate(
            pluginId: "com.a",
            position: .right,
            content: PluginCompactContent(icon: .sf(name: "circle"), label: "12345678", badge: nil, tint: nil)
        ))
        XCTAssertEqual(arbiter.activeRight?.label?.count, 4)
    }

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
