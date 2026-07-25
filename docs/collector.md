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
JsonlTailer ──(新增行)──> Collector ──(UsageEvent)──> TokenAggregator (速率)
                                              └──────> UsageStore (SQLite 队列) ──> Uploader ──> 后端
```

### 1. 文件发现与监听

- `Collector.start()` 每 10 秒重新扫描两个目录，发现新 session 文件即开始监听。
- `JsonlTailer` 用 `DispatchSource.makeFileSystemObjectSource`（FSEvents）监听文件写入。

### 2. Offset 游标

- 每个 tail 的文件维护一个 `byte_offset`。
- **首次定位到 EOF**：不回溯历史用量，只统计 App 启动后的新增。
- 监听到写入事件后，`lseek` 到上次 offset，读取增量，按 `\n` 拆行。
- **轮转检测**：若 `currentSize < offset`（文件被截断/轮转），重置 offset 为 0。

### 3. 去重

- **本地**：`UsageStore.enqueue` 按 `source_uuid` 去重（SQLite `COUNT` 检查）。
- **服务端**：`usage_events` 表 `UNIQUE(client_id, source_uuid)` 约束，重复上传返回 `duplicates` 计数而非报错。
- 双层去重保证：客户端崩溃重试、网络重传都不会产生重复数据。

### 4. 速率聚合

- `TokenAggregator` 维护 60 秒滑动窗口（`[Sample(timestamp, tokens)]`）。
- 每 2 秒清理过期样本并重算 `tokensPerMinute = Σ window.tokens`。
- 该值驱动悬浮宠物窗（纯 SwiftUI `Canvas` 绘制，见 `CyclingPetView.swift`）的轮子转速 `CyclingPet.revolutionsPerSecond(speed:)`：
  - 0 -> 打盹状态（静态 😴）
  - 8000 tokens/min -> 1.0x 标准速度（1 圈/秒）
  - 范围 clamp 在 [0.25, 4.0] 圈/秒

### 5. 上传

- `Uploader` 每 20 秒或缓冲达 50 条时触发。
- `fetchPending` 取一批并原子标记为 `uploading`（防止并发重复取）。
- 成功 -> 删除；失败 -> 回退 `pending` 并 `attempts+1`。
- 离线时数据持续在本地 SQLite 累积，联网后自动补传。

## 延迟特性

- 监听到写入的延迟：毫秒级（FSEvents）。
- 但一条 JSONL 行只在「AI 回合完成」时写入，所以拿到的是**每回合**的 token 用量，而非请求中的流式 token。
- 实际体感：用户看到 AI 回复结束后，宠物几乎立即加速。

## 参考实现

`ccusage`（`npx ccusage`）是同类工具，解析相同的 JSONL 文件，但它是「全量重扫」模式，无增量游标。本采集器的增量 tail 设计使其适合常驻低开销运行。
