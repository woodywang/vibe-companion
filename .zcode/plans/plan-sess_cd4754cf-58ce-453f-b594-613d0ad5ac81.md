# 修复速率显示：引入 effective tokens 口径

## 根因（已定位，Phase 1-2 完成）

`total_tokens` 把 `cache_read_input_tokens` 全额计入。Claude Code 的 prompt caching 让每条 assistant 事件携带 20-28 万 cache_read，占 total 的 92-99%。两端速率都基于 `SUM(total_tokens)` / 窗口内 total 之和，导致 2.9M/min 的天文数字。

实测（DB 全表 235 条）：cache_read 占 total 的 92.4%；effective（input+output+cache_creation）仅占 7.6%。修正后 2900k/min → ~220k/min，仍落在"喷射模式"区间，体感合理。

## 口径定义（用户已选 B）

- **`total_tokens` 保持原义不变**（含 cache_read）—— 用于今日/本周/排行榜等**累计**展示与流量统计。
- **新增 effective tokens = `input + output + cache_creation`**（排除 cache_read）—— 仅用于**速率**展示与动画。

## 改动清单

### 服务端（Next.js）

**1. `server/lib/usage/queries.ts`** —— 新增速率查询 helper
- 新增 `effectiveTokensPerMinuteForUser(userId, sinceMs)` 返回 `SUM(input_tokens + output_tokens + cache_creation_tokens) WHERE user_id=? AND recorded_at >= sinceMs`。
- `dailyTotalsForUser`、`globalLeaderboard` 不动（累计口径保持）。

**2. `server/app/dashboard/page.tsx`（L24-28）** —— 速率切到 effective
- 把 `recent` 的 `SUM(totalTokens)` 改为 `SUM(input_tokens + output_tokens + cache_creation_tokens)`。
- 变量名 `tokensPerMin` 保留（语义已是 effective/min），下游 `fmtRate`/`rateHint`/`petStatus`/`petEmoji`/动画阈值**全部不动**（实测 effective ~220k/min 仍超 30k，喷射模式生效，不会 idle）。
- `todayRow`/`weekTotal`/趋势图/`maxBar` 等累计项**不动**。

**3. `server/app/api/usage/me/route.ts`（L37-43, 61）** —— API 速率字段切 effective
- `tokensLast60s` 的 `SUM(totalTokens)` 改为 `SUM(input_tokens + output_tokens + cache_creation_tokens)`。
- `todayTotal`（L60）/`daily`（L59）不动。
- 响应字段名 `tokensPerMinute` 保留（语义已变），加注释说明口径。

**4. `server/app/page.tsx`（L44）** —— 落地页静态文案
- `8,500` 是营销占位数，本就不是真数据。保持不动（不属本次 bug 范围）。

### 客户端（Swift）

**5. `client/VibeCompanion/Sources/Core/Models.swift`** —— 加 computed 属性
- 给 `UsageEvent` 加 `var effectiveTokens: Int { inputTokens + outputTokens + cacheCreationTokens }`。
- 不改 `totalTokens` 存储字段（保持与服务端 schema 一致，累计口径用）。

**6. `client/VibeCompanion/Sources/Core/TokenAggregator.swift`（L30, L34）** —— 拆分 rate 与 cumulative
- L30 速率窗口：`window.append(Sample(tokens: event.effectiveTokens))`（rate 用 effective）。
- L34 今日累计：`todayTotal += event.totalTokens`（cumulative 保持 total，**不改**）。
- 这样 `tokensPerMinute` 输出 effective/min，`todayTotal` 仍是含 cache 的累计，与服务端累计口径一致。

**7. 客户端其它（MenuBarContent / FloatingPetPanel / LottiePetView / VibeCompanionApp / AppConfig）** —— **全部不动**
- 它们消费的是 `aggregator.tokensPerMinute`，已自动变为 effective。
- 阈值 2000/10000/30000 与 animationSpeed 的 8000 不动（实测 effective ~220k/min 远超阈值）。

### Codex 口径一致性（边界处理）

- Codex parser 里 `cacheCreationTokens: 0`（写死），`cacheReadTokens = cached`。
- effective = input + output + cacheCreation 对 Codex 等于 input + output + 0，**会丢弃 cached**。
- 这与口径意图一致（cached 是缓存读取复用，应排除）。Codex 速率会偏低但语义正确。**不改 Codex parser**。

## 不改动的部分（明确边界）

- `total_tokens` DB 列、schema、batch 上传逻辑 —— 不动
- 今日/本周/趋势图/排行榜所有累计展示 —— 不动（仍用 total_tokens）
- 成本估算 `types.ts` —— 不动（本就按分量算，未受 total 口径影响）
- 动画阈值与宠物状态阈值 —— 不动（实测 effective 仍落在合理区间）
- 客户端 Collector/ClaudeParser/CodexParser —— 不动（total_tokens 计算不变）

## 验证

1. 服务端：`sqlite3` 重算最近 60s effective，确认 ≈ 220k/min 量级（非 2.9M）。
2. 服务端：`npm run build` 或 typecheck 通过。
3. 客户端：`swift build` 通过。
4. 客户端：`./scripts/build-app.sh` 重打包，启动后悬浮窗/菜单栏速率显示合理值。
5. 网页：刷新 `/dashboard`，"当前速率"显示 effective 值；"今日 token"/趋势图仍显示原 total 值（不变）。

## 影响面

- 6 个文件改动（4 个实质性 + 2 个仅查询表达式）。
- 不改 DB schema、不改 API 契约（字段名不变，仅数值口径变）。
- 不破坏历史数据（已入库 235 条 total_tokens 不变）。
- 累计展示与速率展示从此口径分离，语义清晰。