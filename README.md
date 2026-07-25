# Vibe Companion

游戏化的 vibe coding token 消耗追踪工具。

macOS 客户端实时采集 Claude Code / Codex CLI 的 token 用量，以「蹬自行车的卡通形象」悬浮窗展示消耗速度（速率越高蹬得越快）；数据上传后端，网站支持注册、多客户端管理、组队与全网排名。

## 仓库结构

```
vide-companion/
├── client/   # macOS App (SwiftPM, SwiftUI + lottie-ios + GRDB)
├── server/   # Next.js 全栈 (App Router + Drizzle + libsql/SQLite)
├── scripts/  # build-app.sh 打包脚本
└── docs/     # 设计与原理文档
```

## 快速开始

### 后端 + 网站

```bash
cd server
npm install
npm run db:push     # 初始化 SQLite schema
npm run dev         # http://localhost:3000
```

环境变量见 `server/.env.example`。MVP 默认使用 SQLite（`server/.data/app.db`），无需额外安装数据库。后续可切换 Postgres（见 `docs/deployment.md`）。

### macOS 客户端

```bash
# 需先设 Xcode 路径（若 xcode-select 指向 CLT）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# 从仓库根目录
swift build -C client                   # 仅验证编译
./scripts/build-app.sh                  # 打包成 .app（debug）
open client/.build/app/VibeCompanion.app
```

## 数据源

| 工具 | 支持 | 说明 |
|---|---|---|
| Claude Code | ✅ | `~/.claude/projects/*/*.jsonl`，`type:"assistant"` 的 `message.usage` |
| OpenAI Codex CLI | ✅ | `~/.codex/sessions/*/*/*/rollout-*.jsonl`，`payload.type=="token_count"` |
| Cursor | ❌ | 本地无 token 数据，后续走其私有 API/网络拦截 |

详见 `docs/collector.md`。

## MVP 范围

- 客户端：菜单栏 App + Claude/Codex 采集 + 悬浮宠物窗（1 默认蹬车形象，速率→动画速度）+ 本地 SQLite 缓冲 + 登录/上传。
- 后端：注册/登录、设备注册、批量幂等上传、查自己数据、简单全局日榜。
- 网站：落地页、登录注册、个人 dashboard（多客户端 + 今日/趋势）、全网排行榜（今日/周/月）。

后续阶段：组队、完整全网排名、形象扩展与解锁、Cursor 支持、Rive 状态机动画。
