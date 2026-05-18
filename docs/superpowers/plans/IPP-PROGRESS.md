# Island Plugin Protocol — 实施进度

**状态：✅ 全部 11 个 Task 完成。42 个单测通过，全测试套件无回归。**

**当前分支：** `claude/jolly-benz-70d6a4`（worktree 分支）
**计划文档：** `docs/superpowers/plans/2026-05-18-island-plugin-protocol.md`
**Spec 文档：** `docs/superpowers/specs/2026-05-18-island-plugin-protocol-design.md`

---

## 已完成

### ✅ Task 1: Plugin 数据模型
- **Commits：** `43e34e1` (初始) + `a112929` (code review 修复)
- **文件：**
  - `PingIsland/Services/Plugin/PluginModels.swift`
  - `PingIslandTests/PluginModelsTests.swift`
- **测试：** 17/17 通过
- **Review 修复要点：**
  - 移除 section structs 的 `type` 存储属性（discriminator only encode 时注入）
  - `PluginManifest.icon` 重命名为 `iconPath`（JSON key 仍是 `"icon"`）
  - 全部 value type 加 `Sendable`
  - 加 encode roundtrip 测试

---

## 进行中

### 🔄 Task 2: PluginRegistry
**状态：** 已派 subagent 但被用户中断。代码未写入，未提交。

**下次继续方式：**
1. 重新派 implementer subagent（用 sonnet）— prompt 参考 plan 文档 Task 2 章节
2. 创建 `PingIsland/Services/Plugin/PluginRegistry.swift` 和 `PingIslandTests/PluginRegistryTests.swift`
3. 走 spec review + code quality review 流程

---

## 待办

| Task | 文件 | 说明 |
|------|------|------|
| 3 | `PluginProcess.swift` + 测试 | 子进程 + JSON-RPC over stdin/stdout |
| 4 | `PluginSlotArbiter.swift` + 测试 | slot 仲裁、carousel、sanitize |
| 5 | `PluginHost.swift` | 编排所有 PluginProcess |
| 6 | `IslandPluginRenderer.swift` | SwiftUI 渲染（无单测） |
| 7 | `IslandPresentation.swift`、`NotchActivityCoordinator.swift`、`NotchViewModel.swift` 改动 | 加 `.plugin` case |
| 8 | `NotchView.swift`、`IslandExpandedRoute.swift` 改动 | 接入 arbiter |
| 9 | `PluginsSettingsView.swift` + `SettingsWindowView.swift` 改动 | 设置标签页 |
| 10 | `AppDelegate.swift` 改动 + `PluginHost.runningProcesses` | 启动/停止 + button action 转发 |
| 11 | `Prototype/WeatherDemo.pingplugin/` | shell 脚本示例，端到端验证 |

---

## 关键约束（每次派 subagent 前必读）

1. **不要新建分支** — 直接在当前 `claude/jolly-benz-70d6a4` 上 commit
2. **Xcode 项目自动同步** — 使用 `PBXFileSystemSynchronizedRootGroup`，新文件放对目录即可，**无需改 pbxproj**
3. **测试 import：** `@testable import Ping_Island`
4. **macOS 14+，Swift 5.9**
5. **测试命令（必须加 codesign 关闭 flag）：**
   ```bash
   xcodebuild test \
     -project PingIsland.xcodeproj \
     -scheme PingIsland \
     -destination 'platform=macOS,arch=arm64' \
     -only-testing:PingIslandTests/<TestClassName> \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
     2>&1 | grep -E "passed|failed|Executed " | tail -20
   ```
   不加 codesign flag 会因为 Mac Development 证书缺失而 fail。
6. **commit message 规范：** `feat(plugin): ...` 或 `fix(plugin): ...`
7. **SourceKit IDE 警告** `No such module 'XCTest'` 是 IDE 误报，xcodebuild 实际编译通过，忽略

---

## 工作流（每个 task）

1. 派 **implementer subagent**（sonnet）→ 写测试 + 实现 + commit
2. 派 **spec compliance reviewer**（sonnet）→ 验证对照 plan
3. 派 **code quality reviewer**（sonnet）→ 验证代码质量
4. 如有 issues，派 implementer 修复 → 重 review
5. TodoWrite 标记完成 → 下一 task

---

## 下次开干第一步

```
派 subagent: "Implement Task 2: PluginRegistry"
- model: sonnet
- prompt 用 plan 文档 Task 2 章节全文
- 强调: 不要新建分支、PBXFileSystemSynchronizedRootGroup 不用改 pbxproj、测试用 @testable import Ping_Island
```

完成 11 个 task 后：
- 派 final code reviewer 审整体 diff
- 用 `superpowers:finishing-a-development-branch` skill 完成 branch
