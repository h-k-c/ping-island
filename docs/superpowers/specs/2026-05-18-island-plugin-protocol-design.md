# Island Plugin Protocol (IPP) — 设计规格

**日期：** 2026-05-18  
**状态：** 待实现  
**分支：** `feature/island-plugin-protocol`

---

## 一、背景与目标

PingIsland 目前以硬编码方式展示 Claude/Codex 会话状态。本设计将岛（Dynamic Island）抽象为可扩展的插件宿主平台，使第三方 macOS 应用（天气、系统监控、构建状态、网速等原本显示在状态栏的工具）能够将自己的内容迁移到岛上展示。

**核心约束：**
- PingIsland 统一渲染，插件只提供数据，不提供 UI 代码 → 保持视觉一致性
- PingIsland 作为宿主负责启动和管理插件进程 → 用户打开 PingIsland 即启动所有已启用插件
- 插件权限模型：简单开关（启用/禁用），无沙箱，面向本地可信应用
- 现有 Claude 功能不受影响，保持独立

---

## 二、插件 Bundle 结构

插件以 `.pingplugin` bundle 形式分发，安装路径：

```
~/Library/Application Support/PingIsland/Plugins/
└── WeatherPlugin.pingplugin/
    └── Contents/
        ├── manifest.json
        ├── MacOS/
        │   └── WeatherPlugin        ← 可执行文件（任意语言，需 chmod +x）
        └── Resources/               ← 可选，图标等资源
            └── icon.png             ← 插件图标，128×128 PNG
```

### manifest.json 规格

```json
{
  "id": "com.example.weather",
  "name": "天气",
  "version": "1.0.0",
  "minIslandVersion": "0.15.0",
  "executable": "Contents/MacOS/WeatherPlugin",
  "slots": ["compact", "notification", "expanded"],
  "description": "在岛上展示实时天气信息",
  "icon": "Contents/Resources/icon.png"
}
```

| 字段 | 类型 | 必须 | 说明 |
|------|------|------|------|
| `id` | string | ✓ | 反向域名格式，全局唯一 |
| `name` | string | ✓ | 显示名称，建议 ≤8 字符 |
| `version` | string | ✓ | semver |
| `minIslandVersion` | string | — | 最低兼容的 PingIsland 版本 |
| `executable` | string | ✓ | 相对于 bundle 根目录的可执行文件路径 |
| `slots` | string[] | ✓ | 插件使用的 slot，枚举值见第三节 |
| `description` | string | — | 设置页展示的说明文字 |
| `icon` | string | — | 相对于 bundle 根目录的图标路径（128×128 PNG） |

---

## 三、Slot 模型

岛有三个可供插件使用的展示区域：

### 3.1 compact slot — 闭合状态耳朵

岛闭合时左右两侧各有一个位置（"耳朵"），可显示图标+短文本。

```
┌─────────────────────────────────────────┐
│  [LEFT]      ████████████       [RIGHT] │  ← 闭合状态
└─────────────────────────────────────────┘
   ↑ compact/left                ↑ compact/right
```

- 每侧同时只能显示一个内容
- 多个插件争用同一侧：按 10 秒轮播
- **优先级：** 系统核心（Claude 活动指示）> 插件（按注册顺序）
- 当核心有活动时，插件 compact 内容自动让位，核心活动结束后恢复

### 3.2 notification slot — 临时通知气泡

岛短暂展开，显示通知内容后自动收起，与现有 `SessionCompletionNotification` 机制共用队列。

### 3.3 expanded slot — 展开面板

用户点击岛后打开的完整面板。

- 若只有一个插件有 expanded 内容：直接显示该插件内容
- 若多个插件有 expanded 内容：顶部显示插件 icon tab 栏，用户切换

---

## 四、JSON-RPC 通信协议

通信方式：**行分隔 JSON（newline-delimited JSON）over stdin/stdout**。

- Host 向插件写 stdin，读插件 stdout
- 插件 stderr 重定向到日志文件：`~/.ping-island-debug/plugins/<plugin-id>.log`
- 每条消息以单个 `\n` 结尾
- 遵循 JSON-RPC 2.0 格式（有 `id` 为 request/response，无 `id` 为 notification）

### 4.1 Host → Plugin

#### initialize（request）

PingIsland 启动插件进程后立即发送，插件必须在 **5 秒内**响应，否则标记为失败。

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "islandVersion": "0.15.3",
    "pluginId": "com.example.weather",
    "config": {}
  }
}
```

插件响应：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "name": "天气",
    "ready": true
  }
}
```

若插件无法就绪，返回 `"ready": false` 并附 `"error": "reason"`。

#### shutdown（notification）

PingIsland 退出前发送，插件应在 3 秒内主动退出，否则被强制终止（SIGKILL）。

```json
{
  "jsonrpc": "2.0",
  "method": "shutdown"
}
```

#### action（notification）

用户点击了插件在 expanded 或 notification 中放置的按钮。

```json
{
  "jsonrpc": "2.0",
  "method": "action",
  "params": {
    "actionId": "refresh"
  }
}
```

### 4.2 Plugin → Host

所有消息均为 **notification**（无 `id`），插件随时可推送，无需等待 Host 请求。

#### island/compact

更新 compact slot 内容，`content: null` 清除该侧显示。

```json
{
  "jsonrpc": "2.0",
  "method": "island/compact",
  "params": {
    "position": "right",
    "content": {
      "icon": { "type": "sf", "name": "sun.max.fill" },
      "label": "23°",
      "tint": "yellow"
    }
  }
}
```

`content` 为 `null` 时清除该位置。

#### island/notify

触发一条临时通知气泡，进入全局通知队列。

```json
{
  "jsonrpc": "2.0",
  "method": "island/notify",
  "params": {
    "icon": { "type": "sf", "name": "checkmark.circle.fill" },
    "title": "构建成功",
    "subtitle": "MyApp 1.0.2 · 32 秒",
    "duration": 4.0,
    "actionLabel": "查看",
    "actionId": "open_build_log"
  }
}
```

#### island/expanded

更新展开面板内容，空数组清除内容。

```json
{
  "jsonrpc": "2.0",
  "method": "island/expanded",
  "params": {
    "sections": [
      {
        "type": "stat",
        "label": "气温",
        "value": "23°C",
        "icon": { "type": "sf", "name": "thermometer.medium" },
        "tint": "default"
      },
      { "type": "divider" },
      {
        "type": "progress",
        "label": "湿度",
        "value": 0.65,
        "tint": "blue"
      },
      {
        "type": "button",
        "label": "刷新",
        "actionId": "refresh"
      }
    ]
  }
}
```

---

## 五、Island 原生组件规格（expanded sections）

插件 expanded 内容由以下组件自由组合，PingIsland 统一渲染：

### icon 类型（所有组件通用）

```json
{ "type": "sf", "name": "sun.max.fill" }   // SF Symbol
{ "type": "emoji", "value": "🌤" }          // Emoji
```

### tint 枚举

`"default"` | `"green"` | `"yellow"` | `"red"` | `"blue"` | `"orange"` | `"purple"`

---

### stat — 数据行

单行，左侧图标+标签，右侧数值。最常用。

```json
{
  "type": "stat",
  "label": "CPU",
  "value": "42%",
  "icon": { "type": "sf", "name": "cpu" },
  "tint": "default"
}
```

---

### text — 文字段落

```json
{
  "type": "text",
  "content": "最后更新：14:32",
  "style": "caption"
}
```

`style`: `"heading"` | `"body"` | `"caption"`（默认 `"body"`）

---

### list — 列表

```json
{
  "type": "list",
  "items": [
    { "icon": { "type": "sf", "name": "arrow.up" }, "label": "上行", "value": "12.3 MB/s" },
    { "icon": { "type": "sf", "name": "arrow.down" }, "label": "下行", "value": "3.1 MB/s" }
  ]
}
```

---

### progress — 进度条

```json
{
  "type": "progress",
  "label": "磁盘使用",
  "value": 0.73,
  "tint": "orange"
}
```

`value`: `0.0` – `1.0`

---

### chart — 迷你图表

```json
{
  "type": "chart",
  "label": "过去 1 小时 CPU",
  "values": [0.12, 0.45, 0.33, 0.67, 0.42, 0.55, 0.38],
  "style": "line"
}
```

`style`: `"line"` | `"bar"`（默认 `"line"`）  
`values`: 原始数值数组，渲染器自动归一化显示

---

### button — 操作按钮

```json
{
  "type": "button",
  "label": "刷新",
  "actionId": "refresh",
  "style": "default"
}
```

`style`: `"default"` | `"destructive"`  
点击后 Host 发送 `action` notification 给插件。

---

### divider — 分隔线

```json
{ "type": "divider" }
```

---

## 六、compact slot 数据规格

```json
{
  "position": "left" | "right",
  "content": {
    "icon": { "type": "sf", "name": "sun.max.fill" },
    "label": "23°",
    "badge": null,
    "tint": "yellow"
  } | null
}
```

| 字段 | 类型 | 限制 |
|------|------|------|
| `icon` | Icon | 必须 |
| `label` | string | 可选，最多 4 字符 |
| `badge` | number | 可选，非负整数，显示红色数字角标 |
| `tint` | string | 可选，见 tint 枚举 |

---

## 七、notification 数据规格

```json
{
  "icon": Icon,
  "title": string,          // 必须，建议 ≤20 字符
  "subtitle": string,       // 可选
  "duration": number,       // 秒，默认 4.0，最大 10.0
  "actionLabel": string,    // 可选，显示操作按钮文字
  "actionId": string        // actionLabel 存在时必须
}
```

---

## 八、宿主端新增组件

以下为需要在 PingIsland Xcode 项目中新增的 Swift 文件，均放入 `PingIsland/Services/Plugin/` 目录（新建）：

### 8.1 PluginManifest.swift

```swift
// Codable 模型，对应 manifest.json
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

enum PluginSlot: String, Codable {
    case compact
    case notification
    case expanded
}
```

### 8.2 PluginRegistry.swift

职责：发现 + 持久化已安装插件的启用状态。

```swift
// 扫描 ~/Library/Application Support/PingIsland/Plugins/ 中的 .pingplugin
// 使用 FSEventStream 监听目录变化（热插拔插件）
// 持久化启用状态到 UserDefaults key: "PluginRegistry.enabled.v1"（[String: Bool]）
// 对外暴露：
//   @Published var installedPlugins: [InstalledPlugin]
//   func setEnabled(_ enabled: Bool, for pluginId: String)
//   func isEnabled(_ pluginId: String) -> Bool
```

### 8.3 PluginHost.swift

职责：管理所有已启用插件的子进程生命周期。

```swift
// 在 AppDelegate.applicationDidFinishLaunching 中与其他服务同步启动
// 监听 PluginRegistry.installedPlugins 变化，动态增删 PluginProcess
// 对外暴露：
//   func start()
//   func stop()
//   var pluginStates: [String: PluginProcessState]  // pluginId -> state
```

### 8.4 PluginProcess.swift

职责：管理单个插件子进程，实现 JSON-RPC over stdin/stdout。

```swift
// 使用 Foundation.Process 启动可执行文件
// 环境变量注入: PING_ISLAND_VERSION, PING_ISLAND_PLUGIN_ID
// 工作目录: bundle Contents/ 目录
// stderr 重定向到 ~/.ping-island-debug/plugins/<id>.log
// initialize 超时: 5 秒
// 崩溃重启策略: 最多 3 次，退避间隔 1s / 2s / 4s，超出后标记 .failed
// 进程状态枚举:
enum PluginProcessState {
    case starting
    case ready
    case failed(String)
    case stopped
}
// 对外暴露：
//   func send(method: String, params: [String: Any])  // 向插件发消息
//   var compactUpdates: AsyncStream<PluginCompactUpdate>
//   var notificationUpdates: AsyncStream<PluginNotificationUpdate>
//   var expandedUpdates: AsyncStream<PluginExpandedUpdate>
```

### 8.5 PluginSlotArbiter.swift

职责：仲裁多个插件争用同一 slot。

```swift
// compact slot 仲裁规则:
//   - 每侧维护一个 [pluginId: CompactContent] 字典
//   - 系统核心（claude 活动）激活时，对应侧插件内容暂停显示
//   - 多个插件争用同侧：Timer 每 10 秒轮播
// notification 仲裁规则:
//   - 追加到现有 NotchView 的 completionNotificationQueue（需扩展支持插件通知）
// expanded 仲裁规则:
//   - 维护 [pluginId: [ExpandedSection]] 字典
//   - 若只有一个插件有内容，直接显示
//   - 若多个插件有内容，渲染 tab 栏
```

### 8.6 IslandPluginRenderer.swift

职责：把插件数据结构翻译为 SwiftUI 视图，使用现有设计 token。

```swift
// 提供以下 ViewBuilder:
//   func compactView(content: PluginCompactContent) -> some View
//   func notificationView(content: PluginNotificationContent) -> some View
//   func expandedView(sections: [ExpandedSection]) -> some View
// 颜色/字体/圆角完全复用现有 NotchView 设计 token，禁止硬编码新值
```

---

## 九、现有代码改动

### NotchContentType.swift（PingIsland/Core/IslandPresentation.swift）

新增 case：

```swift
enum NotchContentType: Equatable {
    case instances
    case chat(SessionState)
    case plugin(pluginId: String)   // ← 新增
}
```

### NotchActivityType（PingIsland/Core/NotchActivityCoordinator.swift）

新增 case：

```swift
enum NotchActivityType: Equatable {
    case claude
    case plugin(pluginId: String)   // ← 新增
    case none
}
```

### NotchViewModel.swift

在 `closedWidth` 相关逻辑中，为 compact slot 插件内容预留左右耳空间（参考现有 mascot/status 布局）。

### SettingsCategory（PingIsland/UI/Views/SettingsWindowView.swift）

新增枚举 case：

```swift
case plugins   // ← 新增，在 .integration 之前
```

对应：
- `title`: `"插件"`
- `subtitle`: `"已安装的岛插件"`
- `icon`: `"puzzlepiece.extension.fill"`

新增视图文件：`PingIsland/UI/Views/PluginsSettingsView.swift`

---

## 十、PluginsSettingsView 规格

```
┌─ 插件 ──────────────────────────────────┐
│                                          │
│  已安装（2）                              │
│  ┌────────────────────────────────────┐ │
│  │ 🌤  天气         1.0.0      [开启] │ │
│  │     在岛上展示实时天气信息           │ │
│  ├────────────────────────────────────┤ │
│  │ ⚡  系统监控      0.3.1      [开启] │ │
│  │     CPU/内存/网速                   │ │
│  └────────────────────────────────────┘ │
│                                          │
│  [ 打开插件文件夹 ]                        │
│                                          │
└──────────────────────────────────────────┘
```

- 每行：插件图标（从 bundle 读取，fallback 到 `puzzlepiece.extension.fill` SF Symbol）+ 名称 + 版本 + Toggle
- 若插件状态为 `.failed`：名称旁显示红色 `"崩溃"` badge
- "打开插件文件夹"：`NSWorkspace.shared.open(pluginsDirectoryURL)`
- 插件目录不存在时自动创建

---

## 十一、启动流程集成

在 `AppDelegate.applicationDidFinishLaunching` 中，与 `UpdateManager`、`UserIdleAutoProtection` 同级位置添加：

```swift
Task {
    await PluginHost.shared.start()
}
```

在 `applicationWillTerminate` 中：

```swift
Task {
    await PluginHost.shared.stop()
}
```

---

## 十二、错误处理规则

| 场景 | 处理方式 |
|------|----------|
| manifest.json 解析失败 | 跳过该插件，写日志，设置页标记 "格式错误" |
| initialize 超时（5s） | 标记为 `.failed("初始化超时")`，停止进程 |
| 插件进程崩溃 | 指数退避重启（1s/2s/4s），3 次后标记 `.failed("多次崩溃")` |
| shutdown 超时（3s） | SIGKILL 强制终止 |
| 非法 JSON 消息 | 忽略该行，写日志，不崩溃宿主 |
| slot 数据超出限制 | label 截断至 4 字符，duration 钳制至 [0.5, 10.0] |

---

## 十三、日志位置

| 类型 | 路径 |
|------|------|
| 插件 stderr | `~/.ping-island-debug/plugins/<plugin-id>.log` |
| PluginHost 运行日志 | OSLog subsystem: `com.wudanwu.pingisland` category: `Plugins` |

---

## 十四、内置 Claude 插件说明

现有 Claude/Codex 会话功能**不迁移**到插件系统（v1 范围外），继续以现有代码运行。

在设置页 Plugins tab 显示一条不可禁用的条目：

```
🤖  Claude 会话   内置          [始终开启]
    任务进度、通知与对话管理
```

此条目仅展示，无实际 `PluginProcess`。

---

## 十五、实现顺序建议

1. 新建分支 `feature/island-plugin-protocol`
2. 新建 `PingIsland/Services/Plugin/` 目录，实现数据模型（`PluginManifest`、`PluginSlot`、所有 content 结构体）
3. 实现 `PluginRegistry`（扫描+持久化，暂不含 FSEventStream）
4. 实现 `PluginProcess`（进程管理 + JSON-RPC 收发）
5. 实现 `PluginHost`（调度多个 `PluginProcess`）
6. 实现 `PluginSlotArbiter`（compact 轮播逻辑）
7. 实现 `IslandPluginRenderer`（SwiftUI 组件渲染）
8. 修改 `NotchContentType`、`NotchActivityType`、`NotchViewModel`、`NotchView` 接入插件 slot
9. 新增 `PluginsSettingsView`，接入 `SettingsCategory`
10. 修改 `AppDelegate` 接入 `PluginHost` 启动/停止
11. 添加 FSEventStream 热插拔支持
12. 编写一个最小示例插件（Shell 脚本）验证端到端流程

---

## 十六、示例插件（Shell 脚本，用于验证协议）

```bash
#!/bin/bash
# WeatherDemo.pingplugin/Contents/MacOS/WeatherDemo

while IFS= read -r line; do
  method=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('method',''))")
  
  if [ "$method" = "initialize" ]; then
    id=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',1))")
    echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"name\":\"天气Demo\",\"ready\":true}}"
    
    # 发送初始 compact 内容
    echo '{"jsonrpc":"2.0","method":"island/compact","params":{"position":"right","content":{"icon":{"type":"sf","name":"sun.max.fill"},"label":"23°","tint":"yellow"}}}'
    
  elif [ "$method" = "shutdown" ]; then
    exit 0
  fi
done
```

对应 manifest.json：

```json
{
  "id": "com.example.weatherdemo",
  "name": "天气Demo",
  "version": "0.1.0",
  "executable": "Contents/MacOS/WeatherDemo",
  "slots": ["compact"],
  "description": "演示用天气插件"
}
```
