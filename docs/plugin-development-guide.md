# PingIsland 插件开发指南

PingIsland 是一个 macOS Dynamic Island 平台。任何可执行文件都可以通过实现 **Island Plugin Protocol (IPP)** 成为一个岛插件，在刘海岛上展示自己的内容。

---

## 五分钟上手

### 1. 创建插件 Bundle

```
MyPlugin.pingplugin/
└── Contents/
    ├── manifest.json       ← 插件描述
    └── MacOS/
        └── MyPlugin        ← 可执行文件（任意语言，需 chmod +x）
```

### 2. 写 manifest.json

```json
{
  "id": "com.yourname.myplugin",
  "name": "我的插件",
  "version": "1.0.0",
  "executable": "Contents/MacOS/MyPlugin",
  "slots": ["compact", "notification", "expanded"],
  "description": "插件功能说明"
}
```

### 3. 写可执行文件

插件通过 **stdin 接收命令，通过 stdout 发送数据**（JSON-RPC，每行一条消息）。

以下是一个最小 Python 示例：

```python
#!/usr/bin/env python3
import sys, json

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    msg = json.loads(line.strip())
    method = msg.get("method", "")
    
    if method == "initialize":
        # 必须在 8 秒内响应 initialize，否则超时失败
        send({"jsonrpc":"2.0","id":msg["id"],"result":{"name":"我的插件","ready":True}})
        
        # 启动后推送初始内容
        send({"jsonrpc":"2.0","method":"island/compact","params":{
            "preferredPosition": "right",
            "content": {"icon":{"type":"sf","name":"star.fill"},"label":"Hi","tint":"yellow"}
        }})
        
    elif method == "shutdown":
        sys.exit(0)
```

### 4. 安装

```bash
cp -r MyPlugin.pingplugin "$HOME/Library/Application Support/PingIsland/Plugins/"
```

打开 PingIsland → 设置 → 插件 → 点「刷新」即可看到插件。

---

## 协议详解

### 主机 → 插件（Host 发给你）

| 消息 | 时机 | 必须响应 |
|------|------|---------|
| `initialize` | 插件启动时 | ✅ 必须在 8 秒内回复 `ready: true` |
| `action` | 用户点了你的按钮 | 无需响应 |
| `hookEvent` | AI 工具有新事件（需在 manifest 声明 `subscriptions`）| 无需响应 |
| `shutdown` | PingIsland 退出 | 退出进程 |

#### initialize 响应格式
```json
{"jsonrpc":"2.0","id":1,"result":{"name":"插件名","ready":true}}
```

---

### 插件 → 主机（你发给 PingIsland）

所有消息都是 JSON-RPC notification（无 `id` 字段），随时可发送。

#### `island/compact` — 刘海耳朵

```json
{
  "jsonrpc": "2.0",
  "method": "island/compact",
  "params": {
    "preferredPosition": "right",
    "content": {
      "icon": {"type": "sf", "name": "sun.max.fill"},
      "label": "23°",
      "tint": "yellow"
    }
  }
}
```

- `preferredPosition`: 可选，`"left"` 或 `"right"`。最终显示在哪一侧由用户在设置页的槽位分配决定
- `content`: 为 `null` 时清除该插件的 compact 内容
- `label`: 最多 4 个字符

#### `island/notify` — 通知气泡

```json
{
  "jsonrpc": "2.0",
  "method": "island/notify",
  "params": {
    "icon": {"type": "sf", "name": "checkmark.circle.fill"},
    "title": "任务完成",
    "subtitle": "MyProject",
    "duration": 4.0,
    "actionLabel": "查看",
    "actionId": "open_result"
  }
}
```

- `duration`: 显示时长（秒），默认 4，最大 10
- `actionLabel` + `actionId`: 可选，显示操作按钮，点击后收到 `action` 消息

#### `island/expanded` — 展开面板

点击刘海后显示的完整内容，由多个 section 组成：

```json
{
  "jsonrpc": "2.0",
  "method": "island/expanded",
  "params": {
    "sections": [
      {"type":"stat","label":"CPU","value":"42%","icon":{"type":"sf","name":"cpu"}},
      {"type":"divider"},
      {"type":"progress","label":"内存","value":0.65,"tint":"blue"},
      {"type":"button","label":"刷新","actionId":"refresh"}
    ]
  }
}
```

空数组 `"sections": []` 清除展开内容。

---

## Section 类型速查

| 类型 | 必填字段 | 可选字段 |
|------|---------|---------|
| `stat` | `label`, `value` | `icon`, `tint` |
| `text` | `content` | `style`（`heading`/`body`/`caption`） |
| `list` | `items`（每项含 `label`）| `items[].icon`, `items[].value` |
| `progress` | `value`（0.0-1.0）| `label`, `tint` |
| `chart` | `values`（数值数组）| `label`, `style`（`line`/`bar`）|
| `button` | `label`, `actionId` | `style`（`default`/`destructive`）|
| `divider` | 无 | — |

---

## Icon 格式

```json
{"type": "sf", "name": "star.fill"}       // SF Symbol
{"type": "emoji", "value": "⭐"}           // Emoji
```

## Tint 颜色

`"default"` `"green"` `"yellow"` `"red"` `"blue"` `"orange"` `"purple"`

---

## 订阅 AI Hook 事件（进阶）

如果插件需要感知 AI 工具的工作状态，在 manifest 里声明：

```json
{
  "subscriptions": ["hookEvent"]
}
```

然后处理 `hookEvent` 消息：

```python
elif method == "hookEvent":
    params = msg.get("params", {})
    session_id = params["sessionId"]
    phase = params["phase"]       # "idle" / "processing" / "ended"
    provider = params["provider"] # "claude" / "codex" 等
    cwd = params.get("cwd", "")
    
    if phase == "processing":
        # AI 正在处理，更新岛上显示
        send({"jsonrpc":"2.0","method":"island/compact","params":{
            "preferredPosition":"right",
            "content":{"icon":{"type":"sf","name":"bolt.fill"},"label":"...","tint":"green"}
        }})
```

---

## manifest.json 完整字段

| 字段 | 类型 | 必须 | 说明 |
|------|------|------|------|
| `id` | string | ✅ | 反向域名，全局唯一，如 `com.myname.myplugin` |
| `name` | string | ✅ | 显示名称 |
| `version` | string | ✅ | 版本号，如 `"1.0.0"` |
| `executable` | string | ✅ | 相对于 bundle 根目录的可执行文件路径 |
| `slots` | array | ✅ | 使用的 slot：`compact`、`notification`、`expanded`。`compact-left` / `compact-right` 仍兼容，但最终左右由用户分配 |
| `description` | string | — | 在设置页显示的说明 |
| `icon` | string | — | Bundle 内图标路径，128×128 PNG |
| `subscriptions` | array | — | 订阅的事件类型，目前支持 `"hookEvent"` |

### 内置插件

内置插件复用同一套 IPP 协议，但由 app bundle 内的 `PingIslandPlugin` 可执行文件按 `PING_ISLAND_PLUGIN_ID` 分流运行。内置 manifest 放在 `PingIsland/Resources/PluginBundles/<plugin-id>.pingplugin/Contents/` 下，并使用 `<plugin-id>.manifest.json` 命名；Xcode 会把这些 manifest 扁平化复制到 app Resources。

当前用户可配置的内置工具插件包括 AI Monitor 和只读的 Proc Monitor。Claude/Codex 会话监控也复用同一套内部协议传递 compact/notification 数据，但在产品概念上属于核心实时通知源，不作为插件卡片展示。Proc Monitor 使用 `compact` 展示内存占用百分比，`expanded` 展示内存总览和 Top 进程列表，不提供进程终止操作。

---

## 调试

插件的 stderr 会写到：
```
~/.ping-island-debug/plugins/<plugin-id>.log
```

---

## 完整示例：天气插件（Shell 脚本）

```bash
#!/bin/bash
# WeatherPlugin.pingplugin/Contents/MacOS/WeatherPlugin

send() { printf '%s\n' "$1"; }

TEMPS=(20 21 22 23 22 21 20)
IDX=0

update() {
  T="${TEMPS[$IDX]}"
  IDX=$(( (IDX+1) % ${#TEMPS[@]} ))
  send "{\"jsonrpc\":\"2.0\",\"method\":\"island/compact\",\"params\":{\"preferredPosition\":\"right\",\"content\":{\"icon\":{\"type\":\"sf\",\"name\":\"sun.max.fill\"},\"label\":\"${T}°\",\"tint\":\"yellow\"}}}"
}

while IFS= read -r line; do
  METHOD=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('method',''))" 2>/dev/null)
  ID=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',1))" 2>/dev/null)
  
  case "$METHOD" in
    initialize)
      send "{\"jsonrpc\":\"2.0\",\"id\":$ID,\"result\":{\"name\":\"天气\",\"ready\":true}}"
      update
      (while true; do sleep 30; update; done) &
      BG=$!
      ;;
    action)
      update
      send '{"jsonrpc":"2.0","method":"island/notify","params":{"icon":{"type":"sf","name":"arrow.clockwise"},"title":"已更新","duration":2.0}}'
      ;;
    shutdown)
      kill "$BG" 2>/dev/null
      exit 0
      ;;
  esac
done
```

对应 manifest.json：
```json
{
  "id": "com.example.weather",
  "name": "天气",
  "version": "1.0.0",
  "executable": "Contents/MacOS/WeatherPlugin",
  "slots": ["compact", "notification"],
  "description": "实时天气展示"
}
```
