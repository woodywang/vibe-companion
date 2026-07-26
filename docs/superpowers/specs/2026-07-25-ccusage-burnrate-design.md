# 复刻 ccusage burn rate 算法 · 设计文档

日期：2026-07-25
状态：待用户审阅
参考实现：`github.com/ccusage/ccusage` v20.0.18（commit `739e88f`，Rust）

## 1. 背景与目标

当前 `TokenAggregator` 用「60 秒滑动窗口内 token 求和」作为 token 消耗速率。这是本项目自创的口径，与生态里的事实标准 `ccusage` 不可比。本次改造把速率计算替换为 ccusage 的 **session block burn rate** 算法，指标口径统一为 **Total Tokens**（含 cache_read）。

### 宗旨

**数据上与 ccusage 一致。** 所有偏离只允许出现在展示层与缓存策略，不得改变任何数值结果。

### 当前实现的三个缺陷

改造顺带修复以下问题，均由真实数据实测确认：

| 缺陷 | 位置 | 实测影响 |
|---|---|---|
| 完全没有去重 | `Core/TokenAggregator.swift` | 2083 条原始行去重后仅剩 917 条，速率高估 ~2.3 倍 |
| 去重键用 `uuid` 而非 `messageId:requestId` | `Collectors/Collector.swift:68` | Claude 一次响应写多行，`uuid` 各不相同，无法去重 |
| Codex `cached_input_tokens` 双计算 | `Collectors/Collector.swift:145-152` | 该字段嵌套在 `input_tokens` 内部，需相减 |

### 上游版本说明

ccusage 于 v20.0.0 由 TypeScript 重写为 Rust，仓库从 `ryoppippi/ccusage` 迁移至 `ccusage/ccusage`。算法在移植中未变。本文档以 Rust 版为准，标注文件路径均相对 `rust/crates/ccusage/src/`。

**注意**：`blocks` 与 `statusline` 子命令在 ccusage 中**仅对 Claude 开放**，`AgentReportKind` 没有 `Blocks` 变体。本设计把同一套 block 模型外推到 Codex，属于本项目的发明，无上游行为可对齐——只有 Claude 的数值可声称"与 ccusage 一致"。

## 2. 范围

### 本次包含

- 算法核心：TokenCounts / 去重 / session blocks / burn rate / cost
- `AgentAdapter` 协议 + Claude、Codex 两个适配器
- 采集层：历史回扫、6 小时有界窗口、乱序插入
- 展示层：可插拔量程、状态机

### 本次不包含

ccusage v20 共支持 15 个 coding agent。经实测，本机除 claude（2083 条）与 codex（3 个 session）外，其余均无有效数据：`kimi-code` 仅 1 个文件含 usage、`pi` 共 60 行、`droid`/`copilot`/`hermes`/`opencode` **零数据**（`opencode.db` 19 张表全部 0 行）。因此其余 13 个 agent 拆分为后续子项目：

- **子项目②**：JSONL 类扩展（gemini, amp, droid, codebuff, copilot, kimi, openclaw, pi, qwen）
- **子项目③**：SQLite 类扩展（goose, hermes, kilo, opencode），需引入 GRDB 与轮询采集

本次设计的 `AgentAdapter` 协议为②③预留扩展点。

## 3. 与 ccusage 的偏离清单

所有偏离均**不改变数值**：

| # | 项 | ccusage | 本实现 | 理由 |
|---|---|---|---|---|
| D1 | 表盘取值 | 只有区块速率 | 表盘另走**瞬时 EMA**；菜单栏为纯 ccusage 行为 | 区块速率是全程平均，指针不会对新 prompt 有反应；菜单栏那一侧不受影响 |
| D2 | 定价缓存 | 无磁盘缓存，每进程重抓 | 内置快照 → 磁盘缓存(TTL 24h) → 线上抓取 | 桌面应用频繁重启，不应每次启动都发网络请求 |
| D3 | indicator 用途 | 驱动 Normal/Moderate/High 配色徽章 | 降级为菜单栏文字；表盘配色由 Total 速率驱动 | 用户要求"颜色和角度保持一致" |
| D4 | 内存范围 | 全量读入历史 | 仅保留最近 6 小时 entry | 常驻进程不能无界增长 |
| D5 | cost 模式 | `auto`/`calculate`/`display` 三模式 | 固定 `calculate` | 本机 2491 条 assistant 记录中 `costUSD` 出现 **0 次**，`display` 与 `auto` 的读取分支永远走不到 |

## 4. 架构分层

```
Collectors/  AgentAdapter (协议)
             ├─ ClaudeAdapter    路径发现 / 行识别 / token 映射 / dedupKey
             └─ CodexAdapter
                    │ UsageEntry (归一化)
                    ▼
Core/        UsageWindow         有序插入 / 去重替换 / 6h 驱逐
                    ▼
             SessionBlocks       floor→UTC整点 / 双触发 / gap 块 / isActive
                    ▼
             BurnRate ◄────── CostCalculator ◄────── PricingSource (协议)
                    ▼
Overlay/     GaugeScale (协议)   量程可插拔，用户在设置中选择
```

**核心边界**：`Core/` 下除 `PricingSource` 的具体实现外，**不得触碰 I/O、网络、文件系统或任何 agent 特定格式**。全部为纯函数或可注入依赖的类型，可脱离运行环境完整单测。

### 文件清单

| 文件 | 状态 | 职责 |
|---|---|---|
| `Core/TokenCounts.swift` | 新增 | 归一化 token 分桶 + `total()` |
| `Core/UsageWindow.swift` | 新增 | 有界有序窗口 + 去重替换 |
| `Core/SessionBlocks.swift` | 新增 | `identifySessionBlocks` / `floorToUTCHour` |
| `Core/BurnRate.swift` | 新增 | `calculateBurnRate` / `BurnRateLevel` |
| `Core/Pricing.swift` | 新增 | `PricingSource` 协议 + 模型名解析 |
| `Core/CostCalculator.swift` | 新增 | TokenCounts × 定价 → USD |
| `Collectors/AgentAdapter.swift` | 新增 | 协议 + 注册表 |
| `Collectors/ClaudeAdapter.swift` | 新增 | 从 `Collector.swift` 拆出并修正 |
| `Collectors/CodexAdapter.swift` | 新增 | 从 `Collector.swift` 拆出并修正 |
| `Overlay/GaugeScale.swift` | 新增 | 量程协议 + 三种实现 |
| `Core/Models.swift` | 改造 | `UsageEvent` → `UsageEntry`；删除 `effectiveTokens` |
| `Core/TokenAggregator.swift` | 改造 | 滑窗 → 有界窗口 + 重算 |
| `Collectors/JsonlTailer.swift` | 改造 | 支持从 offset 0 起的回扫 |
| `Collectors/Collector.swift` | 改造 | 退化为 adapter 调度 |
| `Core/SpeedometerLogic.swift` | 改造 | 常量 → `GaugeScale` 协议 |
| `Overlay/SpeedometerView.swift` | 改造 | 刻度由 scale 驱动；红线区随量程 |
| `Core/Settings.swift` | 改造 | 增加 `gaugeScaleId` |

## 5. 算法层规格

### 5.1 数据模型

```swift
struct TokenCounts {
    var input: Int
    var output: Int
    var cacheCreation5m: Int
    var cacheCreation1h: Int
    var cacheRead: Int
    var extraTotal: Int          // 预留：gemini 等 agent 的未归类 token

    /// 对齐 ccusage TokenCounts::total()（types.rs:86-91，含 extra_total_tokens）
    var total: Int { input + output + cacheCreation5m + cacheCreation1h + cacheRead + extraTotal }
}
```

**关键**：`cacheCreation5m + cacheCreation1h` 之和等价于 ccusage 的 `cache_creation_token_count()`。计数场景两者合并，计价场景分开取价（单价不同）。

```swift
struct UsageEntry {
    let timestamp: Date
    let agent: String            // "claude" | "codex"
    let sessionId: String?
    let model: String?
    let counts: TokenCounts
    let isSidechain: Bool        // 去重优先级用
    let hasSpeed: Bool           // 去重优先级用
    let isFastSpeed: Bool        // cost 的 fast_multiplier 用
    let dedupKey: String?        // nil = 永不参与去重
}
```

`Models.swift` 现有的 `effectiveTokens`（`input + output + cacheCreation`）**删除**。它是为压制天文数字自创的口径，ccusage 无此概念；其角色由 `tokensPerMinuteForIndicator` 取代。

### 5.2 去重

对齐 `adapter/claude/mod.rs:224-238, 293-298`。

**键**：`"\(message.id):\(requestId)"`。任一为空时的行为按 v19.0.3 语义——`message.id` 缺失则 `dedupKey = nil`（永不去重）；`requestId` 缺失时退化为仅用 `message.id`。

**替换语义**（非跳过）。已存在同键条目时，按以下优先级判断新条目是否取代旧条目：

1. 非 sidechain 胜过 sidechain
2. 若 sidechain 状态相同：token 总量大的胜
3. 若总量也相同：带 `usage.speed` 字段的胜
4. 否则保留原有

实测本机 2374 条中 441 条为 sidechain（18.6%），此规则真实生效。**注意**：采用替换语义后同一区块的 Total 速率可从 439k 变为 760k——去重实现直接决定数值，不可简化。

### 5.3 Session Blocks

对齐 `blocks.rs:17-128`、`date_utils.rs:58-60`。

```
SESSION_DURATION_HOURS = 5
```

**块起点向下取整到 UTC 整点**，用整数欧几里得除法而非截断除法（负时间戳语义不同）：

```swift
func floorToUTCHour(_ ms: Int64) -> Int64 {
    let h: Int64 = 3_600_000
    return (ms / h - (ms % h < 0 ? 1 : 0)) * h   // 等价于 Rust 的 div_euclid
}
```

**分块流程**：

1. 全部 entry 按 timestamp 升序排序
2. 遍历，对每条 entry：
   - 若 `entry.ts - blockStart > 5h` **或** `entry.ts - lastEntry.ts > 5h`（均为**严格大于**），封闭当前块
   - 若是因**第二个条件**触发，额外插入一个 gap 伪块，跨度 `lastEntry.ts + 5h → entry.ts`
   - 新块起点 = `floorToUTCHour(entry.ts)`
3. 块结束时间 = `blockStart + 5h`
4. `isActive` = `now - lastEntry.ts < 5h` **且** `now < blockEnd`（两条件必须同时成立）
5. 块 `id` = 起点的 ISO-8601 字符串

**推论**：首个块的实际墙钟跨度在 4h00m–5h00m 之间，因为起点被 floor 到整点。

### 5.4 Burn Rate

对齐 `blocks.rs:535-552`。

```swift
struct BurnRate {
    let tokensPerMinute: Double              // 分子：TokenCounts.total（含 cache_read）
    let tokensPerMinuteForIndicator: Double  // 分子：input + output（两个 cache 桶均排除）
    let costPerHour: Double?
}

func calculateBurnRate(_ block: SessionBlock) -> BurnRate? {
    guard !block.entries.isEmpty, !block.isGap else { return nil }
    let first = block.entries.first!.timestamp
    let last = block.entries.last!.timestamp
    let durationMinutes = last.timeIntervalSince(first) / 60
    guard durationMinutes > 0 else { return nil }
    ...
}
```

**分母是「首条 entry → 末条 entry」**，不是块起点，也不是 `now`。空闲时间不会稀释速率，故空闲时该速率**冻结**——这与 ccusage 一致，菜单栏原样呈现。

> 曾经这里有一条「距末条 entry > 90 秒即归零」的展示层补丁，用于给常驻仪表"熄火"反馈。实测它在真实数据里每 13.6 分钟触发一次、占块时长 11%，造成「满值 → 瞬间归零 → 弹回满值」的暴跳。该补丁**已整条删除**：熄火反馈改由表盘的瞬时 EMA 自然衰减提供（见 D1）。

三个返回 `nil` 的守卫：entries 为空、块为 gap、`durationMinutes <= 0`（单条 entry 的块，或全部 entry 落在同一毫秒）。

**档位阈值**（对 `tokensPerMinuteForIndicator` 生效，仅用于菜单栏文字）：

```
< 2000        Normal
2000 – 5000   Moderate
> 5000        High
```

ccusage v17 时代的 `{HIGH: 1000, MODERATE: 500}` 已随 live monitor 在 v18 移除，**不要使用**。

### 5.5 定价与 Cost

对齐 `pricing.rs`、`cost.rs`。

#### 定价来源层次

```
1. 内置 LiteLLM 快照（打包为 app 资源）
2. 硬编码 builtin 表覆盖其上          ← claude-opus-4-8 在这里，LiteLLM 可能缺失
3. 磁盘缓存（TTL 24h）覆盖其上         ← 偏离 D2
4. 线上抓取覆盖其上                    ← 成功后写回磁盘缓存
```

线上地址：`https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`，超时 10s。

#### 读取的 LiteLLM 字段

```
input_cost_per_token                              (必需)
output_cost_per_token                             (必需)
cache_creation_input_token_cost                   缺省 = input × 1.25
cache_read_input_token_cost                       缺省 = input × 0.1，需记录是否显式给出
input_cost_per_token_above_200k_tokens
output_cost_per_token_above_200k_tokens
cache_creation_input_token_cost_above_200k_tokens
cache_read_input_token_cost_above_200k_tokens
max_input_tokens
```

`input` 或 `output` 缺失的条目**整条跳过**。

#### 1 小时缓存单价

```swift
let CACHE_CREATE_1H_INPUT_MULTIPLIER = 2.0
let cacheCreate1hRate = pricing.input * CACHE_CREATE_1H_INPUT_MULTIPLIER
```

**这不是 LiteLLM 的 key**。LiteLLM 上游确实发布了 `cache_creation_input_token_cost_above_1hr`，但 ccusage 不读它，而是从 **input 单价**（不是 cache_creation 单价）乘 2.0 推导。两者对当前所有 Anthropic 模型数值相同。

#### Cost 公式

```
若 usage.cache_creation 对象存在：
    cacheCreate5m = ephemeral_5m_input_tokens
    cacheCreate1h = ephemeral_1h_input_tokens
    ← 完全忽略扁平的 cache_creation_input_tokens
否则：
    cacheCreate5m = cache_creation_input_tokens
    cacheCreate1h = 0
```

实测本机 2615 条 usage **全部**带 `cache_creation` 对象（990 条 1h>0，1624 条 5m>0），扁平分支永远走不到。

五个桶各自独立做 200K 边际分段：

```swift
func tieredCost(_ tokens: Int, base: Double, above: Double?, threshold: Int = 200_000) -> Double {
    guard tokens > 0 else { return 0 }
    if let above, tokens > threshold {
        return Double(threshold) * base + Double(tokens - threshold) * above
    }
    return Double(tokens) * base
}

cost = tieredCost(input,          base: p.input,            above: p.inputAbove200k)
     + tieredCost(output,         base: p.output,           above: p.outputAbove200k)
     + tieredCost(cacheCreate5m,  base: p.cacheCreate,      above: p.cacheCreateAbove200k)
     + tieredCost(cacheCreate1h,  base: cacheCreate1hRate,  above: p.inputAbove200k.map { $0 * 2.0 })
     + tieredCost(cacheRead,      base: p.cacheRead,        above: p.cacheReadAbove200k)
```

实测 375 条 entry 的 `cache_read` 超过 200K（最大 460,590），分段计价真实触发，不可简化。

**OpenAI 整请求分段**（`long_context_threshold` 非 nil 时，阈值 272K）走另一分支：由 `input_tokens` 单独决定档位，所有桶整体按该档单价计费。本次两个 adapter 都用不到，但协议需预留。

#### fast_multiplier

```swift
let multiplier = entry.isFastSpeed ? pricing.fastMultiplier : 1.0
cost = baseCost * multiplier
```

倍率来自 `provider_specific_entry.fast`，缺失时查覆盖表：

```json
{"exact": {"gpt-5.5": 2.5, "gpt-5.4": 2.0, "gpt-5.3-codex": 2.0},
 "normalized_prefix": {"claude-opus-4-6": 6.0, "claude-opus-4-7": 6.0, "claude-opus-4-8": 2.0}}
```

实测本机 `usage.speed` 只出现 `standard`(1734) 与缺失(881)，从未出现 `fast`，但仍按宗旨完整实现。

#### 聚合到 block

cost 按 **entry 逐条计算**后求和得到 `block.costUSD`，不可用 block 聚合后的 TokenCounts 一次性计算。原因有三，任一都会导致数值偏差：

- 200K 边际分段是**按单次请求**判定的，聚合后再分段会把多条小请求错误地推过阈值
- `fast_multiplier` 是 **per-entry** 的（取决于该条的 `usage.speed`）
- 一个 block 内可能混用多个模型（实测本机同时出现 opus-5 / sonnet-5 / opus-4-8 / haiku-4-5），单价不同

`BurnRate.costPerHour` 则由 `block.costUSD / durationMinutes * 60` 得出，分母与两个速率完全一致。

#### 模型名解析

四步，逐级降级：

1. 精确哈希查找
2. 归一化：`.` 和 `@` 替换为 `-`，再查（`claude-3.5-sonnet` ≡ `claude-3-5-sonnet`）
3. 双向边界感知子串匹配，**最长 key 胜**，同长则字典序小者胜
   - 匹配位置前一字节必须非字母数字（或为串首），匹配后缀必须以非字母数字开头（或为串尾）
   - 若候选 key 以数字结尾且其后紧跟 `-<数字>`，拒绝匹配——**除非**该数字串恰好 8 位（Anthropic 的 `YYYYMMDD`）
4. 别名表

**推论**：`claude-haiku-4-5` 可匹配 `claude-haiku-4-5-20251001`（8 位日期），但 `claude-opus-4` **不可**匹配 `claude-opus-4-5`。

**未命中**：cost 记 0 并产生一条告警，**不报错、不跳过该 entry**，token 照常计入。`<synthetic>`（本机出现 1 条）永远命中不了，即 cost 为 0，且不计入模型分布统计。

### 5.6 Adapter 规格

```swift
struct ParseContext { var stickyModel: String?  /* Codex 的 turn_context 设定 */ }

protocol AgentAdapter {
    var id: String { get }
    func discoverFiles() -> [URL]
    func parse(line: String, context: inout ParseContext) -> UsageEntry?
    func dedupKey(_ entry: UsageEntry) -> String?
}
```

`inout ParseContext` 的存在是因为 Codex 的 model 是 sticky 的：由 `type == "turn_context"` 行设定，供后续 `token_count` 行使用。

#### ClaudeAdapter

- 路径：`$CLAUDE_CONFIG_DIR`（逗号分隔，展开 `~`）否则 `${XDG_CONFIG_HOME:-~/.config}/claude` 与 `~/.claude`，各需存在 `projects/` 子目录；glob `projects/**/*.jsonl`
- 行识别：**不检查 `type == "assistant"`**。ccusage 的判定是含 `"usage":{` 且解码成功且 `timestamp` 与 `message.usage` 均存在
- token 映射：四字段直取；`cache_creation` 对象存在时拆 5m/1h
- 去重键：`message.id` + `:` + `requestId`

> **注**：当前实现（`Collector.swift:62`）用 `type == "assistant"` 过滤。改为 ccusage 口径后可能纳入更多行，需在实现时以真实数据对比两种口径的条目数差异并记录。

#### CodexAdapter

- 路径：`$CODEX_HOME`（逗号分隔，**不**展开 `~`）否则 `~/.codex`；glob `sessions/**/*.jsonl` 与 `archived_sessions/**/*.jsonl`，**无 `rollout-*` 前缀过滤**
- 行识别：`type == "event_msg"` 且 `payload.type == "token_count"`；`type == "turn_context"` 更新 sticky model
- usage 来源：`payload.info.last_token_usage`（每回合增量）；缺失时用 `total_token_usage` 减去累计前值
- token 映射（**修复当前 bug**）：
  ```
  cachedClamped = min(cached_input_tokens, input_tokens)
  input         = input_tokens - cachedClamped      ← 当前实现缺此步
  cacheRead     = cachedClamped
  output        = output_tokens
  cacheCreation = 0                                  ← Codex 无缓存写入概念
  total         = 文件自带的 total_tokens（直取，不重算）
  ```
- `reasoning_output_tokens` **不单独计入**，它已包含在 `output_tokens` 内
- 去重键：`(timestamp, model, input, cached, output, reasoning, total)` 的组合，**不含 sessionId**
- Cost：`cached_input_tokens` 按 `cache_read` 单价计费**仅当该单价显式给出**，否则按**完整 input 单价**（与 Claude 路径的 `input × 0.1` 缺省不同）；`fast` 时若模型无显式倍率则默认 **2.0**（Claude 路径默认 1.0）

## 6. 采集层规格

### 6.1 数据流

```
启动
 └─ 各 Adapter.discoverFiles()
     └─ tail-probe：seek 到 EOF-8KB，反向找末条完整 JSON 行，读其 timestamp
         ├─ 在 6h 内  → JsonlTailer 初始 offset = 0（回扫全文）
         └─ 早于 6h   → JsonlTailer 初始 offset = EOF（不回扫）

运行时
 └─ FSEvents → JsonlTailer 增量读 → Adapter.parse → UsageEntry → UsageWindow.insert

每 2s 定时器
 └─ UsageWindow.evict(now) → identifySessionBlocks → calculateBurnRate → @Published
```

**回扫与尾随共用同一条代码路径**——把初始 offset 设为 0，正常的增量读逻辑自然读完全文。这消除了「先回扫后 watch」之间的漏数据窗口。

回扫在后台队列执行，不阻塞 UI。实测本机需回扫 12.42 MB / 46 文件（tail-probe 过滤掉 10 文件 / 4.44 MB），单文件最大 2.65 MB。

### 6.2 UsageWindow

```swift
final class UsageWindow {
    func insert(_ entry: UsageEntry)   // 按 timestamp 二分插入 + 去重替换
    func evict(now: Date)              // 丢弃 timestamp < now - 6h
    func snapshot() -> [UsageEntry]    // 有序、已去重
}
```

**保留窗口 6 小时**的推导：活跃块要求 `now < blockStart + 5h`，而 `blockStart = floorToUTCHour(firstEntry)` 最多比 `firstEntry` 早 1 小时，故活跃块的首条 entry 不会早于 `now - 5h`；再加 1 小时余量覆盖 floor 偏移，6h 足以保证活跃块的分块结果与全量重扫一致。

**乱序是必须处理的**：多个 session 文件由 FSEvents 并发触发，回扫与实时 tail 交错，到达顺序不等于 timestamp 顺序。而分块规则对顺序敏感。二分插入保证窗口始终有序。

替换发生时，旧条目须从有序数组中移除后再插入新条目——新旧条目的 timestamp 可能不同，不能原地覆盖。

### 6.3 时间口径

现有 `TokenAggregator.ingest` 用**到达时间** `now()` 建窗（`TokenAggregator.swift:34-36`）。必须改为使用 **entry 自身的 timestamp**，否则回扫的历史数据会被当作"此刻发生"，分块完全错乱。这是从滑窗转向 session block 模型的前提。

## 7. 展示层规格

### 7.1 可插拔量程

真实分布跨度约 20 倍（实测 41k – 760k tok/min），单一量程无法兼顾。量程改由用户在设置中选择：

```swift
protocol GaugeScale {
    var id: String { get }                    // 持久化到 Settings.gaugeScaleId
    var displayName: String { get }
    var majorTicks: [Double] { get }
    func angle(for value: Double) -> Double   // -135° ... +135°，clamp
}
```

| 实现 | 刻度 |
|---|---|
| `LinearScale(max:)` | 0 / 200k / 400k / 600k / 800k / 1M |
| `LogScale(min:max:)` | 10k / 30k / 100k / 300k / 1M |
| `AdaptiveScale` | 随 `TokenAggregator.recentPeakTokensPerMinute` 浮动 |

`SpeedometerView.swift:13-14` 写死的 `redlineStart` 与 `majorValues` 删除，刻度改由 `scale.majorTicks` 驱动。

### 7.2 配色

指针角度、LCD 数字、配色**全部由 `tokensPerMinute`（Total）驱动**，三者天然一致。

阈值定义为**指针行程比例**——即 `(angle(value) - angleMin) / (angleMax - angleMin)`，而非绝对速率、也不是 `value / maxValue`：

| 指针行程 | 颜色 |
|---|---|
| < 60% | 绿 |
| 60% – 85% | 黄 |
| > 85% | 红（红线弧画在此段） |

**必须用行程比例而非数值比例**：对数量程下 100k 在 10k–1M 表盘上指针正指中间（行程 50%），数值比例却只有 10%。按数值比例配色会让指针指在正中却显示绿色，破坏"颜色与角度一致"。红线弧的起点角度同样直接由 85% 行程算出，不经过数值映射。

`tokensPerMinuteForIndicator` 照常计算，但只出现在菜单栏下拉的一行文字（Normal/Moderate/High，阈值 2000/5000）。

### 7.3 显示状态

| 状态 | 触发 | 表现 |
|---|---|---|
| 正常 | 有活跃块且 `burnRate != nil` | 指针 + 数字 + 配色 |
| 无速率 | 活跃块仅 1 条 entry（`duration <= 0`） | 菜单栏显示 `--`（**不是 `0`**）。这是 ccusage 自己的语义，与空闲无关 |
| 熄火 | 瞬时 EMA 衰减到 0（约 `ln(value)·τ` 秒） | 指针平滑落回 0，LCD 显示 `--`，隐藏气泡 |

表盘的 `--` 由**瞬时**速率是否为 0 决定，**不用** `hasBurnRate`——后者会把"会话第一条记录"这种最该给出即时反馈的时刻压掉。

## 8. 错误处理

| 失败 | 处理 |
|---|---|
| 定价抓取失败或未就绪 | `cost` 为 `nil`，速率照常。网络与主功能完全解耦 |
| 单行 JSON 解析失败 | 跳过该行，不中断文件 |
| 模型名未命中定价表 | 该条 cost 记 0 并告警，token 照常计入 |
| 文件被截断/轮转 | 沿用现有 `currentSize < offset` 检测，offset 归零 |
| 回扫中途失败 | 该文件降级为 EOF 尾随，不影响其它文件 |
| tail-probe 读取失败 | 保守起见按"需回扫"处理 |

**约束**：`CostCalculator` 不得直接发起网络请求，只能依赖注入的 `PricingSource`。否则算法层单测将被迫联网，违背第 4 节的分层边界。

## 9. 测试策略

算法层为纯函数，按 ccusage 源码写表驱动测试：

| 目标 | 用例 |
|---|---|
| `floorToUTCHour` | 整点 / 非整点 / **负时间戳**（欧几里得除法与截断除法结果不同） |
| `identifySessionBlocks` | 两个触发条件各自的边界（严格 `>`，恰好 5h **不**开新块）；gap 块生成与跨度；`isActive` 双条件的四种组合 |
| `calculateBurnRate` | 三个 `nil` 守卫；两个速率分子的差异（cache 桶是否计入） |
| 去重 | 三级优先级各自的分支；`dedupKey == nil` 时不去重；替换后有序性保持 |
| `UsageWindow` | 乱序插入后仍有序；替换时旧条目正确移除；6h 驱逐边界 |
| `tieredCost` | 恰好 200K / 超出 / `above` 为 nil 时不分段 |
| Cost | `cache_creation` 对象存在时忽略扁平字段；1h 单价 = `input × 2.0`；fast 倍率 |
| 模型名解析 | `claude-haiku-4-5` 命中 `...-20251001`；`claude-opus-4` **不**命中 `claude-opus-4-5`；`.`/`@` 归一化；未命中返回 0 |
| CodexAdapter | `cached` 减法；`total_tokens` 直取；`reasoning` 不重复加 |
| `GaugeScale` | 每种 scale 的映射表 + 共用的 clamp 断言 |

### Golden fixture

以本机真实数据的四个 session block 作为端到端校验基准，Swift 实现必须算出相同数字：

| 块起点 | 条数 | 时长 | tok/min (Total) | indicator | 档位 |
|---|---|---|---|---|---|
| 07-12 05:00 | 89 | 257 min | 41,080 | 762 | Normal |
| 07-21 11:00 | 2 | ~0 | — | — | duration≤0 → 无速率 |
| 07-25 02:00 | 716 | 281 min | 299,509 | 1,940 | Normal |
| 07-25 07:00 | 392 | 51 min | 760,582 | 3,908 | Moderate |

> 该表由分析脚本在 2026-07-25 生成，其中活跃块会随时间继续累积。实施时应先固化一份脱敏的 JSONL fixture（仅保留 timestamp / message.id / requestId / isSidechain / usage 字段，剔除对话内容），基于该固定快照重新生成期望值并纳入版本控制，避免测试随本机数据漂移。

### 交叉验证

条件允许时以 `npx ccusage@20 blocks --active` 的输出直接对比 Claude 侧数值。这是"数据上与 ccusage 一致"这一宗旨的最终验收标准。

## 10. 常量汇总

```
SESSION_DURATION_HOURS              = 5
WINDOW_RETENTION_HOURS              = 6        （本项目，偏离 D4）
IDLE_TIMEOUT_SECONDS                = 90       （本项目，偏离 D1）
RECOMPUTE_INTERVAL_SECONDS          = 2
TAIL_PROBE_BYTES                    = 8192     （本项目）

BURN_RATE_THRESHOLD_MODERATE        = 2000     （对 indicator）
BURN_RATE_THRESHOLD_HIGH            = 5000     （对 indicator）

CACHE_CREATE_1H_INPUT_MULTIPLIER    = 2.0
DEFAULT_LONG_CONTEXT_THRESHOLD      = 200_000
OPENAI_LONG_CONTEXT_THRESHOLD       = 272_000
CACHE_CREATE_DEFAULT_MULTIPLIER     = 1.25     （input × 1.25）
CACHE_READ_DEFAULT_MULTIPLIER       = 0.1      （input × 0.1）
MODEL_DATE_SUFFIX_DIGITS            = 8
PRICING_FETCH_TIMEOUT_SECONDS       = 10
PRICING_CACHE_TTL_HOURS             = 24       （本项目，偏离 D2）

GAUGE_COLOR_YELLOW_FRACTION         = 0.60     （本项目）
GAUGE_COLOR_RED_FRACTION            = 0.85     （本项目）
```

## 11. 文档更新

`docs/collector.md` 第 4 节「速率聚合」整节需重写：现有内容描述 60 秒滑窗与 `effectiveTokens`，改造后全部失效。同时补充 session block 模型、去重语义与偏离清单。
