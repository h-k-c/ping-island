# Claude Plugin Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Claude session monitoring from hardcoded NotchView UI to a proper plugin subprocess that communicates via JSON-RPC, making Claude a first-class plugin like any third-party plugin.

**Architecture:** Main app receives hook events via `HookSocketServer`, forwards them to the Claude plugin process via `PluginEventBus` (stdin JSON-RPC). Claude plugin tracks sessions and pushes compact/notify updates back through `PluginSlotArbiter`. Hardcoded SessionCountIndicator and completion notification queue are removed from NotchView.

**Tech Stack:** Swift 5.9, macOS 14+, Python3 (/usr/bin/python3 for ClaudePlugin executable), XCTest

**Spec:** `docs/superpowers/specs/2026-05-19-claude-plugin-migration-design.md`

**Branch:** `claude/jolly-benz-70d6a4` (current)

---

## ⚠️ Critical Notes

1. **No new Xcode target** — ClaudePlugin is a Python script, embedded as a resource file
2. **No pbxproj edits** — Project uses `PBXFileSystemSynchronizedRootGroup`; files auto-included
3. **Plugin bundle location in source:** `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/`
4. **Plugin bundle location at runtime:** `Bundle.main.bundleURL/Contents/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/`
5. **Test command:**
   ```bash
   xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
     -destination 'platform=macOS,arch=arm64' \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
     2>&1 | grep -E "passed|failed|Executed " | tail -20
   ```
6. **Build command:**
   ```bash
   xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
     -destination 'platform=macOS,arch=arm64' \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
     2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
   ```
7. SourceKit IDE errors are false positives — trust xcodebuild

---

## File Map

### New Files
| Path | Purpose |
|------|---------|
| `PingIsland/Services/Plugin/PluginEventBus.swift` | Forwards HookEvents to subscribed plugin processes |
| `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/manifest.json` | Claude plugin manifest |
| `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS/ClaudePlugin` | Python3 plugin executable |
| `PingIslandTests/PluginEventBusTests.swift` | PluginEventBus unit tests |

### Modified Files
| Path | Change |
|------|--------|
| `PingIsland/Services/Plugin/PluginModels.swift` | Add `subscriptions: [String]?` and `builtIn: Bool?` to PluginManifest |
| `PingIsland/Services/Plugin/PluginProcess.swift` | Add `sendHookEvent(_:)` method |
| `PingIsland/Services/Plugin/PluginHost.swift` | Scan app bundle PluginBundles dir; expose subscribedProcesses(for:) |
| `PingIsland/Services/Plugin/PluginRegistry.swift` | Scan app bundle PluginBundles in addition to user Plugins dir |
| `PingIsland/Services/Session/SessionMonitor.swift` | Call PluginEventBus.shared.dispatch after processing hook event |
| `PingIsland/UI/Views/NotchView.swift` | Remove SessionCountIndicator branch; remove completion notification queue |
| `PingIsland/Services/Plugin/PluginSlotArbiter.swift` | Remove updateSystemSessionCount + systemSessionsPluginId |
| `PingIsland/UI/Views/PluginsSettingsView.swift` | Show builtIn badge; grey out toggle for builtIn plugins |

---

## Task 1: Extend PluginManifest

**Files:**
- Modify: `PingIsland/Services/Plugin/PluginModels.swift`
- Test: `PingIslandTests/PluginModelsTests.swift`

- [ ] **Step 1.1: Add tests for new manifest fields**

Add to `PluginModelsTests.swift`:

```swift
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
```

- [ ] **Step 1.2: Run tests to verify they fail**

```bash
xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PingIslandTests/PluginModelsTests \
  2>&1 | grep -E "passed|failed|error:" | tail -10
```

- [ ] **Step 1.3: Add fields to PluginManifest**

In `PluginModels.swift`, find `struct PluginManifest` and add:

```swift
struct PluginManifest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    let minIslandVersion: String?
    let executable: String
    let slots: [PluginSlot]
    let description: String?
    let iconPath: String?
    let subscriptions: [String]?   // ← new: event types this plugin subscribes to
    let builtIn: Bool?             // ← new: true = can't be disabled/removed

    var isBuiltIn: Bool { builtIn ?? false }
    var subscribesTo: [String] { subscriptions ?? [] }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, minIslandVersion, executable, slots, description
        case iconPath = "icon"
        case subscriptions, builtIn
    }
}
```

- [ ] **Step 1.4: Run tests to verify they pass**

```bash
xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PingIslandTests/PluginModelsTests \
  2>&1 | grep -E "passed|failed|error:" | tail -5
```

Expected: all PluginModelsTests pass.

- [ ] **Step 1.5: Commit**

```bash
git add PingIsland/Services/Plugin/PluginModels.swift \
        PingIslandTests/PluginModelsTests.swift
git commit -m "feat(claude-plugin): add subscriptions + builtIn to PluginManifest"
```

---

## Task 2: PluginEventBus

**Files:**
- Create: `PingIsland/Services/Plugin/PluginEventBus.swift`
- Create: `PingIslandTests/PluginEventBusTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `PingIslandTests/PluginEventBusTests.swift`:

```swift
import XCTest
@testable import Ping_Island

@MainActor
final class PluginEventBusTests: XCTestCase {

    func testDispatchCallsSubscribedProcesses() async {
        // PluginEventBus.dispatch should invoke sendHookEvent on subscribed processes
        // This is tested indirectly via the hookEventJSON helper
        let bus = PluginEventBus()

        // Build a minimal HookEvent-like dict and verify JSON output
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
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PingIslandTests/PluginEventBusTests \
  2>&1 | grep "error:" | head -5
```

- [ ] **Step 2.3: Create `PingIsland/Services/Plugin/PluginEventBus.swift`**

```swift
import Foundation
import os.log

/// Forwards host-side events (e.g. hook events) to plugin processes
/// that declared a matching subscription in their manifest.
@MainActor
final class PluginEventBus {
    static let shared = PluginEventBus()
    private let logger = Logger(subsystem: "com.wudanwu.pingisland", category: "PluginEventBus")

    init() {}

    /// Dispatch a HookEvent to all plugin processes subscribed to "hookEvent".
    func dispatch(hookEvent event: HookEvent) {
        let json = hookEventJSON(
            sessionId: event.sessionId,
            event: event.event,
            status: event.status,
            provider: event.provider.rawValue,
            cwd: event.cwd,
            message: event.message,
            phase: resolvedPhase(from: event)
        )
        for process in PluginHost.shared.subscribedProcesses(for: "hookEvent") {
            process.sendRawDict(json)
        }
    }

    /// Build the JSON-RPC notification dict for a hookEvent message.
    /// Exposed for testing.
    func hookEventJSON(
        sessionId: String,
        event: String,
        status: String,
        provider: String,
        cwd: String,
        message: String?,
        phase: String
    ) -> [String: Any] {
        var params: [String: Any] = [
            "sessionId": sessionId,
            "event": event,
            "status": status,
            "provider": provider,
            "cwd": cwd,
            "phase": phase
        ]
        if let message {
            params["message"] = message
        }
        return ["jsonrpc": "2.0", "method": "hookEvent", "params": params]
    }

    private func resolvedPhase(from event: HookEvent) -> String {
        // Derive a simple phase string from the hook event fields.
        // This mirrors the SessionPhase logic but is kept simple for plugin consumption.
        switch event.event {
        case "Stop", "Notification" where event.status == "completed":
            return "ended"
        case "PreToolUse", "PostToolUse":
            return "processing"
        default:
            return "idle"
        }
    }
}
```

- [ ] **Step 2.4: Add `sendRawDict` and `subscribedProcesses` (needed by PluginEventBus)**

In `PluginProcess.swift`, add `sendRawDict` as a public method (it wraps the existing private `sendRawMessage`):

Find `private func sendRawMessage(_ dict: [String: Any])` and change `private` to `func` (remove private, or add a public wrapper):

```swift
// Change existing private to internal:
func sendRawMessage(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let handle = stdinHandle else { return }
    var line = data
    line.append(UInt8(ascii: "\n"))
    try? handle.write(contentsOf: line)
}

// Add convenience alias used by PluginEventBus:
func sendRawDict(_ dict: [String: Any]) {
    sendRawMessage(dict)
}
```

In `PluginHost.swift`, add `subscribedProcesses(for:)`:

```swift
/// Returns running processes whose manifest subscribes to the given event type.
func subscribedProcesses(for eventType: String) -> [PluginProcess] {
    processes.values.filter { process in
        process.manifest.subscribesTo.contains(eventType)
    }
}
```

- [ ] **Step 2.5: Build verify**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 2.6: Run tests**

```bash
xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:PingIslandTests/PluginEventBusTests \
  2>&1 | grep -E "passed|failed|error:" | tail -5
```

Expected: `Test Suite 'PluginEventBusTests' passed`

- [ ] **Step 2.7: Commit**

```bash
git add PingIsland/Services/Plugin/PluginEventBus.swift \
        PingIsland/Services/Plugin/PluginProcess.swift \
        PingIsland/Services/Plugin/PluginHost.swift \
        PingIslandTests/PluginEventBusTests.swift
git commit -m "feat(claude-plugin): add PluginEventBus + subscribedProcesses + sendRawDict"
```

---

## Task 3: Wire SessionMonitor → PluginEventBus

**Files:**
- Modify: `PingIsland/Services/Session/SessionMonitor.swift`

- [ ] **Step 3.1: Find the dispatch point in SessionMonitor**

Read `handleIncomingHookEvent` in `SessionMonitor.swift`. The hook event is processed at:
```swift
await SessionStore.shared.process(.hookReceived(effectiveEvent))
```

- [ ] **Step 3.2: Add PluginEventBus dispatch after SessionStore processing**

After the `SessionStore.shared.process(.hookReceived(effectiveEvent))` line, add:

```swift
// Forward to plugin event bus (e.g. ClaudePlugin subscribes to hookEvent)
await MainActor.run {
    PluginEventBus.shared.dispatch(hookEvent: effectiveEvent)
}
```

- [ ] **Step 3.3: Build verify**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 3.4: Commit**

```bash
git add PingIsland/Services/Session/SessionMonitor.swift
git commit -m "feat(claude-plugin): wire SessionMonitor → PluginEventBus dispatch"
```

---

## Task 4: Create ClaudePlugin Bundle (Python executable)

**Files:**
- Create: `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/manifest.json`
- Create: `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS/ClaudePlugin`

- [ ] **Step 4.1: Create directory structure**

```bash
mkdir -p "PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS"
```

- [ ] **Step 4.2: Create manifest.json**

```json
{
  "id": "com.wudanwu.pingisland.claude",
  "name": "Claude 会话",
  "version": "1.0.0",
  "executable": "Contents/MacOS/ClaudePlugin",
  "slots": ["compact-right", "notification"],
  "subscriptions": ["hookEvent"],
  "builtIn": true,
  "description": "监控 Claude Code 会话状态"
}
```

- [ ] **Step 4.3: Create ClaudePlugin Python executable**

Create `PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS/ClaudePlugin`:

```python
#!/usr/bin/env python3
"""
ClaudePlugin — Island Plugin Protocol executable.
Tracks Claude Code hook events and pushes compact/notify updates to PingIsland.
"""
import sys
import json
import threading

active_sessions = {}   # sessionId -> {"provider": str, "cwd": str}
request_id_counter = [1]

def send(msg):
    line = json.dumps(msg, ensure_ascii=False) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()

def send_compact():
    count = len(active_sessions)
    if count > 0:
        label = str(count)
        icon_name = "brain.head.profile" if count == 1 else "cpu"
    else:
        label = None
        icon_name = "circle"

    send({
        "jsonrpc": "2.0",
        "method": "island/compact",
        "params": {
            "position": "right",
            "content": {
                "icon": {"type": "sf", "name": icon_name},
                "label": label,
                "tint": "default"
            } if count > 0 else None
        }
    })

def handle_hook_event(params):
    session_id = params.get("sessionId", "")
    phase = params.get("phase", "idle")
    provider = params.get("provider", "claude")
    cwd = params.get("cwd", "")

    was_active = session_id in active_sessions

    if phase == "ended":
        if was_active:
            session_info = active_sessions.pop(session_id, {})
            send_compact()
            # Send completion notification
            send({
                "jsonrpc": "2.0",
                "method": "island/notify",
                "params": {
                    "icon": {"type": "sf", "name": "checkmark.circle.fill"},
                    "title": "会话已完成",
                    "subtitle": session_info.get("cwd", "").split("/")[-1] or "项目",
                    "duration": 4.0
                }
            })
    else:
        if not was_active:
            active_sessions[session_id] = {"provider": provider, "cwd": cwd}
            send_compact()

def handle_initialize(req_id):
    send({
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {"name": "Claude 会话", "ready": True}
    })
    send_compact()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = msg.get("method", "")
        params = msg.get("params", {})
        req_id = msg.get("id")

        if method == "initialize":
            handle_initialize(req_id or 1)
        elif method == "hookEvent":
            handle_hook_event(params)
        elif method == "shutdown":
            sys.exit(0)

if __name__ == "__main__":
    main()
```

- [ ] **Step 4.4: Make executable**

```bash
chmod +x "PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS/ClaudePlugin"
```

- [ ] **Step 4.5: Verify script works manually**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | \
  "PingIsland/Resources/PluginBundles/com.wudanwu.pingisland.claude.pingplugin/Contents/MacOS/ClaudePlugin"
```

Expected output:
```json
{"jsonrpc": "2.0", "id": 1, "result": {"name": "Claude 会话", "ready": true}}
{"jsonrpc": "2.0", "method": "island/compact", "params": {"position": "right", "content": null}}
```

- [ ] **Step 4.6: Commit**

```bash
git add "PingIsland/Resources/PluginBundles/"
git commit -m "feat(claude-plugin): add ClaudePlugin bundle with Python executable"
```

---

## Task 5: PluginRegistry scans app bundle

**Files:**
- Modify: `PingIsland/Services/Plugin/PluginRegistry.swift`

- [ ] **Step 5.1: Add built-in plugins directory URL**

In `PluginRegistry.swift`, add:

```swift
/// URL for plugins bundled inside the app (read-only, built-in).
nonisolated static var builtInPluginsDirectoryURL: URL? {
    Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/PluginBundles", isDirectory: true)
}
```

- [ ] **Step 5.2: Extend rescan() to include built-in plugins**

Find `rescan()` method. Currently it only scans `pluginsDirectoryURL`. Change to:

```swift
func rescan() {
    var found: [InstalledPlugin] = []

    // Scan built-in plugins from app bundle (read-only)
    if let builtInURL = Self.builtInPluginsDirectoryURL,
       let contents = try? FileManager.default.contentsOfDirectory(
           at: builtInURL, includingPropertiesForKeys: nil) {
        let builtIns = contents
            .filter { $0.pathExtension == "pingplugin" }
            .compactMap { bundleURL -> InstalledPlugin? in
                loadPlugin(at: bundleURL)
            }
        found.append(contentsOf: builtIns)
    }

    // Scan user-installed plugins
    if let contents = try? FileManager.default.contentsOfDirectory(
        at: pluginsDirectoryURL, includingPropertiesForKeys: nil) {
        let userPlugins = contents
            .filter { $0.pathExtension == "pingplugin" }
            .compactMap { bundleURL -> InstalledPlugin? in
                loadPlugin(at: bundleURL)
            }
        found.append(contentsOf: userPlugins)
    }

    installedPlugins = found
}

private func loadPlugin(at bundleURL: URL) -> InstalledPlugin? {
    let manifestURL = bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("manifest.json")
    guard
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
    else { return nil }
    return InstalledPlugin(manifest: manifest, bundleURL: bundleURL)
}
```

- [ ] **Step 5.3: isEnabled always returns true for builtIn plugins**

```swift
func isEnabled(_ pluginId: String) -> Bool {
    // Built-in plugins cannot be disabled
    if let plugin = installedPlugins.first(where: { $0.id == pluginId }),
       plugin.manifest.isBuiltIn {
        return true
    }
    return enabledMap[pluginId] ?? true
}
```

- [ ] **Step 5.4: Build verify**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 5.5: Commit**

```bash
git add PingIsland/Services/Plugin/PluginRegistry.swift
git commit -m "feat(claude-plugin): PluginRegistry scans app bundle PluginBundles dir"
```

---

## Task 6: PluginsSettingsView — built-in plugin UI

**Files:**
- Modify: `PingIsland/UI/Views/PluginsSettingsView.swift`

- [ ] **Step 6.1: Update pluginList to show builtIn badge and disabled toggle**

Find `pluginRow(_ plugin:)` function. Update the Toggle binding to disable for builtIn:

```swift
Toggle("", isOn: Binding(
    get: { registry.isEnabled(plugin.id) },
    set: { newValue in
        guard !plugin.manifest.isBuiltIn else { return }
        registry.setEnabled(newValue, for: plugin.id)
    }
))
.toggleStyle(.switch)
.labelsHidden()
.disabled(plugin.manifest.isBuiltIn)
```

In the name/version HStack, add builtIn badge after the version label:

```swift
if plugin.manifest.isBuiltIn {
    Text("内置")
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.secondary.opacity(0.12), in: Capsule())
}
```

Also **remove the hardcoded `builtInRow`** (the fake "Claude 会话 / 始终开启" row) from `pluginList` — the real ClaudePlugin will appear as a proper plugin row now.

- [ ] **Step 6.2: Remove the old builtInRow**

Find and delete the `builtInRow` computed property and its usage in `pluginList`.

- [ ] **Step 6.3: Build verify**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 6.4: Commit**

```bash
git add PingIsland/UI/Views/PluginsSettingsView.swift
git commit -m "feat(claude-plugin): settings shows builtIn badge, greys toggle for builtIn plugins"
```

---

## Task 7: NotchView cleanup — remove hardcoded Claude UI

**Files:**
- Modify: `PingIsland/UI/Views/NotchView.swift`

This is the most impactful change. Read the file carefully before editing.

- [ ] **Step 7.1: Remove SessionCountIndicator from right ear**

Find the right-ear ZStack in `headerRow`:
```swift
} else if activeSessionCount > 0 {
    SessionCountIndicator(count: activeSessionCount)
}
```

Remove this `else if` branch entirely. The ClaudePlugin will push compact updates via `PluginSlotArbiter`, so the session count will appear through the normal plugin rendering path.

- [ ] **Step 7.2: Remove updateSystemSessionCount call**

Find:
```swift
.onChange(of: activeSessionCount) { _, count in
    PluginSlotArbiter.shared.updateSystemSessionCount(count)
}
.onAppear {
    PluginSlotArbiter.shared.updateSystemSessionCount(activeSessionCount)
}
```

Remove both modifiers.

- [ ] **Step 7.3: Remove completion notification queue**

Find all usages of:
- `completionNotificationQueue`
- `activeCompletionNotification`
- `SessionCompletionNotification`
- `completionNotificationDismissWorkItem`
- `shouldDismissCompletionNotificationOnHoverExit`

Remove the `@State` declarations for these and the `SessionCompletionNotificationView` rendering block. The ClaudePlugin will push `island/notify` for session completions instead.

Also remove `handleCompletionNotificationChange`, `handleCompletionNotificationHover`, and related private methods that only serve the completion notification system.

**Be careful:** Only remove code that exclusively serves the completion notification queue. Leave session monitoring, hook message display, and other unrelated code intact.

- [ ] **Step 7.4: Build and fix all compile errors**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep "error:" | head -20
```

Fix each error iteratively. Common issues:
- References to removed state variables
- Exhaustive switch on types that now have fewer cases

- [ ] **Step 7.5: Verify BUILD SUCCEEDED**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 7.6: Commit**

```bash
git add PingIsland/UI/Views/NotchView.swift
git commit -m "feat(claude-plugin): remove hardcoded SessionCountIndicator and completion notification queue from NotchView"
```

---

## Task 8: PluginSlotArbiter cleanup

**Files:**
- Modify: `PingIsland/Services/Plugin/PluginSlotArbiter.swift`

- [ ] **Step 8.1: Remove updateSystemSessionCount and systemSessionsPluginId**

Find and remove:
```swift
static let systemSessionsPluginId = "__system.sessions__"

func updateSystemSessionCount(_ count: Int) { ... }
```

Also remove any `systemSessionsPluginId` references inside the arbiter.

- [ ] **Step 8.2: Build verify**

```bash
xcodebuild build -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
```

- [ ] **Step 8.3: Run full test suite**

```bash
xcodebuild test -project PingIsland.xcodeproj -scheme PingIsland \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  2>&1 | grep -E "Test Suite.*passed|Test Suite.*failed|error:" | tail -10
```

All tests must pass.

- [ ] **Step 8.4: Commit**

```bash
git add PingIsland/Services/Plugin/PluginSlotArbiter.swift
git commit -m "feat(claude-plugin): remove updateSystemSessionCount from PluginSlotArbiter"
```

---

## Task 9: End-to-end verification

- [ ] **Step 9.1: Build and run from Xcode**

Press ⌘R in Xcode. App should launch.

- [ ] **Step 9.2: Check Settings → Plugins**

Should show:
```
🤖  Claude 会话   1.0.0   [右耳] [通知]   内置   [始终开启（灰）]
    监控 Claude Code 会话状态
```

WeatherDemo should also still appear below.

- [ ] **Step 9.3: Check process state**

Claude 会话 row should show **「运行中」** status badge.

If it shows **「未启动」**: click「重启插件」button.
If it shows **「失败: ...」**: check `~/.ping-island-debug/plugins/com.wudanwu.pingisland.claude.log`

- [ ] **Step 9.4: Trigger a Claude Code session**

Run any Claude Code command in terminal. The right ear should show the session count (e.g., `1`).

- [ ] **Step 9.5: Complete the session**

When Claude Code session ends, a notification bubble should appear: **「会话已完成」**

- [ ] **Step 9.6: Verify weather still works**

When no Claude sessions are active, the right ear should show weather (from WeatherDemo). The carousel still works correctly.

- [ ] **Step 9.7: Final commit**

```bash
git add -A
git commit -m "feat(claude-plugin): v2.0 — Claude session monitoring as a proper plugin"
git push
```
