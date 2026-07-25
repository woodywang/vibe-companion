# Vibe Companion · 会话交接文档

> 供下个会话快速接续工作。最后更新：2026-07-25。

## 项目一句话

游戏化的 vibe coding token 消耗追踪工具：macOS 客户端实时采集 Claude Code / Codex CLI 的 token 用量，以「蹬自行车的卡通形象」悬浮窗展示消耗速度，上传后端；网站支持注册、多客户端管理、全网排名。

## 当前状态：MVP 已跑通端到端真实联调

真实 Claude Code 编程的 token 消耗已成功采集并显示在网页上（实测 8.8M tokens / $34.41 上传成功）。

## 仓库结构

```
vide-companion/
├── client/    # macOS App (SwiftPM, SwiftUI + lottie-ios + GRDB)
├── server/    # Next.js 全栈 (App Router + Drizzle + libsql/SQLite)
├── scripts/   # build-app.sh 打包脚本
├── docs/      # architecture / collector / deployment / client-build / handover
└── .claude/worktrees/hardening  # Claude Code 的 hardening 分支 worktree（已 gitignore）
```

## 如何启动（开发）

### 后端 + 网站

```bash
cd server
npm install          # 已装好
npm run db:push      # 初始化 SQLite（已执行过，.data/app.db 已存在）
npm run dev          # http://localhost:3000
```

### macOS 客户端

```bash
# 必须先设 Xcode 路径（本机 xcode-select 指向 CLT）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 从仓库根目录
./scripts/build-app.sh          # 打包 .app（debug）
open client/.build/app/VibeCompanion.app
```

## 已完成的功能

### 后端 + 网站（server/）
- 7 个 API：注册/登录/登出、设备注册、批量幂等上传、查自己用量、设备列表、全网排行榜
- DB：Drizzle ORM + libsql/SQLite（可平滑切 Turso/Postgres，见 docs/deployment.md）
- 页面：落地页、登录、注册、个人 dashboard（实时速率/今日/本周/趋势图/设备管理/全网排名位）、全网排行榜（领奖台+列表，今日/周/月切换）
- 鉴权：bcrypt 密码 + JWT cookie 会话 + 设备 client_token（双层幂等去重）

### macOS 客户端（client/）
- SwiftPM 工程，`swift build` 通过，`build-app.sh` 打包出可用 `.app`（`LSUIElement=true` 菜单栏常驻）
- 采集器：FSEvents 监听 `~/.claude` 和 `~/.codex` 的 JSONL，自维护 byte offset 游标
- 速率聚合：60s 滑动窗口，`animationSpeed` 映射 token/min 驱动 Lottie 蹬车动画
- 本地缓冲：GRDB SQLite 队列，离线累积、失败重试
- 悬浮宠物窗：透明置顶 NSPanel + Lottie 动画 + 速率气泡
- 菜单栏：速率档位图标、今日累计、待上传、暂停、设置入口

## 端到端联调已验证

实测链路（2026-07-25）：
1. 客户端采集真实 Claude Code 会话（`~/.claude/projects/.../session.jsonl`）
2. 解析 `type:"assistant"` 行的 `message.usage`
3. 本地 SQLite 缓冲（按 source_uuid 去重）
4. 每 20s 批量上传 `POST /api/usage/batch`
5. 后端幂等入库（UNIQUE(client_id, source_uuid)）
6. 网页 Dashboard 显示：**8,828,498 tokens / $34.41**，排行榜 #1

## ⚠️ 联调中踩过的坑（务必注意，已修复但下个会话需知晓）

| 问题 | 根因 | 修复 | 位置 |
|---|---|---|---|
| 客户端 "Could not connect to server" | 后端 dev server 被停了 | 确保 `npm run dev` 在跑 | server/ |
| ATS 拒绝明文 HTTP | `.app` 连 `http://localhost` 被 App Transport Security 拦 | Info.plist 加 `NSAppTransportSecurity.NSAllowsLocalNetworking=true` | scripts/build-app.sh |
| 后端返回 `400 invalid_body` | 客户端 JSON 用 snake_case（`source_uuid`），后端 zod 期望 camelCase（`sourceUuid`） | 删除 Models.swift 的自定义 CodingKeys，用默认 camelCase | client/.../Core/Models.swift |
| 客户端读不到 client_token | SwiftPM 打包的 .app 里 `UserDefaults.standard` 的 domain ≠ CFBundleIdentifier | Settings.swift 改用 `UserDefaults(suiteName: "dev.vibe.companion")` | client/.../Networking/Settings.swift |

## 测试账号

dev 数据库（`server/.data/app.db`）里有：
- 用户：`test@vc.dev` / `hunter22`
- 3 个设备：Woody-MacBook、MacBook-Pro-M3、Woody-Live-Mac

client_token 明文只存于客户端 UserDefaults（`defaults read dev.vibe.companion vc.client_token`），服务端只存 hash。如需重置：`rm -rf server/.data && npm run db:push`（在 server/ 下）。

## 已知的数据行为（非 bug）

- **同一 assistant 消息多行**：Claude Code 会把一条 assistant 响应写成多个 `type:assistant` 行（流式增量 + 最终态），它们共享同一 `uuid`。本地按 `source_uuid` 去重，所以不会重复入库。**注意**：不同 assistant 消息可能恰好有相同 `total_tokens`（如 102655），那是巧合不是重复。
- **速率延迟**：一条 JSONL 行只在「AI 回合完成」时写入，所以拿到的是每回合的 token 用量，非请求中流式。体感：用户看到 AI 回复结束后，宠物约 20s 内（上传间隔）加速。
- **Cursor 不支持**：本地无 token 数据，需走其私有 API/网络拦截。

## superpowers 插件相关

用户安装了 superpowers 插件。本会话中插件生成了 `docs/superpowers/specs/cycling-pet-preview.html`（蹬车小人动画的 CSS 设计预览，361 行）。下个会话若要启用 superpowers 能力，需确认插件已正确启用（本会话技能列表中未出现该插件，可能需重启会话加载）。

## 后续待办（按优先级）

### 高
- [ ] **悬浮宠物窗实际效果验证**：当前 Lottie 形象是手写简易 JSON（橙黄身体+两轮子），视觉简陋。可用 `docs/superpowers/specs/cycling-pet-preview.html` 的设计重制 Lottie，或用 LottieFiles 公开素材。
- [ ] **Lottie 资源加载验证**：`LottiePetView` 用 `LottieAnimationView(name:bundle:.main)`，需确认 `.app/Contents/Resources/Animations/cycling_pet.json` 能被正确加载（当前 idle 状态用 emoji 占位，非 idle 走 Lottie，实际加载未在运行时验证过）。
- [ ] **client_token 存 Keychain**：当前存 UserDefaults（明文），生产应迁 Keychain。

### 中
- [ ] 组队功能（teams / team_members 表已建，API 与页面未实现）
- [ ] 完整全网排名（多周期细分、分模型排行）
- [ ] 形象扩展与解锁（多档位：idle/慢骑/飞驰/喷火）
- [ ] 签名与公证（生产分发，当前 `.app` 未签名，需右键打开绕过 Gatekeeper）
- [ ] 成本估算细化（当前定价表粗略，见 server/lib/usage/types.ts）

### 低
- [ ] Cursor 支持（走私有 API 或网络拦截）
- [ ] Rive 状态机升级动画
- [ ] 移动端查看
- [ ] Windows 客户端

## 关键文件速查

| 想看什么 | 文件 |
|---|---|
| 整体架构 | `docs/architecture.md` |
| 采集器原理（数据源/去重/速率） | `docs/collector.md` |
| 部署与 DB 迁移 | `docs/deployment.md` |
| 客户端构建 | `docs/client-build.md` |
| DB schema | `server/lib/db/schema.ts` |
| API 路由 | `server/app/api/*/route.ts` |
| 上传幂等逻辑 | `server/app/api/usage/batch/route.ts` |
| 成本定价表 | `server/lib/usage/types.ts` |
| 客户端采集解析 | `client/VibeCompanion/Sources/Collectors/Collector.swift` |
| 速率→动画速度映射 | `client/VibeCompanion/Sources/Core/AppConfig.swift` |
| 客户端 UserDefaults | `client/VibeCompanion/Sources/Networking/Settings.swift` |
| 悬浮宠物窗 | `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift` |
| Lottie 形象素材 | `client/VibeCompanion/Resources/Animations/cycling_pet.json` |
| 动画设计预览 | `docs/superpowers/specs/cycling-pet-preview.html` |

## Git 状态

- 分支：`main`
- 提交历史：
  - `c032392` Baseline: import client + server + docs before hardening（含所有联调修复）
  - `9cdb4f2` Initial commit
- 另有 worktree `hardening` 分支（`.claude/worktrees/hardening`，locked，已 gitignore）
- 本 handover 提交后工作区应干净

## 给下个会话的提示

1. 先读本文件和 `docs/architecture.md`。
2. 启动后端 `cd server && npm run dev`，启动客户端 `./scripts/build-app.sh && open client/.build/app/VibeCompanion.app`。
3. 用 `test@vc.dev` / `hunter22` 登录 http://localhost:3000/dashboard 看数据。
4. 客户端已绑定 token（`defaults read dev.vibe.companion`），无需重新注册。
5. 若数据不更新：先确认后端在跑（`curl localhost:3000`），再看客户端进程（`pgrep -lf VibeCompanion`）和本地缓冲（`sqlite3 ~/Library/Application\ Support/VibeCompanion/usage.db "SELECT status,COUNT(*) FROM pending_event GROUP BY status;"`）。
