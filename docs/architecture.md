# 整体架构

## 模块职责

```
┌─────────────────────────────┐         ┌─────────────────────────────┐
│      macOS 客户端 (Swift)     │         │      后端 + 网站 (Next.js)    │
│                             │         │                             │
│  Collector                  │         │  /api/auth/{register,login, │
│   ├ JsonlTailer (FSEvents)  │  HTTPS  │   logout}                   │
│   ├ ClaudeParser            │ ──────> │  /api/clients/register      │
│   └ CodexParser             │  Bearer │  /api/usage/batch (幂等)     │
│  TokenAggregator (60s 窗口)  │  Token  │  /api/usage/me              │
│  UsageStore (SQLite/GRDB)   │         │  /api/clients/me            │
│  Uploader (重试队列)          │         │  /api/leaderboard/global    │
│  FloatingPetPanel (Lottie)  │         │                             │
│  MenuBarExtra               │         │  网站: / /login /register    │
└─────────────────────────────┘         │       /dashboard /leaderboard│
                                        │  DB: SQLite (libsql/Drizzle) │
                                        └─────────────────────────────┘
```

## 客户端模块（`client/VibeCompanion/Sources/`）

| 模块 | 文件 | 职责 |
|---|---|---|
| App | `App/VibeCompanionApp.swift` | `@main` 入口、`MenuBarExtra`、`AppCoordinator` 生命周期协调 |
| App | `App/MenuBarContent.swift` | 菜单栏下拉视图（实时速率、今日累计、待上传、暂停、设置、退出） |
| Core | `Core/Models.swift` | `UsageEvent`、API 请求/响应类型（与服务端字段对齐） |
| Core | `Core/AppConfig.swift` | 常量：API base、上传间隔、速率窗口、动画速度映射 |
| Core | `Core/TokenAggregator.swift` | 60s 滑动窗口，计算 `tokensPerMinute` 与 `todayTotal` |
| Collectors | `Collectors/JsonlTailer.swift` | FSEvents 监听 + byte offset 游标 + 行拆分 |
| Collectors | `Collectors/DataSource.swift` | Claude/Codex 文件路径发现 |
| Collectors | `Collectors/Collector.swift` | 协调 tailer + 解析器 + 事件产出 |
| Storage | `Storage/UsageStore.swift` | GRDB SQLite 队列：enqueue/fetchPending/markUploaded/markFailed |
| Networking | `Networking/Settings.swift` | UserDefaults 持久化 client_token/api_base/paused |
| Networking | `Networking/Uploader.swift` | 定时批量上传 + 指数退避重试 |
| Overlay | `Overlay/LottiePetView.swift` | `NSViewRepresentable` 包装 `LottieAnimationView`，速度绑定 |
| Overlay | `Overlay/FloatingPetPanel.swift` | 透明置顶 `NSPanel` + SwiftUI 内容（宠物 + 速率气泡） |
| Settings | `Settings/SettingsView.swift` | 注册/粘贴 token、API base、暂停开关 |
| Resources | `Resources/Animations/cycling_pet.json` | 默认蹬车 Lottie 形象（占位，后续替换原创） |

## 后端模块（`server/`）

| 路径 | 职责 |
|---|---|
| `lib/db/schema.ts` | Drizzle 表定义：users / clients / usage_events / teams / team_members |
| `lib/db/index.ts` | libsql 连接（本地文件或远程 Turso） |
| `lib/auth/index.ts` | bcrypt 密码、JWT 会话、client_token 签发/校验 |
| `lib/auth/session.ts` | cookie 会话解析 -> `getCurrentUser`/`requireUser` |
| `lib/auth/client.ts` | Bearer token 解析 -> `resolveClient`（用于上传 API） |
| `lib/usage/types.ts` | `UsageEventInput` zod schema + 定价表 + `estimateCost` |
| `lib/usage/queries.ts` | 聚合查询：每日总量、全网排行榜、时间窗 helper |
| `app/api/*` | 7 个 API 路由（见下） |
| `app/{,login,register,dashboard,leaderboard}` | 网站页面 |
| `middleware.ts` | 保护 `/dashboard` 路径，未登录重定向 |
| `components/{AuthForm,ClientManager}.tsx` | 共享 UI 组件 |

## API 端点

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| POST | `/api/auth/register` | - | 注册，设 cookie |
| POST | `/api/auth/login` | - | 登录，设 cookie |
| POST | `/api/auth/logout` | cookie | 清 cookie |
| POST | `/api/clients/register` | cookie | 创建设备，返回 client_token（明文仅一次） |
| POST | `/api/usage/batch` | Bearer | 批量上传，`(client_id, source_uuid)` 幂等 |
| GET | `/api/usage/me?period=` | cookie | 自己的用量+趋势+设备+实时速率 |
| GET | `/api/clients/me` | cookie | 自己的设备列表 |
| GET | `/api/leaderboard/global?period=` | - | 全网排行（today/week/month） |

## 数据流：一次 token 用量的旅程

1. 用户在 Claude Code 完成一回合 -> 追加一行到 `~/.claude/projects/.../session.jsonl`。
2. `JsonlTailer` 的 FSEvents 触发 -> 读增量 -> `onLine`。
3. `ClaudeParser` 提取 `message.usage` -> 产出 `UsageEvent`。
4. `TokenAggregator.ingest` 更新 60s 窗口 -> `tokensPerMinute` 变化 -> Lottie `animationSpeed` 更新（宠物加速）。
5. `UsageStore.enqueue` 写入 SQLite `pending_event`（按 source_uuid 去重）。
6. 20 秒后或满 50 条，`Uploader.flush` 取 pending -> `POST /api/usage/batch`。
7. 后端 `resolveClient` 校验 Bearer token -> `estimateCost` 计算 USD -> 插入 `usage_events`（UNIQUE 约束兜底去重）。
8. 用户刷新 Dashboard -> `dailyTotalsForUser` + `globalLeaderboard` 聚合 -> 页面渲染趋势图与排名。

## 关键设计决策

- **SwiftPM 而非 .xcodeproj**：可用 `swift build` 验证编译，`.app` 由脚本打包；避免手写易错的 pbxproj。
- **libsql 而非 better-sqlite3**：Node v26 下 native addon 编译受阻；libsql 纯 JS/WASM 零编译，且可平滑切 Turso 远程。
- **双层幂等去重**：客户端 SQLite 按 source_uuid、服务端 UNIQUE 约束，保证崩溃/重传零重复。
- **菜单栏 App + 悬浮窗**：放弃 WidgetKit（快照式刷新无法做连续蹬车动画）；`LSUIElement=true` 让 App 常驻菜单栏不占 Dock。
- **Lottie 而非 Rive（MVP）**：`animationSpeed` 直接映射速率，实现简单；Rive 状态机留作多档位形象升级路径。
