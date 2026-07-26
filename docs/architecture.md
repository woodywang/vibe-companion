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
| Core | `Core/Settings.swift` | UserDefaults 持久化暂停状态、量程、EMA 时间常数（suite `dev.vibe.companion`） |
| Core | `Core/TokenAggregator.swift` | ccusage 区块速率（菜单栏）+ 瞬时速率（表盘）+ `todayTotal` |
| Core | `Core/InstantRate.swift` | 时间衰减 EMA：表盘的瞬时速率（纯值语义，不取系统时间） |
| Core | `Core/SpeedometerLogic.swift` | 配色分区（按指针行程比例）、LCD 与刻度标签格式化（纯函数，可单测） |
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
5. 聚合器更新两条互不干扰的读数：
   - **ccusage 区块速率**（`tokensPerMinute` / `indicator` / `level` / `costPerHour`）→ 菜单栏下拉面板的文字，数值与 `ccusage blocks` 一致；
   - **瞬时速率**（`instantTokensPerMinute`，时间衰减 EMA）→ 悬浮速度表指针转动。

   菜单栏图标固定不动。表盘那个数**不是** ccusage 的值，两者不可混用。

数据全程只存在内存中，App 退出即清空。

## 关键设计决策

- **SwiftPM 而非 .xcodeproj**：可用 `swift build` 验证编译，`.app` 由脚本打包；避免手写易错的 pbxproj。
- **菜单栏 App + 悬浮窗**：放弃 WidgetKit（快照式刷新无法做连续动画）；`LSUIElement=true` 让 App 常驻菜单栏不占 Dock。
- **速度表纯 SwiftUI 绘制**：无 Lottie/Rive 依赖，映射逻辑抽到 `SpeedometerLogic.swift` 便于单测。
- **表盘与菜单栏分家**：菜单栏是 ccusage 口径（区块全程平均，空闲冻结），表盘是瞬时 EMA。曾用「距末条 entry > 90 秒即归零」给常驻仪表做熄火反馈，实测每 13.6 分钟触发一次、占块时长 11%，造成「满值 → 瞬间归零 → 弹回满值」的暴跳，已整条删除——EMA 的自然衰减自带熄火效果且平滑。
- **配色按指针行程比例而非数值比例**：对数量程下两者差别极大（100k 在 10k–1M 表盘上指针正指中间，数值比例却只有 10%）。用行程比例才能保证任何量程下颜色与指针位置一致。
- **本地优先**：不存在鉴权、设备注册与用户数据外发。唯一的出网请求是可选拉取 LiteLLM 公开定价表，失败即回退内置快照，不影响速率显示。
