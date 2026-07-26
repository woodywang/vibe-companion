# 整体架构

Vibe Companion 目前是**纯本地的 macOS 菜单栏 App**，没有服务端、不发起任何网络请求。

## 模块职责

```
┌──────────────────────────────────────────────┐
│            macOS 客户端 (Swift)                │
│                                              │
│  Collector                                   │
│   ├ JsonlTailer (FSEvents + byte offset)     │
│   ├ ClaudeParser                             │
│   └ CodexParser                              │
│            │ UsageEvent                      │
│            ▼                                 │
│  TokenAggregator (60s 滑动窗口)               │
│            │ tokensPerMinute / todayTotal    │
│            ├──────────────┐                  │
│            ▼              ▼                  │
│  FloatingPetPanel     MenuBarExtra           │
│  (速度表悬浮窗)         (图标 + 下拉面板)       │
└──────────────────────────────────────────────┘
```

## 模块（`VibeCompanion/Sources/`）

| 模块 | 文件 | 职责 |
|---|---|---|
| App | `App/VibeCompanionApp.swift` | `@main` 入口、`MenuBarExtra`、`AppCoordinator` 生命周期协调 |
| App | `App/MenuBarContent.swift` | 菜单栏下拉视图（实时速率、今日累计、暂停、设置、退出） |
| Core | `Core/Models.swift` | `UsageEvent` 数据模型 |
| Core | `Core/AppConfig.swift` | 常量：速率聚合窗口 |
| Core | `Core/Settings.swift` | UserDefaults 持久化暂停状态（suite `dev.vibe.companion`） |
| Core | `Core/TokenAggregator.swift` | 60s 滑动窗口，计算 `tokensPerMinute` 与 `todayTotal` |
| Core | `Core/SpeedometerLogic.swift` | 速率 → 指针角度映射、idle 判定、数值格式化（纯函数，可单测） |
| Core | `Core/DateParsing.swift` | ISO8601 时间戳解析 |
| Collectors | `Collectors/JsonlTailer.swift` | FSEvents 监听 + byte offset 游标 + 行拆分 |
| Collectors | `Collectors/DataSource.swift` | Claude/Codex 文件路径发现 |
| Collectors | `Collectors/Collector.swift` | 协调 tailer + 解析器 + 事件产出 |
| Overlay | `Overlay/SpeedometerView.swift` | 纯 SwiftUI 绘制的速度表（表盘/刻度/指针/LCD 数字窗） |
| Overlay | `Overlay/FloatingPetPanel.swift` | 透明置顶 `NSPanel` + SwiftUI 内容（速度表 + 速率气泡） |
| Settings | `Settings/SettingsView.swift` | 设置窗口（暂停显示开关） |
| App | `App/UsageDisplay.swift` | 展示层读数快照 + 暂停冻结（摄入永不中断） |

## 数据流：一次 token 用量的旅程

1. 用户在 Claude Code 完成一回合 → 追加一行到 `~/.claude/projects/.../session.jsonl`。
2. `JsonlTailer` 的 FSEvents 触发 → 读增量 → `onLine`。
3. `ClaudeParser` 提取 `message.usage` → 产出 `UsageEvent`。
4. `AppCoordinator` 经 `UsageDisplay.ingest` 交给 `TokenAggregator.ingest`——**无论是否暂停**。暂停丢弃会让 tailer offset 照常前进而活跃块永久缺条目，burn rate 算出的是错值而非过时值；暂停只冻结 `UsageDisplay` 的读数快照。
5. 聚合器更新 60s 窗口 → `tokensPerMinute` 变化 → 悬浮速度表指针转动。菜单栏图标固定不动，速率只在下拉面板里以文字呈现。

数据全程只存在内存中，App 退出即清空。

## 关键设计决策

- **SwiftPM 而非 .xcodeproj**：可用 `swift build` 验证编译，`.app` 由脚本打包；避免手写易错的 pbxproj。
- **菜单栏 App + 悬浮窗**：放弃 WidgetKit（快照式刷新无法做连续动画）；`LSUIElement=true` 让 App 常驻菜单栏不占 Dock。
- **速度表纯 SwiftUI 绘制**：无 Lottie/Rive 依赖，映射逻辑抽到 `SpeedometerLogic.swift` 便于单测。
- **速率口径排除 cache_read**：prompt cache 命中会让 `cache_read_input_tokens` 达数十万，直接计入会让速率失真；速率窗口用 `effectiveTokens`，今日累计仍用 `totalTokens`。
- **本地优先**：不存在鉴权、设备注册与用户数据外发。唯一的出网请求是可选拉取 LiteLLM 公开定价表，失败即回退内置快照，不影响速率显示。
