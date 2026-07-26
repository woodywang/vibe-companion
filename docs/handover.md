# Vibe Companion · 会话交接文档

> 供下个会话快速接续工作。最后更新：2026-07-25。

## 项目一句话

游戏化的 vibe coding token 消耗追踪工具：macOS 菜单栏 App 实时采集 Claude Code / Codex CLI 的 token 用量，以悬浮速度表展示消耗速率。

## 当前状态：纯本地客户端

服务端与客户端联网层已于 2026-07-25 整体移除，项目聚焦客户端体验。如需查阅当时的实现，从 git 历史中取回。

副作用修正：`isPaused` 原先只在上传层生效（采集从未真正暂停）。现已接到 `AppCoordinator` 的事件入口，暂停后不再喂给聚合器，按钮名副其实。

用量数据只在内存中，仅保留最近 6 小时，App 退出即清空。落盘的只有用户设置（`UserDefaults`）与定价缓存（`~/Library/Application Support/VibeCompanion/pricing-cache.json`）。

## 如何启动（开发）

```bash
# 必须先设 Xcode 路径（本机 xcode-select 指向 CLT）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 从仓库根目录
swift build --package-path client           # 编译
swift test --package-path client            # 单测（23 个，需 Xcode 工具链提供 XCTest）
./scripts/build-app.sh          # 打包 .app（debug）
open .build/app/VibeCompanion.app
```

注意：不带 `DEVELOPER_DIR` 时 `swift test` 会报 `no such module 'XCTest'`（CLT 工具链无 XCTest），`swift build` 则不受影响。

## 已完成的功能

- SwiftPM 工程，零第三方依赖，`build-app.sh` 打包出可用 `.app`（`LSUIElement=true` 菜单栏常驻）
- 采集器：FSEvents 监听 `~/.claude` 和 `~/.codex` 的 JSONL，自维护 byte offset 游标
- 速率聚合：60s 滑动窗口 → `tokensPerMinute`（排除 cache_read）+ `todayTotal`
- 悬浮速度表：透明置顶 NSPanel + 纯 SwiftUI 绘制表盘（0–500k tok/min）+ 速率气泡
- 菜单栏：固定速度表图标（`gauge.with.dots.needle.67percent`）、当前速率、今日累计、暂停采集、设置、退出

## 踩过的坑（已修复，下个会话需知晓）

| 问题 | 根因 | 修复 | 位置 |
|---|---|---|---|
| 客户端读不到自身配置 | SwiftPM 打包的 .app 里 `UserDefaults.standard` 的 domain ≠ CFBundleIdentifier | 改用 `UserDefaults(suiteName: "dev.vibe.companion")` | `Core/Settings.swift` |
| 速率数值天文级 | prompt cache 命中让 `cache_read_input_tokens` 达数十万 | 速率窗口改用 `effectiveTokens`（排除 cache_read） | `Core/TokenAggregator.swift` |
| `swift test` 报 no such module 'XCTest' | `xcode-select` 指向 CLT | 命令前置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` | — |

## 已知的数据行为（非 bug）

- **同一 assistant 消息多行**：Claude Code 会把一条 assistant 响应写成多个 `type:assistant` 行（流式增量 + 最终态），共享同一 `uuid`。**注意**：不同 assistant 消息可能恰好有相同 `total_tokens`（如 102655），那是巧合不是重复。
- **速率延迟**：一条 JSONL 行只在「AI 回合完成」时写入，所以拿到的是每回合的 token 用量，非请求中流式。用户看到 AI 回复结束后速度表几乎立即抬升。
- **不回溯历史**：`JsonlTailer` 首次定位到 EOF，只统计 App 启动后的新增用量。
- **Cursor 不支持**：本地无 token 数据，需走其私有 API/网络拦截。

## 后续待办（按优先级）

### 高
- [ ] 悬浮窗视觉打磨（当前速度表为基础版，可加发光/阻尼动画/换肤）
- [ ] 本地历史留存（当前退出即清空；今日累计跨重启会归零）

### 中
- [ ] 悬浮窗位置记忆（当前每次启动固定右上角，见 `AppCoordinator.showFloatingPanel`）
- [ ] 多档位形象与解锁
- [ ] 签名与公证（当前 `.app` 未签名，需右键打开绕过 Gatekeeper）

### 低
- [ ] Cursor 支持（走私有 API 或网络拦截）
- [ ] Windows 客户端

## 关键文件速查

| 想看什么 | 文件 |
|---|---|
| 整体架构 | `docs/architecture.md` |
| 采集器原理（数据源/游标/速率） | `docs/collector.md` |
| 客户端构建 | `docs/client-build.md` |
| 采集解析 | `VibeCompanion/Sources/Collectors/Collector.swift` |
| 增量 tail 与游标 | `VibeCompanion/Sources/Collectors/JsonlTailer.swift` |
| 速率聚合 | `VibeCompanion/Sources/Core/TokenAggregator.swift` |
| 速度表量程/角度映射 | `VibeCompanion/Sources/Core/SpeedometerLogic.swift` |
| 悬浮窗 | `VibeCompanion/Sources/Overlay/FloatingPetPanel.swift` |
| 生命周期协调 | `VibeCompanion/Sources/App/VibeCompanionApp.swift` |

## 给下个会话的提示

1. 先读本文件和 `docs/architecture.md`。
2. `export DEVELOPER_DIR=...` 后 `./scripts/build-app.sh && open .build/app/VibeCompanion.app`。
3. 若速度表不动：确认进程在跑（`pgrep -lf VibeCompanion`）、未处于暂停（`defaults read dev.vibe.companion vc.paused`），并且当前有真实的 Claude/Codex 会话在产生新行。
