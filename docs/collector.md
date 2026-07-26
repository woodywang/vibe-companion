# 采集器原理

## 数据源

客户端监听本机 AI 编程工具的 JSONL 会话文件。无需特殊权限（用户主目录下）。

### Claude Code

- **根目录**：`$CLAUDE_CONFIG_DIR`（逗号分隔，展开 `~`）；未设置时用 `${XDG_CONFIG_HOME:-~/.config}/claude` 与 `~/.claude`
- **文件发现**：每个根目录下须存在 `projects/` 子目录，**递归**枚举其下全部 `*.jsonl`（解析符号链接后按真实路径去重）。目录名是 cwd 的编码形式（`/` 换成 `-`），但适配器不依赖这个约定，只按扩展名收集。
- **有效行**：先做廉价前置过滤（整行含 `"usage"`），再要求同时具备 `timestamp`、`message`、`message.usage`。
  **不检查 `type` 字段**——这是刻意的（对齐 ccusage）：用量不止出现在 `type: "assistant"` 的行上，认 `type` 会漏数据。
- **token 字段**：`message.usage` 下的
  - `input_tokens`、`output_tokens`、`cache_read_input_tokens`
  - 缓存写入拆 **5m / 1h 两档**：
    - 存在 `cache_creation` 对象时取 `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`，**并忽略**扁平的 `cache_creation_input_tokens`
    - 否则扁平字段全部计入 5m 档，1h 档记 0
  - 必须拆开的原因是计价：1h 档按 `input 单价 × 2.0` 计费，5m 档按 `cache_creation` 单价，合并就算错钱（计数场景两者等价，见 `TokenCounts.cacheCreationTotal`）
- **其他字段**：`sessionId`、`message.model`、`timestamp`（ISO8601）、`isSidechain`（参与去重优先级）、`usage.speed`（值为 `"fast"` 时套用模型的 fast 倍率）
- **去重键**：`message.id` + `:` + `requestId`（详见第 3 节）。**不是**行内 `uuid`——一次响应会写成多行，各行 `uuid` 不同而 messageId/requestId 相同。

### OpenAI Codex CLI

- **根目录**：`$CODEX_HOME`（逗号分隔，**不**展开 `~`——对齐 ccusage）；未设置时用 `~/.codex`
- **文件发现**：递归枚举 `sessions/**/*.jsonl` 与 `archived_sessions/**/*.jsonl`。
  **没有 `rollout-*` 前缀过滤**，这同样是刻意的（对齐 ccusage）——文件名形如 `rollout-<ts>-<uuid>.jsonl`，但按前缀过滤会漏掉命名不同的文件。
- **有效行**：`type == "event_msg"` 且 `payload.type == "token_count"`。
  另有 `type == "turn_context"` 的行只用来更新 sticky model，本身不产出 entry；sticky model 按**文件**隔离（`Collector` 的 `contextByFile`）。
- **token 字段**：`payload.info.last_token_usage` 下的 `input_tokens`、`cached_input_tokens`、`output_tokens`、`reasoning_output_tokens`、`total_tokens`，映射规则：

  ```
  cached   = min(cached_input_tokens, input_tokens)   # cached 嵌套在 input 内，先 clamp
  input    = input_tokens - cached                    # 再相减，否则 cached 被重复计算
  cacheRead = cached
  output   = output_tokens
  cacheCreation5m/1h = 0                              # Codex 无缓存写入概念
  total    = total_tokens                             # 直取文件值，不重算
  extraTotal = max(0, total - (input + cached + output))
  ```

  `reasoning_output_tokens` **不单独计入**——它已包含在 `output_tokens` 内。
- **model**：来自 sticky model，行内不带。
- **去重键**：`timestamp|model|input_tokens|cached_input_tokens|output_tokens|reasoning|total` 的拼接，**刻意不含 sessionId**（对齐 ccusage：同一回合可能被写进多个 session 文件，含 sessionId 就去不掉重）。

### Cursor（不支持）

本地无 token 数据存储（仅行数/模型名），需走其私有 API 或网络拦截，MVP 不支持。

## 工作机制

```
JsonlTailer ──(新增行)──> Collector ──(UsageEntry)──> TokenAggregator (速率) ──> 速度表 / 菜单栏
```

`Collector` 本身不认识任何 JSONL 格式：解析全部下沉到 `AgentAdapter` 实现，它只负责调度、决定每个文件是否回扫、并按文件维护解析上下文。

### 1. 文件发现与监听

- `Collector.start()` **立即返回**：首轮扫描与之后每 10 秒的周期扫描都派到后台串行队列 `vibe.collector.scan` 上。
  这是必须的——回扫要 probe 上百个文件再整文件读一遍，本机实测 150 个会话文件共 59 MB，放在主线程上就是菜单栏图标出现前的几百毫秒卡顿。
- 每轮扫描调用各 adapter 的 `discoverFiles()`，新出现的文件先登记进 `ownerByFile` / `contextByFile`，再交给 `JsonlTailer` 监听。
- `JsonlTailer` 用 `DispatchSource.makeFileSystemObjectSource`（FSEvents）监听文件写入。
- **锁序**：`ownerByFile` / `contextByFile` 由 `mapsLock` 保护，而 `tailer.watch` 内部 `queue.sync` 进 tailer 队列、`handle()` 又是从那条队列上被回调并获取 `mapsLock` 的。
  因此扫描**必须在释放 `mapsLock` 之后**才调用 `watch`——两条路径都保持 tailer-queue → mapsLock 的单一顺序，任何反转都会构成循环等待死锁。

### 2. Offset 游标

- 每个 tail 的文件维护一个 `byte_offset`。
- **首次定位由回扫判定决定**（本分支的主要改动，此前是无条件定位到 EOF）：
  - `TailProbe` 只读文件**尾部 8 KB**，反向找出末条完整 JSON 行并取其 timestamp
  - 落在回扫窗口（默认 6 小时，`AppConfig.backfillWindowHours`）内 → offset 置 0，**从头回扫全文**
  - 落在窗口外 → offset 置 EOF，只看后续新增
  - 探测或时间戳解析的任何一步失败 → 一律回扫。宁可多读，不可漏数据。
- 监听到写入事件后，`lseek` 到上次 offset，分块（256 KB）循环读到末尾，按 `\n` 拆行。
  单次 `read(2)` 不保证返回请求的全部字节，按单次读取量之外的值推进 offset 会静默丢数据；`EINTR` 原地重试而非放弃——回扫历史文件时那一次同步读取是唯一时机（`DispatchSource` 只在 `.write` 时才触发）。
- 拆不成完整行的尾部字节（半行，或被截断的多字节 UTF-8 字符）留作 partial，与下一批拼接。
- **轮转检测**：若 `currentSize < offset`（文件被截断/轮转），重置 offset 为 0 并丢弃 partial。

### 3. 速率聚合

采用 ccusage v20 的 **session block burn rate** 算法（参考 `rust/crates/ccusage/src/blocks.rs`）。

- `UsageWindow` 维护最近 **6 小时**的原始 entry，按 **entry 自身的 timestamp**（不是到达时间）有序插入。
- 去重键是 `messageId:requestId`（**不是**行内 `uuid`），且为**替换**语义：非 sidechain > token 总量大 > 带 speed 字段。实测去重掉约 56% 的行。
- 每 2 秒把窗口快照切成 **5 小时计费块**：起点 floor 到 UTC 整点；`距块起点 > 5h` 或 `距上条 > 5h` 开新块（均为严格大于），后者额外插入 gap 伪块。
- 活跃块的 burn rate = `TokenCounts.total ÷ (末条 entry − 首条 entry)` 分钟数。**Total 含 cache_read**。空闲时冻结（分母不含空闲时间），与 ccusage 一致。
- 另有 `tokensPerMinuteForIndicator`（仅 input + output），按阈值 2000/5000 映射为 Normal/Moderate/High，显示在菜单栏。
- cost 按 entry 逐条计价后求和；定价来自内置 LiteLLM 快照 → 硬编码覆盖 → 磁盘缓存(24h) → 线上抓取。
- 以上全部只喂菜单栏，**未经任何加工**。

#### 3b. 瞬时速率（表盘专用，非 ccusage 口径）

区块速率是全程平均，实测块启动 5 分钟后相邻更新中位跳变仅 0.04%——指针对新 prompt 毫无反应。表盘因此另走一条时间衰减 EMA（`Core/InstantRate.swift`）：

- 经过 Δt 秒先衰减 `value *= exp(-Δt / τ)`，摄入一条 `v` tokens 的记录则 `value += v / τ * 60`。稳态下恒定流量 F tok/min 收敛到 F。
- 喂入的是每条记录的 `counts.total`（与表盘既有口径一致，含 cache_read），且**只喂去重后被接受的记录**。
- 时刻取 **entry 自身的 timestamp** 而非到达时间——否则回扫 6 小时的历史会在一瞬间全部砸进 EMA 把指针顶死。乱序/迟到的时间戳只计入、不倒表。
- τ 由用户在设置中选（15 / 30 / 60 / 120 秒，默认 30 秒），改档立即生效并保留当前读数。
- 自适应量程的 `recentPeak` 跟的也是它——量程上限必须与指针同源。

#### 与 ccusage 的偏离

| 项 | ccusage | 本实现 | 理由 |
|---|---|---|---|
| 表盘取值 | 只有区块速率 | 表盘走瞬时 EMA；菜单栏为纯 ccusage 行为 | 速度表该显示当前速度而非全程平均 |
| 定价缓存 | 无磁盘缓存 | 磁盘缓存 TTL 24h | 桌面应用频繁重启 |
| indicator 用途 | 驱动配色徽章 | 菜单栏文字 | 表盘配色与指针角度须同源 |
| 内存范围 | 全量读入 | 仅最近 6 小时 | 常驻进程不能无界增长 |
| cost 模式 | auto/calculate/display | 固定 calculate | JSONL 中无 `costUSD` 字段 |

以上偏离均**不改变菜单栏的数值**——菜单栏的速率/档位/花费/今日累计与 `ccusage blocks` 一致。表盘是另一个量（瞬时速率），见 3b。

速度表量程（对数 10k–10M 默认 / 线性 0–10M / 自适应）由用户在设置中选择，与算法完全解耦。

## 延迟特性

- 监听到写入的延迟：毫秒级（FSEvents）。
- 但一条 JSONL 行只在「AI 回合完成」时写入，所以拿到的是**每回合**的 token 用量，而非请求中的流式 token。
- 实际体感：用户看到 AI 回复结束后，宠物几乎立即加速。

## 参考实现

`ccusage`（`npx ccusage`）是同类工具，解析相同的 JSONL 文件。本实现回扫最近 6 小时的历史以热启动，之后转为增量 tail；与全量重扫的偏离在于回扫范围有界且后续转增量，这使其适合常驻低开销运行。
