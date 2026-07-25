# Vibe Companion — 实现方案

## 一、项目概览

游戏化的 vibe coding token 消耗追踪工具。macOS 客户端实时采集 Claude Code / Codex CLI 的 token 用量，以「蹬自行车的卡通形象」悬浮窗展示消耗速度（速率越高蹬得越快），数据上传后端；网站支持注册、多客户端管理、组队与全网排名。

**工作目录** `/Users/woody/Workspaces/vide-companion`（当前为空，全新搭建）。

## 二、技术选型

| 部分 | 选型 | 理由 |
|---|---|---|
| macOS 客户端 | SwiftUI（MenuBarExtra + 悬浮 NSPanel）+ lottie-ios | 原生、动画库成熟 |
| 动画 | Lottie 矢量（`animationSpeed` 映射 token/min） | MVP 简单；形象可热替换；Rive 留作后续升级 |
| 采集 | DispatchSource / FSEvents 监听 JSONL，自维护 byte offset 游标 | 近实时、低开销、可去重幂等上传 |
| 本地缓冲 | SQLite（GRDB.swift） | 离线缓存 + 上传失败重试 |
| 后端 | Next.js App Router + TypeScript | 全栈一体、API 与网站同栈 |
| 数据库 | PostgreSQL（Drizzle ORM） | 标准关系型，排名查询方便 |
| 鉴权 | 邮箱密码 + 设备 client_token（登录后签发，客户端长期持有） | 简单可靠 |
| 部署 | Next.js → Vercel 或自建；Postgres → Neon/自建 | MVP 灵活 |

## 三、数据源（已实测验证）

- **Claude Code**：`~/.claude/projects/<encoded-cwd>/*.jsonl`，`type:"assistant"` 行的 `message.usage` → `input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens`；附带 `timestamp` / `model` / `sessionId` / `uuid`（用作去重 key）。
- **Codex CLI**：`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`，`payload.type=="token_count"` 行 → `payload.info.last_token_usage.{input_tokens,cached_input_tokens,output_tokens,reasoning_output_tokens,total_tokens}`；去重 key = `${sessionId}-${timestamp}`。
- **Cursor**：本地无 token 数据（MVP 不支持，后续需走其私有 API 或网络拦截）。

## 四、目录结构

```
vide-companion/
├── README.md
├── client/                         # macOS App (Xcode 工程)
│   └── VibeCompanion/
│       ├── App/                    # @main, MenuBarExtra, 生命周期
│       ├── Collectors/             # ClaudeCollector, CodexCollector, JSONL tailer
│       ├── Core/                   # TokenAggregator(速率窗口), RateBucket
│       ├── Storage/                # SQLite 缓冲 + offset 游标
│       ├── Networking/             # 登录/注册/批量上传, 重试队列
│       ├── Overlay/                # 悬浮宠物窗(NSPanel) + LottieView
│       ├── Settings/               # 登录/形象/目标/暂停
│       └── Resources/Animations/   # *.json Lottie 形象(蹬车动物)
├── server/                         # Next.js 全栈
│   ├── app/
│   │   ├── (marketing)/            # 落地页
│   │   ├── (auth)/                 # 注册/登录
│   │   ├── dashboard/              # 自己的数据 + 多客户端
│   │   ├── teams/                  # 组队排名
│   │   ├── leaderboard/            # 全网排名
│   │   └── api/                    # 见 API 列表
│   ├── lib/{db,auth,usage,ranking}/
│   └── drizzle/                    # migrations
├── shared/                         # 类型/常量(可选, 简单复制)
└── docs/
```

## 五、核心模块设计

### 5.1 客户端采集器
- `JsonlTailer`：对每个匹配文件维护 `file_path → byte_offset`（持久化 SQLite），启动时定位到 EOF（不回溯历史），之后 `DispatchSource.makeFileSystemObjectSource` 监听增长；读到的完整行交给解析器。
- `ClaudeCollector` / `CodexCollector`：解析、提取 token 字段、产出 `UsageEvent`（含 `source_uuid` 去重键）。
- `TokenAggregator`：维护 60s 滑动窗口，计算 `tokens_per_minute` 与「今日累计」；驱动悬浮窗动画速率。

### 5.2 悬浮宠物窗
- `FloatingPetPanel`：`NSPanel`，`level = .floating`，透明背景、无标题栏、可拖动、可设置点击穿透；位置持久化。
- `LottieView`（`UIViewRepresentable` 包 `lottie-ios`）：循环播放蹬车动画，`animationSpeed = clamp(tokensPerMin / 8000, 0.25, 4.0)`。
- 速率档位映射形象行为：0 → idle（打盹）｜低 → 慢骑｜中 → 正常｜高 → 飞驰｜极高 → 火焰加速（MVP 先用速度系数 + 1 个默认形象；多档位形象作后续）。

### 5.3 菜单栏
- `MenuBarExtra`：图标（随速率变色）+ 下拉：当前 token/min、今日总量、网络状态、暂停采集、切换形象、打开网站、登录/登出、设置。

### 5.4 上传
- 本地 SQLite 队列：每条 `UsageEvent` 入库（`status=pending`）。
- 上传器：每 20s 或满 50 条触发 `POST /api/usage/batch`，成功标记 `uploaded`；失败指数退避重试；离线照常本地累计。
- 鉴权：登录后保存 `client_token`，请求头 `Authorization: Bearer <client_token>`。

## 六、数据库模型（Drizzle / Postgres）

- `users`(id, email UNIQUE, password_hash, display_name, created_at)
- `clients`(id, user_id FK, device_name, machine_id, client_token_hash, platform, created_at, last_seen_at) — 一用户多客户端
- `usage_events`(id, client_id FK, user_id FK, agent, session_id, model, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens, reasoning_tokens, total_tokens, cost_usd, recorded_at, source_uuid, UNIQUE(client_id, source_uuid)) — 幂等
- `teams`(id, name, created_by, created_at)
- `team_members`(team_id FK, user_id FK, joined_at, PK(team_id,user_id))
- 排名：基于 `usage_events` 聚合查询 + 物化视图/缓存（按 today/week/month）。

## 七、API

- `POST /api/auth/register`、`POST /api/auth/login`
- `POST /api/clients/register`（登录后创建设备，返回 `client_id` + `client_token`）
- `POST /api/usage/batch`（批量上传，按 `(client_id, source_uuid)` 幂等）
- `GET /api/usage/me?from&to`、`GET /api/clients/me`
- `GET /api/leaderboard/global?period=today|week|month`
- `GET /api/teams`、`POST /api/teams`、`GET /api/leaderboard/team/:id`

## 八、MVP 范围（纵向切片，明确边界）

**包含：**
1. 客户端：菜单栏 App + Claude/Codex 采集 + 悬浮宠物窗（1 个默认蹬车形象，速率→动画速度）+ SQLite 缓冲 + 登录/上传 + 基础设置。
2. 后端：注册/登录、设备注册、批量幂等上传、查自己数据、简单全局日榜。
3. 网站：落地页、登录注册、个人 dashboard（多客户端 + 今日/趋势）。

**明确不在 MVP：** 组队功能、完整全网排名（多周期/细分）、形象商城与多形象切换、Cursor 支持、Windows 客户端。

**后续阶段：** 队伍与全网排名完整版、形象扩展与解锁、Cursor 支持、Rive 状态机升级动画、移动端查看。

## 九、实施步骤（MVP）

1. 初始化 monorepo（git + 目录 + README + `.gitignore`）。
2. 后端先行：Next.js 脚手架 + Drizzle schema + 迁移 + 注册/登录/设备/批量上传/查自己/日榜 API；本地 Postgres 跑通。
3. 网站：落地页 + 登录注册 + 个人 dashboard 页面（接 API）。
4. 客户端：Xcode 工程脚手架 + 采集器（Claude+Codex tailer + 去重 + 速率聚合）+ SQLite + 登录/上传 + 悬浮宠物窗(Lottie，1 默认形象) + 菜单栏。
5. 打通联调：客户端真实采集 → 上传 → 网站可见 + 排名。
6. 一个默认蹬车动物 Lottie 资源（可先用 LottieFiles 公开素材占位，后续替换原创）。
7. 文档：README 使用说明 + 采集器原理 + 部署说明。

## 十、风险与备注

- **Lottie 形象素材**：MVP 用一张默认蹬车动物（占位或公开素材），原创美术后续补。
- **macOS 权限**：监听 `~/.claude`、`~/.codex` 属用户主目录，无需特殊 TCC 权限；App Sandbox 默认关闭（菜单栏常驻 + 悬浮窗 + 文件监听场景更简单），签名/公证后续处理。
- **去重幂等**：上传以 `(client_id, source_uuid)` 唯一约束保证，客户端/服务端均可重试安全。
- **成本估算**：`cost_usd` 由后端按 model+定价表计算（MVP 可先只存 token 数，cost 后补）。