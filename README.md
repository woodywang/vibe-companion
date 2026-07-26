# Vibe Companion

macOS 菜单栏 App，实时显示 AI 编程的 token 消耗速率。

悬浮的老式汽车速度表随 Claude Code / Codex CLI 的实时用量转动指针，读数为 tokens/min。

> **表盘与菜单栏是两个不同的量，别弄混：**
> - **表盘**显示的是**瞬时**速率（时间衰减 EMA），**不等于 `ccusage blocks` 的输出**。它是为了让指针即时响应而设计的——你刚发出一个大 prompt，指针就该动。
> - **菜单栏**的速率、档位、估算花费与今日累计才是 ccusage 口径，与 `ccusage blocks` 数值一致。

菜单栏那一侧的算法是 [ccusage](https://github.com/ccusage/ccusage) 的完整复刻——同样的 5 小时会话区块、同样的去重语义、同样的分层计价。

**纯本地应用：不联网、不上传任何数据、无第三方依赖。** 唯一的网络行为是可选地拉取 LiteLLM 公开定价表用于估算花费，失败时回退到内置快照，且完全不影响速率显示。

## 仓库结构

```
vibe-companion/
├── Package.swift          # SwiftPM 清单
├── VibeCompanion/
│   ├── Sources/
│   │   ├── App/           # 菜单栏与生命周期协调
│   │   ├── Collectors/    # 日志发现、增量 tail、各 agent 的解析适配器
│   │   ├── Core/          # 速率算法、定价与成本（无 I/O，可纯函数测试）
│   │   ├── Overlay/       # 悬浮速度表
│   │   ├── Settings/      # 设置界面
│   │   └── Resources/     # 内置 LiteLLM 定价快照
│   └── Tests/             # XCTest，287 个用例
├── scripts/build-app.sh   # 打包成 .app
└── docs/                  # 设计与原理文档
```

## 快速开始

```bash
# 若 xcode-select 指向 CommandLineTools，需先指定 Xcode（否则找不到 XCTest）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build              # 编译
swift test               # 单元测试
./scripts/build-app.sh   # 打包成 .app（debug；传 release 打发布版）
open .build/app/VibeCompanion.app
```

需要 macOS 13+ 与 Swift 5.9。

## 数据源

| 工具 | 支持 | 日志位置 |
|---|---|---|
| Claude Code | ✅ | `$CLAUDE_CONFIG_DIR`，否则 `~/.claude` 与 `${XDG_CONFIG_HOME:-~/.config}/claude`，取其下 `projects/**/*.jsonl` |
| OpenAI Codex CLI | ✅ | `$CODEX_HOME`，否则 `~/.codex`，取其下 `sessions/**` 与 `archived_sessions/**` 的 `*.jsonl` |
| Cursor | ❌ | 本地无 token 数据 |

启动时按「尾部探测」筛出最近 6 小时内有活动的文件并回扫，之后增量 tail。解析细节见 [`docs/collector.md`](docs/collector.md)。

## 速率是怎么算的

### 菜单栏：ccusage 口径

与 ccusage 一致，未经任何加工：

- **5 小时会话区块**——按计费窗口切分，块起点向下取整到 UTC 整点；静默超过 5 小时则断块。
- **替换语义去重**——键为 `messageId:requestId`，重复条目按「非 sidechain 优先 > token 更多优先」覆盖而非跳过。这一条实测会让同一区块算出 439k 还是 760k 的差别。
- **速率 = 区块内 token 总量 ÷（末条 − 首条）分钟数**，Total 口径（含 cache_read）。档位行另给 input+output 口径，即 ccusage 判定 Normal/Moderate/High 的依据，两者相差十几倍属正常。
- **空闲时速率冻结**（分母是「末条 − 首条」，空闲不稀释），这也是 ccusage 的行为。
- **成本**按 LiteLLM 单价逐条计算再聚合，覆盖 200K 分档、1 小时缓存倍率与块内多模型混合。

对本机真实数据的三个已结束区块，成本与 `ccusage blocks` 逐位相同。

### 表盘：瞬时速率（**不是** ccusage 的值）

区块速率是**全程平均**，极其平稳——块启动 5 分钟后相邻更新的中位跳变只有 0.04%。作为账单口径这是对的，但速度表本该显示**当前速度**。

表盘因此走一条独立的时间衰减 EMA（与 Unix load average 同款，单位直接是 tok/min）：

```
经过 Δt 秒：value *= exp(-Δt / τ)
摄入 v tokens：value += v / τ * 60
```

稳态性质：以恒定流量 F tok/min 持续喂入，读数收敛到 F。停手后按 τ 自然衰减回零，「熄火」是衰减出来的，不靠任何超时归零补丁。

τ 可在设置中选（15 / 30 / 60 / 120 秒，默认 30 秒）：越小越跳、反馈越快，越大越稳、响应越慢。

## 界面

- **悬浮速度表**：指针角度、LCD 读数、表盘配色同源于**瞬时**速率。配色按指针行程比例（角度）判定而非数值比例，所以颜色与指针位置在任何量程下都一致。
- **量程可选**（设置中切换）：对数 10k–10M（**默认**）/ 线性 0–10M / 自适应（跟随近期峰值，按 5 分钟半衰期衰减）。实测瞬时速率跨三个数量级——中位 613k、p90 1.71M、p99 6.02M、峰值 8.35M tokens/min——线性量程下中位值只占 7.3% 行程，指针几乎贴底，故默认取对数。
- **菜单栏**：当前速率（ccusage 区块口径）、ccusage 档位、估算花费（$/h）、今日累计、暂停开关。

## 数据留存

用量数据只存在内存中，仅保留最近 6 小时，App 退出即清空。落盘的只有两样：用户设置（`UserDefaults`）与定价缓存（`~/Library/Application Support/VibeCompanion/pricing-cache.json`）。

## 文档

- [`docs/architecture.md`](docs/architecture.md) — 模块划分与数据流
- [`docs/collector.md`](docs/collector.md) — 采集与解析细节
- [`docs/client-build.md`](docs/client-build.md) — 构建与打包
- [`docs/superpowers/specs/`](docs/superpowers/specs/) — ccusage 复刻的设计规格与偏离说明
