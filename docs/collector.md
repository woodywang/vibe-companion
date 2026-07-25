# 采集器原理

## 数据源

客户端监听本机 AI 编程工具的 JSONL 会话文件。无需特殊权限（用户主目录下）。

### Claude Code

- **路径**：`~/.claude/projects/<encoded-cwd>/*.jsonl`
- **路径编码**：cwd 中的 `/` 被替换为 `-`，例如 `/Users/woody` -> `-Users-woody`
- **有效行**：`type: "assistant"` 的 JSON 记录
- **token 字段**：`message.usage` 下的
  - `input_tokens`
  - `output_tokens`
  - `cache_creation_input_tokens`
  - `cache_read_input_tokens`
- **其他字段**：`uuid`（去重键）、`sessionId`、`message.model`、`timestamp`（ISO8601）

### OpenAI Codex CLI

- **路径**：`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`
- **有效行**：`payload.type == "token_count"` 的 JSON 记录
- **token 字段**：`payload.info.last_token_usage` 下的
  - `input_tokens`
  - `cached_input_tokens`（cache read）
  - `output_tokens`
  - `reasoning_output_tokens`
  - `total_tokens`
- **去重键**：`sessionId + timestamp`（Codex 没有唯一 uuid 字段）

### Cursor（不支持）

本地无 token 数据存储（仅行数/模型名），需走其私有 API 或网络拦截，MVP 不支持。

## 工作机制

```
JsonlTailer ──(新增行)──> Collector ──(UsageEvent)──> TokenAggregator (速率) ──> 速度表 / 菜单栏
```

### 1. 文件发现与监听

- `Collector.start()` 每 10 秒重新扫描两个目录，发现新 session 文件即开始监听。
- `JsonlTailer` 用 `DispatchSource.makeFileSystemObjectSource`（FSEvents）监听文件写入。

### 2. Offset 游标

- 每个 tail 的文件维护一个 `byte_offset`。
- **首次定位到 EOF**：不回溯历史用量，只统计 App 启动后的新增。
- 监听到写入事件后，`lseek` 到上次 offset，读取增量，按 `\n` 拆行。
- **轮转检测**：若 `currentSize < offset`（文件被截断/轮转），重置 offset 为 0。

### 3. 速率聚合

采用 ccusage v20 的 **session block burn rate** 算法（参考 `rust/crates/ccusage/src/blocks.rs`）。

- `UsageWindow` 维护最近 **6 小时**的原始 entry，按 **entry 自身的 timestamp**（不是到达时间）有序插入。
- 去重键是 `messageId:requestId`（**不是**行内 `uuid`），且为**替换**语义：非 sidechain > token 总量大 > 带 speed 字段。实测去重掉约 56% 的行。
- 每 2 秒把窗口快照切成 **5 小时计费块**：起点 floor 到 UTC 整点；`距块起点 > 5h` 或 `距上条 > 5h` 开新块（均为严格大于），后者额外插入 gap 伪块。
- 活跃块的 burn rate = `TokenCounts.total ÷ (末条 entry − 首条 entry)` 分钟数。**Total 含 cache_read**。
- 另有 `tokensPerMinuteForIndicator`（仅 input + output），按阈值 2000/5000 映射为 Normal/Moderate/High，显示在菜单栏。
- cost 按 entry 逐条计价后求和；定价来自内置 LiteLLM 快照 → 硬编码覆盖 → 磁盘缓存(24h) → 线上抓取。

#### 与 ccusage 的偏离

| 项 | ccusage | 本实现 | 理由 |
|---|---|---|---|
| 空闲 | 速率冻结至块失活 | 距末条 entry > 90s 归零 | 常驻仪表需要"熄火"反馈 |
| 定价缓存 | 无磁盘缓存 | 磁盘缓存 TTL 24h | 桌面应用频繁重启 |
| indicator 用途 | 驱动配色徽章 | 菜单栏文字 | 表盘配色与指针角度须同源 |
| 内存范围 | 全量读入 | 仅最近 6 小时 | 常驻进程不能无界增长 |
| cost 模式 | auto/calculate/display | 固定 calculate | JSONL 中无 `costUSD` 字段 |

以上偏离均**不改变数值**。速度表量程（线性/对数/自适应）由用户在设置中选择，与算法完全解耦。

## 延迟特性

- 监听到写入的延迟：毫秒级（FSEvents）。
- 但一条 JSONL 行只在「AI 回合完成」时写入，所以拿到的是**每回合**的 token 用量，而非请求中的流式 token。
- 实际体感：用户看到 AI 回复结束后，宠物几乎立即加速。

## 参考实现

`ccusage`（`npx ccusage`）是同类工具，解析相同的 JSONL 文件。本实现回扫最近 6 小时的历史以热启动，之后转为增量 tail；与全量重扫的偏离在于回扫范围有界且后续转增量，这使其适合常驻低开销运行。
