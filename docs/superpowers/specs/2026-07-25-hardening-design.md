# VibeCompanion 安全 / 健壮性加固 — 设计规格

- 日期：2026-07-25
- 分支：`worktree-hardening`
- 基线提交：`c032392`
- 范围：Code review 发现的 **H1–H4 + M1–M7**（C1 已在基线前修复）

## 1. 目标与非目标

**目标**：把 MVP 从"看起来完整但不安全、会丢数据、可刷分"提升到"能扩展、不被冒充、崩溃不丢数据、排名可信"的可上线状态，并建立最小回归保护（server vitest + client XCTest）。

**非目标**：
- 不做组队/Cursor 支持等未来功能。
- 不做与本次加固无关的重构。
- 不追求生产级限流/风控（Low 项，本轮不含）。

## 2. 测试基建（前置，TDD）

### server（vitest）
- 新增 devDependency `vitest`；`package.json` 加 `"test": "vitest run"`、`"test:watch": "vitest"`。
- `server/vitest.config.ts`：node 环境。
- 测试放 `server/lib/**/*.test.ts`，纯函数无 DB 依赖：token 哈希、`estimateCost`、zod 上下界与 `recordedAt` refine、`periodRange`、leaderboard 加权口径。

### client（XCTest）
- `Package.swift` 加 `.testTarget(name: "VibeCompanionTests", dependencies: ["VibeCompanion"])`，路径 `VibeCompanion/Tests`。
- 为可测性，把纯逻辑做成可从测试 target 访问（`internal`，`@testable import`）。
- 覆盖：`ClaudeParser`/`CodexParser` 解析、`TokenAggregator` 跨零点清零、`JsonlTailer` 字节级半行拆分、ISO8601 小数秒解析。
- 说明：`swift test` 首次会拉取 Lottie/GRDB 依赖。GUI/Lottie 渲染（M5）无法在单测覆盖，靠实机手动验证。

**流程**：每项先写失败测试 → 实现 → 绿 → 重构。

## 3. 服务端改动

### H1 — 客户端 token 鉴权去 bcrypt（O(n) → O(1)）

**问题**：`resolveClient` 全表拉取所有 client，对每行 `bcrypt.compare`（~100ms），每次 `/api/usage/batch` 都跑，自我 DoS。

**方案**：
- 新增 `lib/auth/token.ts`：`hashClientToken(token): string` = `crypto.createHash("sha256").update(token).digest("hex")`（token 为高熵随机串，快哈希足够）。
- `lib/db/schema.ts`：`clients.clientTokenHash` 加 `uniqueIndex("clients_token_hash_idx")`。
- `lib/auth/index.ts::signClientToken`：删除未使用的 `clientId` 参数；`hash` 改为 `hashClientToken(token)`。
- `lib/auth/client.ts::resolveClient`：改为
  ```
  const hash = hashClientToken(token)
  const rows = await db.select({...}).from(clients).where(eq(clients.clientTokenHash, hash)).limit(1)
  ```
  命中即更新 `lastSeenAt`，O(1)。
- `bcryptjs` 仍用于用户密码，保留。

**迁移决策（已确认）**：DB 为 dev、无真实用户 → **干净切换**。旧 bcrypt 哈希的 client 记录鉴权将失效，需重新在 Dashboard 注册设备。`npm run db:push --force` 重建 schema。

**测试**：`hashClientToken` 确定性、同 token 同 hash、不同 token 不同 hash、hex 长度 64。

### H2 — AUTH_SECRET 生产环境 fail-hard

**问题**：`AUTH_SECRET` 未设时回落硬编码 `"dev-secret-change-me-in-production"`，生产可伪造会话。

**方案**：`lib/auth/index.ts` 模块加载处：
```
const rawSecret = process.env.AUTH_SECRET;
if (process.env.NODE_ENV === "production" && !rawSecret) {
  throw new Error("AUTH_SECRET must be set in production");
}
const secret = new TextEncoder().encode(rawSecret ?? "dev-secret-change-me-in-production");
```
dev 未设时 `console.warn` 一次。

**测试**：因涉及模块级 env 判断，用一个可测的 `assertAuthSecret(env)` 纯函数承载逻辑并单测（production+缺失→throw；dev+缺失→不 throw）。

### H4 — 上传字段 / 时间戳上界

**问题**：token 字段无 `.max()`，`recordedAt` 允许任意值（负数/未来），排行榜可刷分。

**方案**：`app/api/usage/batch/route.ts` 的 `eventSchema`：
- 每个 token 字段：`.int().min(0).max(50_000_000)`（单回合 50M 上限，远超真实值）。
- `recordedAt`：`.int().refine(v => v >= Date.now() - 90*86400_000 && v <= Date.now() + 600_000, "recordedAt out of range")`（**已确认**：90 天补传窗口 + 10 分钟时钟偏差容忍）。
- 把 schema 常量抽到 `lib/usage/types.ts` 便于单测。

**测试**：合法值通过；超上限/负 token 拒绝；`recordedAt` 过去 91 天 / 未来 11 分钟拒绝，边界内通过。

### M6 — token 吊销 / 设备删除

**问题**：无法作废泄露的 token；设备只增不减。

**方案**：
- 新增 `app/api/clients/[id]/route.ts` 的 `DELETE`：cookie 鉴权（`requireUser`），校验 `client.userId === user.id`，删除该 client 行（`usage_events` 靠 FK `onDelete: cascade` 一并清理——**注意**：这会连带删掉该设备的历史用量。设计上可接受，UI 二次确认）。
- `components/ClientManager.tsx`：每台设备加"删除"按钮 + 确认，成功后从列表移除。
- 客户端 `SettingsView` 的"取消注册"：本轮仍只清本地（调用服务端删除需存 clientId 且非必须），在文案上明确"仅登出本机，如需彻底吊销请在网站删除设备"。

**测试**：DELETE 未登录→401；删他人设备→404/403；删自己→200 且列表不再含该 id（用轻量集成或 mock；若成本高则仅测归属校验纯函数）。

### M7 — cacheRead 放大速率/排名（已确认改加权口径）

**问题**：`totalTokens` 含 `cacheRead`（廉价且巨量），主导宠物速率与排行榜。

**方案**：引入"加权 token"概念 `weightedTokens = input + output + cacheCreation + reasoning`（**排除 cacheRead**）：
- **server**：`usage_events` 加列 `weighted_tokens`（integer，default 0），入库时由服务端计算写入（不信任客户端）。`globalLeaderboard` 排名与 `usage/me`、dashboard 的"速率/趋势"改用 `SUM(weighted_tokens)`。`totalTokens` 仍存储并在成本/明细处保留。
- **client**：`TokenAggregator` 的宠物速率改用 `weightedTokens`（客户端本地按同公式算，仅用于动画，不影响服务端权威值）。为此 `UsageEvent` 增加计算属性 `weightedTokens`。
- 排行榜/趋势 UI 文案不变（展示的是"token"，口径切换对用户透明）。

**测试**：`weightedTokens` 公式（含/不含各字段）；给定一组事件，leaderboard 加权求和正确。

## 4. 客户端（Swift）改动

### H3 — uploading 崩溃复位（防丢数据）

**问题**：`fetchPending` 标记 `uploading` 后若崩溃，行永久卡死，不再上传。

**方案**：`UsageStore.init` 在 `migrate` 之后调用 `recoverStuck()`：
```
try dbPool.write { db in
  try db.execute(sql: "UPDATE pending_event SET status='pending' WHERE status='uploading'")
}
```
每次启动都跑（非一次性迁移）。

**测试**：插入 `status='uploading'` 行 → 新建 `UsageStore`（或调 recover）→ 该行变 `pending`、可被 `fetchPending` 取到。

### M1 — 今日累计跨零点清零

**问题**：`todayTotal` 只增不减，跨天不归零。

**方案**：`TokenAggregator` 增 `private var currentDayKey: String`（`yyyy-MM-dd`，本地时区）。`ingest` 与 2s tick 开头都调 `rolloverIfNeeded()`：当天 key 变化 → `todayTotal = 0`、更新 key。`ingest` 仅当事件属"今天"才累加。

**测试**：注入日期为"昨天"的事件不计入 today；模拟跨天（注入可控 clock）后 `todayTotal` 归零。为可测，`TokenAggregator` 接受可注入的 `now`/日期提供者。

### M2 — 认证失败停止无限重试 + 退避

**问题**：`Uploader.upload` 不看 `statusCode`；401 被当网络错误无限重试；`attempts`/`uploadMaxRetries` 定义未用；文档承诺的指数退避未实现。

**方案**：`Uploader.upload` 解析 `HTTPURLResponse.statusCode`：
- 2xx → 解 `UsageBatchResponse` 成功。
- **401/403** → `.failure(unauthorized)`：`markFailed`（保数据）+ 停 timer + 状态 `.failed("认证失败，请重新注册")` + 置 `authBlocked=true`；`flush` 在 `authBlocked` 时直接 return。保存新 token（`SettingsView.saveToken`）时清 `authBlocked` 并 `start()`。
- **其他（5xx/网络）** → `markFailed`，`attempts+1`；引入指数退避：记录 `nextRetryAt = now + min(base*2^attempts, cap)`，`flush` 在 `now < nextRetryAt` 时跳过。`attempts` 达 `uploadMaxRetries` 后仍保留数据但拉大间隔（不丢弃）。

**测试**：给 `Uploader` 注入可 mock 的传输层（协议抽象 `Transport`），断言：401→停止且不再请求；500→退避递增；2xx→markUploaded。

### M3 — ISO8601 小数秒解析

**问题**：默认 `ISO8601DateFormatter` 不解析 `.123Z`，`recordedAt` 退化为"现在"；且每行新建 formatter。

**方案**：新增 `Core/DateParsing.swift`：两个静态复用 formatter（带 `.withFractionalSeconds` 与不带），`parseISO8601(_:) -> Date?` 先试带小数秒再兜底。`Collector` 两处解析改用它。

**测试**：`2026-07-25T09:30:00.123Z`、`...:00Z` 均解析成功且毫秒正确；非法串返回 nil。

### M4 — 半行 / 多字节截断防丢

**问题**：`readNew` 无条件把 offset 推到 EOF，半行或 UTF-8 边界被切时整块丢弃。

**方案**：`JsonlTailer` 增 `private var partials: [URL: Data]`：
- 读到增量 `data` 后：`buf = partials[url] + data`。
- 在**字节层**找最后一个 `\n`：其前的完整部分按 `\n` 切成多行、逐行 `String(data:.utf8)` 解码回调；末尾残段（最后 `\n` 之后）存回 `partials[url]`。
- `offset` 推进到 `currentSize`（残段字节已被缓存，不会丢）。
- 轮转/截断（`offset > currentSize`）时清空该 url 的 partials。

**测试**：把一行 JSON 拆成两次 `feed`（前半+后半）只在补全后产出一行；UTF-8 多字节（中文）跨块也能正确拼回。为可测，抽出纯函数 `splitLines(buffer:) -> (lines: [Data], rest: Data)` 单测。

### M5 — Lottie 资源路径（best-effort + 手动验证）

**问题**：SwiftPM 资源在 module bundle，打包脚本又放到 `.app/Contents/Resources/Animations/`，`LottieAnimationView(name:bundle:.main)` 可能找不到。

**方案**：`LottiePetView` 用健壮加载：优先 `Bundle.main` 下 `Animations/` 子目录查找 `cycling_pet.json`（用 `Bundle.main.url(forResource:withExtension:subdirectory:)` 显式路径构造 `LottieAnimation`），失败再退回 `LottieAnimationView(name:bundle:)`。找不到时降级为静态 emoji 而非空白。

**验证**：⚠️ 单测无法覆盖渲染，**改完需手动 `./scripts/build-app.sh` 运行确认宠物动画显示**。

## 5. 数据流 / 接口影响

- `usage_events` 新增 `weighted_tokens` 列（M7）——需 `db:push`。
- `clients` 新增唯一索引（H1）——需 `db:push`。
- 新增 `DELETE /api/clients/[id]`（M6）。
- 客户端上传体不变（字段名已在 C1 对齐）；服务端 batch 校验更严（H4）。
- 排行榜/趋势后端聚合字段由 `total_tokens` → `weighted_tokens`（M7），API 响应形状不变。

## 6. 验证与收尾

- server：`npm run test`、`npx tsc --noEmit`、`npm run build`。
- client：`swift build`、`swift test`。
- 手动：`./scripts/build-app.sh` 跑一次确认 M5 动画（唯一无法自动化项）。
- 走 verification-before-completion + requesting-code-review，再决定合并回 main。

## 7. 风险

- **M7 改口径**会让已有 dev 数据的排行榜数值变化（无真实用户，可接受）。
- **M6 级联删除**会连带删设备历史用量（UI 二次确认缓解）。
- **H1 干净切换**使旧 token 失效（无真实用户，可接受）。
- **M5** 依赖实机验证，是本轮唯一非自动化闭环项。
