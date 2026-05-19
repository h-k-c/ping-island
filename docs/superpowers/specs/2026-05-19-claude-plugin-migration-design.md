# Claude 会话插件化设计规格 (IPP v2.0)

**日期：** 2026-05-19
**状态：** 待实现
**前置：** IPP v1 + v1.1

---

## 一、目标

将 PingIsland 从"带插件支持的 Claude 监控工具"改造为"纯 Dynamic Island 平台"。Claude 会话监控成为第一个真正的内置插件，和第三方插件平等竞争 slot。

**MVP 范围（本 spec）：**
- compact slot：会话数量
- notification：会话完成通知
- 不含：宠物动画、对话 UI、approval 交互

---

## 二、架构变化

### 现在
```
Claude Code CLI
    ↓ Unix socket hook
HookSocketServer (主 app)
    ↓ HookEvent
SessionMonitor → SessionStore → NotchViewModel → NotchView
                                                  ↑ 硬编码 Claude UI
```

### 改造后
```
Claude Code CLI
    ↓ Unix socket hook
HookSocketServer (主 app)
    ↓ PluginEventBus 转发
PluginProcess (ClaudePlugin 子进程)
    ↓ island/compact + island/notify
PluginSlotArbiter → NotchView (通用渲染)
```

主 app 变成纯平台：收集事件、分发给插件、统一渲染。

---

## 三、协议扩展：事件订阅

### 3.1 manifest.json 新增 subscriptions 字段

```json
{
  "id": "com.wudanwu.pingisland.claude",
  "name": "Claude 会话",
  "version": "1.0.0",
  "executable": "Contents/MacOS/ClaudePlugin",
  "slots": ["compact-right", "notification"],
  "subscriptions": ["hookEvent"],
  "builtIn": true
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `subscriptions` | `[string]` | 插件订阅的事件类型，目前只有 `"hookEvent"` |
| `builtIn` | bool | 内置插件，不可禁用，不可删除 |

### 3.2 新增 Host → Plugin 消息：hookEvent

```json
{
  "jsonrpc": "2.0",
  "method": "hookEvent",
  "params": {
    "sessionId": "abc123",
    "event": "PostToolUse",
    "status": "success",
    "provider": "claude",
    "cwd": "/Users/foo/project",
    "message": "运行测试...",
    "phase": "processing"
  }
}
```

`phase` 值：`"idle"` | `"processing"` | `"waitingForInput"` | `"compacting"` | `"ended"`

这是 `HookEvent` 结构体的精简 JSON 表示，只传 ClaudePlugin 需要的字段。

---

## 四、新增组件

### 4.1 PluginEventBus（`PingIsland/Services/Plugin/PluginEventBus.swift`）

主 app 事件转发中心。

```swift
@MainActor
final class PluginEventBus {
    static let shared = PluginEventBus()

    /// 将 HookEvent 转发给所有订阅了 "hookEvent" 的插件进程
    func dispatch(hookEvent: HookEvent)
}
```

`HookSocketServer` 在 `SessionMonitor.handleHookEvent` 之后调用 `PluginEventBus.shared.dispatch(hookEvent:)`。

`PluginEventBus` 遍历 `PluginHost.shared.runningProcesses`，找到 manifest 里 `subscriptions.contains("hookEvent")` 的进程，发送 `hookEvent` JSON-RPC notification。

### 4.2 ClaudePlugin 可执行文件（新 Xcode target）

Swift CLI target，打包在 app bundle 内：
```
PingIsland.app/Contents/PluginBundles/
└── com.wudanwu.pingisland.claude.pingplugin/
    └── Contents/
        ├── manifest.json
        └── MacOS/
            └── ClaudePlugin  ← Swift CLI 可执行文件
```

ClaudePlugin 逻辑：
1. 读 stdin，响应 `initialize`
2. 收到 `hookEvent` → 更新内部 session 状态
3. session count 变化 → 发送 `island/compact`
4. session 完成 → 发送 `island/notify`

**ClaudePlugin 内部状态（极简）：**
```swift
var activeSessions: Set<String> = []   // 活跃 sessionId
var sessionProviders: [String: String] // sessionId → provider name
```

收到 hookEvent：
- `phase == "ended"` → 从 activeSessions 移除 → 如果之前在 activeSessions → 发 notify
- 其他 → 加入 activeSessions（如不存在）→ 更新 compact count

---

## 五、PluginRegistry 扩展

### 5.1 内置插件目录扫描

`PluginRegistry` 除扫描 `~/Library/Application Support/PingIsland/Plugins/` 外，还扫描：
```
Bundle.main.bundleURL/Contents/PluginBundles/
```

内置插件标记为 `builtIn: true`（来自 manifest），在 Settings 中：
- 开关灰置（不可禁用）
- 名称旁显示「内置」badge
- 不显示删除选项

### 5.2 PluginManifest 新增字段

```swift
struct PluginManifest: Codable {
    // ... 现有字段
    let subscriptions: [String]?   // 订阅的事件类型
    let builtIn: Bool?             // 内置插件
}
```

---

## 六、NotchView 清理

移除以下硬编码 Claude UI：

| 移除项 | 位置 | 替代方案 |
|--------|------|---------|
| `SessionCountIndicator` | headerRow 右耳 | ClaudePlugin 通过 arbiter 推送 |
| `updateSystemSessionCount` 调用 | NotchView onChange | 删除 |
| `completionNotificationQueue` + `activeCompletionNotification` | NotchView state | ClaudePlugin 推 `island/notify` |
| `SessionCompletionNotificationView` 渲染 | NotchView | 改用 `IslandPluginRenderer.notificationView` |
| `closedCenterMessage` / `closedCenterContent` hook 文字 | headerRow 中间 | **保留**（中间被物理刘海遮住，不影响） |
| `MascotView` 左耳 | headerRow | **保留**（后续再迁，当前 scope 外） |

> **注意：** `SessionStore`、`SessionMonitor` 等后端逻辑**不移除**，它们继续为主 app 其他功能（remote forwarding、approval、runtime）服务。只移除 UI 层的硬编码渲染。

---

## 七、PluginSlotArbiter 清理

移除：
- `updateSystemSessionCount(_:)` 方法
- `systemSessionsPluginId` 常量
- NotchView 里调用这两个的代码

ClaudePlugin 会直接通过 `handleCompact` 推送 session count，走正常插件流程。

---

## 八、Settings 展示

Claude 插件行：
```
🤖  Claude 会话   1.0.0   [右耳] [通知]   内置   [始终开启（灰）]
    监控 Claude Code 会话状态
```

`builtIn == true` 的插件：
- Toggle 灰置 `disabled`
- 旁边显示「内置」小 badge
- 进程状态正常显示（运行中 / 失败）

---

## 九、文件改动清单

### 新增
| 文件 | 说明 |
|------|------|
| `PingIsland/Services/Plugin/PluginEventBus.swift` | 事件转发中心 |
| `ClaudePlugin/main.swift` | Swift CLI plugin 可执行文件 |
| `ClaudePlugin/ClaudePlugin.xcodeproj target` | 新 Xcode target |
| `PingIsland.app/Contents/PluginBundles/...` | 内置插件 bundle 目录 |

### 修改
| 文件 | 改动 |
|------|------|
| `PluginModels.swift` | 加 `subscriptions`、`builtIn` 字段 |
| `PluginRegistry.swift` | 扫描 app bundle 内置插件目录 |
| `PluginProcess.swift` | `sendHookEvent(_:)` 方法（转发用） |
| `PluginHost.swift` | 加载内置插件；暴露 subscribed processes |
| `PluginSlotArbiter.swift` | 删除 `updateSystemSessionCount` |
| `SessionMonitor.swift` | 调用 `PluginEventBus.shared.dispatch` |
| `NotchView.swift` | 移除 SessionCountIndicator、completion notification queue |
| `PluginsSettingsView.swift` | 内置插件 UI（灰置 toggle + 内置 badge） |

---

## 十、实现顺序

1. `PluginManifest` 加 `subscriptions` + `builtIn`
2. `PluginEventBus` — 事件转发框架
3. `PluginProcess.sendHookEvent` — 转发能力
4. `SessionMonitor` 接入 PluginEventBus
5. 创建 `ClaudePlugin` Xcode target + Swift CLI 可执行文件
6. 内置插件 bundle 结构 + `PluginRegistry` 扫描 app bundle
7. `NotchView` 清理（移除 SessionCountIndicator + completion queue）
8. `PluginSlotArbiter` 清理
9. `PluginsSettingsView` 内置插件 UI
10. 端到端验证：ClaudePlugin 进程起来，compact + notify 正常工作
