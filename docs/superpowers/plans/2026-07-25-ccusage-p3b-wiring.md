# P3b 采集层接线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把适配器、有界窗口、分块算法与定价接成一条完整链路，让速度表显示与 ccusage 一致的 burn rate。

**Architecture:** `Collector` 退化为 adapter 调度器并承担回扫决策；`TokenAggregator` 从 60s 滑窗改写为 `UsageWindow` + 每 2s 分块重算。完成后 app 行为真正改变。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest / macOS 13+

依赖：P1 全部、P2 全部、P3 Task 1–4。
设计文档：`docs/superpowers/specs/2026-07-25-ccusage-burnrate-design.md`

## Global Constraints

- **测试命令必须带 `DEVELOPER_DIR`**：`cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`
- **`Core/` 仍不得触碰 I/O。**
- 涉及文件系统的测试用 `FileManager.default.temporaryDirectory` 下的唯一子目录并在 `tearDown` 清理；**禁止读写 `~/.claude` 或 `~/.codex`**。
- **数值必须与 ccusage 一致。**
- 提交信息用中文，结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 5: Collector 改为 adapter 调度

**Files:**
- Modify: `client/VibeCompanion/Sources/Collectors/Collector.swift`（整体重写）
- Delete: `client/VibeCompanion/Sources/Collectors/DataSource.swift`（职责已移入两个 adapter）
- Test: `client/VibeCompanion/Tests/CollectorTests.swift`
- Delete: `client/VibeCompanion/Tests/ParserTests.swift`（其覆盖的 `ClaudeParser`/`CodexParser` 已被 adapter 取代，等价用例已在 `ClaudeAdapterTests`/`CodexAdapterTests` 中）

**Interfaces:**
- Consumes: `AgentAdapter`（P3 Task 1）、`ClaudeAdapter`、`CodexAdapter`、`TailProbe`、`JsonlTailer.watch(_:startAtBeginning:)`
- Produces: `final class Collector` — `init(adapters: [AgentAdapter], backfillWindowHours: Double = 6, now: @escaping () -> Date = { Date() })`、`var onEntry: ((UsageEntry) -> Void)?`、`func start()`、`func stop()`、`func shouldBackfill(_ url: URL, adapter: AgentAdapter) -> Bool`

**背景：** 回扫决策是本任务的核心。对每个新发现的文件用 `TailProbe` 读末条完整行、交给 adapter 提时间戳：落在回扫窗口内则 `startAtBeginning: true`，否则 `false`。**任何一步失败都按"需回扫"处理**——宁可多读，不可漏数据。

`ParseContext` 需按文件保存：Codex 的 sticky model 在同一文件的行之间传递，跨文件不得串味。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/CollectorTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class CollectorTests: XCTestCase {

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 一个可控的假 adapter：文件列表与时间戳解析都由测试指定
    private struct FakeAdapter: AgentAdapter {
        let id = "fake"
        var files: [URL] = []
        var timestampByLine: [String: Date] = [:]
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? { nil }
        func timestamp(fromLine line: String) -> Date? { timestampByLine[line] }
    }

    private func write(_ contents: String, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collector(_ adapter: AgentAdapter) -> Collector {
        Collector(adapters: [adapter], backfillWindowHours: 6, now: { self.now })
    }

    func testBackfillsWhenLastEntryInsideWindow() throws {
        let url = try write("old\nrecent\n", name: "a.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["recent": now.addingTimeInterval(-3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testSkipsBackfillWhenLastEntryOutsideWindow() throws {
        let url = try write("old\nancient\n", name: "b.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["ancient": now.addingTimeInterval(-10 * 3600)])
        XCTAssertFalse(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsAtExactWindowBoundary() throws {
        let url = try write("x\nedge\n", name: "c.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["edge": now.addingTimeInterval(-6 * 3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 时间戳解析失败 -> 保守回扫
    func testBackfillsWhenTimestampUnparseable() throws {
        let url = try write("x\nunknown\n", name: "d.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 探测不到完整行（空文件）-> 保守回扫
    func testBackfillsWhenProbeFindsNothing() throws {
        let url = try write("", name: "e.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsWhenFileMissing() {
        let url = dir.appendingPathComponent("nope.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 端到端：回扫真实 Claude 行并产出 entry
    func testStartEmitsEntriesFromBackfilledFile() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5}}}
        """
        let url = try write(line + "\n", name: "claude.jsonl")
        let adapter = ClaudeAdapter(roots: [])

        // 直接驱动 tailer 路径：用真实 ClaudeAdapter 但把文件列表固定住
        // now 取 entry 之后 1 小时（entry 是 2026-07-25T07:00:00Z == 1784962800）
        let c = Collector(adapters: [FixedFileAdapter(inner: adapter, files: [url])],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })
        var got: [UsageEntry] = []
        let done = expectation(description: "entry")
        done.assertForOverFulfill = false
        c.onEntry = { got.append($0); done.fulfill() }
        c.start()
        wait(for: [done], timeout: 3)
        c.stop()

        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].counts.input, 10)
        XCTAssertEqual(got[0].dedupKey, "m1:r1")
    }

    /// 包装器：复用真实 adapter 的解析，但固定文件列表
    private struct FixedFileAdapter: AgentAdapter {
        let inner: AgentAdapter
        let files: [URL]
        var id: String { inner.id }
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? {
            inner.parse(line: line, context: &context)
        }
        func timestamp(fromLine line: String) -> Date? { inner.timestamp(fromLine: line) }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CollectorTests
```

Expected: 编译失败——`Collector` 无 `init(adapters:backfillWindowHours:now:)`。

- [ ] **Step 3: 重写 Collector**

把 `client/VibeCompanion/Sources/Collectors/Collector.swift` 整体替换为：

```swift
import Foundation

/// 采集器：调度各 agent 适配器，把它们的 session 文件接到 JsonlTailer 上，
/// 并决定每个文件是否需要回扫历史。
///
/// 解析细节全部下沉到 `AgentAdapter` 实现，本类不认识任何 JSONL 格式。
final class Collector {
    /// 解析出一条用量记录时回调。
    var onEntry: ((UsageEntry) -> Void)?

    private let adapters: [AgentAdapter]
    private let backfillWindow: TimeInterval
    private let now: () -> Date

    private let tailer = JsonlTailer()
    /// 文件 -> 负责它的 adapter
    private var ownerByFile: [URL: AgentAdapter] = [:]
    /// 文件 -> 解析上下文（Codex 的 sticky model 按文件隔离）
    private var contextByFile: [URL: ParseContext] = [:]
    private var rescanTimer: Timer?

    init(adapters: [AgentAdapter] = [ClaudeAdapter(), CodexAdapter()],
         backfillWindowHours: Double = 6,
         now: @escaping () -> Date = { Date() }) {
        self.adapters = adapters
        self.backfillWindow = backfillWindowHours * 3600
        self.now = now
    }

    func start() {
        tailer.onLine = { [weak self] url, line in
            self?.handle(url: url, line: line)
        }
        rescan()
        // 每 10s 重新扫描，捕获新创建的 session 文件
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        tailer.stopAll()
    }

    /// 该文件是否需要从头回扫。
    ///
    /// 判据是文件**末条记录**的时间戳是否落在回扫窗口内——用 `TailProbe`
    /// 只读 8 KB 尾部即可判定，无需读全文。
    /// 探测或解析的任何一步失败都返回 true：宁可多读，不可漏数据。
    func shouldBackfill(_ url: URL, adapter: AgentAdapter) -> Bool {
        guard let line = TailProbe.lastCompleteLine(of: url),
              let ts = adapter.timestamp(fromLine: line)
        else { return true }
        return now().timeIntervalSince(ts) <= backfillWindow
    }

    // MARK: - private

    private func rescan() {
        for adapter in adapters {
            for file in adapter.discoverFiles() where ownerByFile[file] == nil {
                ownerByFile[file] = adapter
                contextByFile[file] = ParseContext()
                tailer.watch(file, startAtBeginning: shouldBackfill(file, adapter: adapter))
            }
        }
    }

    private func handle(url: URL, line: String) {
        guard let adapter = ownerByFile[url] else { return }
        var context = contextByFile[url] ?? ParseContext()
        let entry = adapter.parse(line: line, context: &context)
        contextByFile[url] = context
        if let entry { onEntry?(entry) }
    }
}
```

- [ ] **Step 4: 删除被取代的文件**

```bash
git rm client/VibeCompanion/Sources/Collectors/DataSource.swift
git rm client/VibeCompanion/Tests/ParserTests.swift
```

`DataSource` 的路径发现职责已移入两个 adapter，且 adapter 版本更完整（支持 `CLAUDE_CONFIG_DIR` / `XDG_CONFIG_HOME` / `CODEX_HOME` 与 `archived_sessions`）。`ParserTests` 覆盖的 `ClaudeParser`/`CodexParser` 已随本次重写消失，其用例在 `ClaudeAdapterTests`/`CodexAdapterTests` 中均有等价覆盖且更严格。

- [ ] **Step 5: 修复 AppCoordinator 的调用点**

`client/VibeCompanion/Sources/App/VibeCompanionApp.swift:49` 用的是 `c.onEvent`，需改为 `c.onEntry`。把 `start()` 中的这一段：

```swift
        let c = Collector()
        c.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.aggregator.ingest(event)
            }
        }
```

改为：

```swift
        let c = Collector()
        c.onEntry = { [weak self] entry in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.aggregator.ingest(entry)
            }
        }
```

（`aggregator.ingest` 的参数类型将在 Task 6 变为 `UsageEntry`；此刻可能暂时不编译，Task 6 完成后恢复。若希望本任务独立可编译，先把 `TokenAggregator.ingest` 的签名改为接收 `UsageEntry` 并在内部只更新 `todayTotal`，Task 6 再补齐。）

- [ ] **Step 6: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CollectorTests
```

Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 7: 提交**

```bash
git add -A client/VibeCompanion
git commit -m "$(cat <<'EOF'
refactor(collectors): Collector 改为 adapter 调度

解析细节下沉到 AgentAdapter，Collector 只负责调度与回扫决策；
回扫判据是 TailProbe 读出的末条记录时间戳，任何一步失败都保守回扫。
ParseContext 按文件隔离，避免 Codex sticky model 跨文件串味。
删除 DataSource 与 ParserTests（职责与覆盖已被 adapter 取代）。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: TokenAggregator 重写

**Files:**
- Create: `client/VibeCompanion/Sources/Core/SessionBlockCost.swift`
- Modify: `client/VibeCompanion/Sources/Core/TokenAggregator.swift`（整体重写）
- Modify: `client/VibeCompanion/Sources/Core/Models.swift`（删除 `UsageEvent`）
- Modify: `client/VibeCompanion/Sources/Core/AppConfig.swift`（常量替换）
- Modify: `client/VibeCompanion/Tests/TokenAggregatorTests.swift`（重写）

**Interfaces:**
- Consumes: `UsageWindow`、`identifySessionBlocks`、`calculateBurnRate`、`BurnRateLevel`（P1）；`PricingSource`、`calculateCost`（P2）
- Produces:
  - `extension SessionBlock { func withCostUSD(_ cost: Double?) -> SessionBlock }`
  - `func blockCostUSD(_ block: SessionBlock, source: PricingSource) -> Double?`
  - `@MainActor final class TokenAggregator: ObservableObject` — `init(pricing: PricingSource?, retentionHours: Double = 6, idleTimeoutSeconds: TimeInterval = 90, now: @escaping () -> Date = { Date() })`；`func ingest(_ entry: UsageEntry)`；`func recompute()`；发布 `tokensPerMinute: Double`、`indicatorTokensPerMinute: Double`、`level: BurnRateLevel`、`costPerHour: Double?`、`hasBurnRate: Bool`、`isIdle: Bool`、`todayTotal: Int`、`recentPeak: Double`

**背景（三个关键决策）：**

1. **窗口用 entry 自身的 timestamp，不是到达时间。** 现有实现（`TokenAggregator.swift:34-36`）用 `now()` 建窗，改造后回扫进来的历史数据会被当成"此刻发生"，分块彻底错乱。
2. **今日累计改用第二个 24h 窗口。** 主窗口只保留 6h，装不下一整天；而按 ingest 累加会因去重替换语义重复计数。复用 `UsageWindow`（保留 25h）并在每次重算时按日期过滤求和，去重逻辑自动生效。
3. **cost 按 entry 逐条计算后求和。** 不可用 block 聚合后的 `TokenCounts` 一次性算——200K 分段按单次请求判定、`fastMultiplier` 是 per-entry 的、一个 block 内可能混用多个模型（实测本机 opus-5 / sonnet-5 / opus-4-8 / haiku-4-5 并存）。

- [ ] **Step 1: 写失败的测试**

把 `client/VibeCompanion/Tests/TokenAggregatorTests.swift` 整体替换为：

```swift
import XCTest
@testable import VibeCompanion

@MainActor
final class TokenAggregatorTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    private struct NoPricing: PricingSource {
        func pricing(for model: String) -> ModelPricing? { nil }
    }

    private struct FlatPricing: PricingSource {
        let rate: Double
        func pricing(for model: String) -> ModelPricing? {
            ModelPricing(input: rate, output: rate, cacheCreate: rate, cacheRead: rate,
                         cacheReadExplicit: true, inputAbove200k: nil, outputAbove200k: nil,
                         cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                         longContextThreshold: nil, fastMultiplier: 1.0)
        }
    }

    private func entry(min: Double, input: Int = 0, output: Int = 0,
                       cacheRead: Int = 0, key: String) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(min * 60),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: input, output: output, cacheRead: cacheRead),
                   isSidechain: false, hasSpeed: false, isFastSpeed: false, dedupKey: key)
    }

    private func aggregator(nowOffsetMin: Double,
                            pricing: PricingSource = NoPricing()) -> TokenAggregator {
        TokenAggregator(pricing: pricing, retentionHours: 6, idleTimeoutSeconds: 90,
                        now: { self.base.addingTimeInterval(nowOffsetMin * 60) })
    }

    // MARK: 主速率

    func testRateUsesTotalTokensIncludingCacheRead() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, output: 100, cacheRead: 800, key: "k1"))
        a.ingest(entry(min: 10, input: 100, output: 100, cacheRead: 800, key: "k2"))
        a.recompute()
        // total = 2000，跨 10 分钟
        XCTAssertEqual(a.tokensPerMinute, 200, accuracy: 0.001)
    }

    func testIndicatorExcludesCacheBuckets() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, output: 100, cacheRead: 800, key: "k1"))
        a.ingest(entry(min: 10, input: 100, output: 100, cacheRead: 800, key: "k2"))
        a.recompute()
        // input+output = 400，跨 10 分钟
        XCTAssertEqual(a.indicatorTokensPerMinute, 40, accuracy: 0.001)
        XCTAssertEqual(a.level, .normal)
    }

    func testLevelFollowsIndicatorNotTotal() {
        let a = aggregator(nowOffsetMin: 2)
        // indicator = 12000/1min = 12000 -> high，尽管 total 更大
        a.ingest(entry(min: 0, input: 6000, output: 0, cacheRead: 900_000, key: "k1"))
        a.ingest(entry(min: 1, input: 6000, output: 0, cacheRead: 900_000, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.level, .high)
    }

    // MARK: 窗口以 entry timestamp 为准

    func testUsesEntryTimestampNotArrivalTime() {
        let a = aggregator(nowOffsetMin: 11)
        // 两条 entry 的时间戳相隔 10 分钟，但都是"此刻"注入的
        a.ingest(entry(min: 0, input: 500, key: "k1"))
        a.ingest(entry(min: 10, input: 500, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.tokensPerMinute, 100, accuracy: 0.001)   // 1000 / 10min
    }

    // MARK: 单条 entry -> 无速率

    func testSingleEntryYieldsNoBurnRate() {
        let a = aggregator(nowOffsetMin: 1)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.recompute()
        XCTAssertFalse(a.hasBurnRate)
        XCTAssertEqual(a.tokensPerMinute, 0, accuracy: 0.001)
    }

    func testTwoEntriesYieldBurnRate() {
        let a = aggregator(nowOffsetMin: 2)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 1, input: 100, key: "k2"))
        a.recompute()
        XCTAssertTrue(a.hasBurnRate)
    }

    // MARK: 空闲归零（偏离 D1）

    func testIdleAfterTimeoutZeroesRate() {
        let a = aggregator(nowOffsetMin: 20)      // 距末条 entry 10 分钟 > 90s
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertTrue(a.isIdle)
        XCTAssertEqual(a.tokensPerMinute, 0, accuracy: 0.001)
    }

    func testNotIdleWithinTimeout() {
        let a = aggregator(nowOffsetMin: 11)      // 距末条 60s < 90s
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertFalse(a.isIdle)
        XCTAssertGreaterThan(a.tokensPerMinute, 0)
    }

    // MARK: 去重

    func testDuplicateKeyIsDeduped() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 0, input: 100, key: "k1"))   // 同键，同量 -> 丢弃
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.tokensPerMinute, 20, accuracy: 0.001)   // 200/10，不是 300/10
    }

    // MARK: 今日累计

    func testTodayTotalUsesTotalTokensAndDedupes() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 10, cacheRead: 90, key: "k1"))
        a.ingest(entry(min: 0, input: 10, cacheRead: 90, key: "k1"))   // 重复
        a.ingest(entry(min: 10, input: 10, cacheRead: 90, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.todayTotal, 200)
    }

    /// 今日累计不受 6h 主窗口驱逐影响
    func testTodayTotalSurvivesMainWindowEviction() {
        let a = aggregator(nowOffsetMin: 60 * 10)     // now = base + 10h
        a.ingest(entry(min: 0, input: 100, key: "k1"))         // 10h 前，已被主窗口驱逐
        a.ingest(entry(min: 60 * 9, input: 100, key: "k2"))    // 1h 前
        a.recompute()
        XCTAssertEqual(a.todayTotal, 200)
    }

    // MARK: cost

    func testCostPerHourComputedFromPerEntryCosts() {
        let a = aggregator(nowOffsetMin: 31, pricing: FlatPricing(rate: 1e-3))
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 30, input: 1000, key: "k2"))
        a.recompute()
        // cost = 2000 * 1e-3 = 2.0 USD，跨 30 分钟 -> 4.0 USD/h
        XCTAssertEqual(a.costPerHour!, 4.0, accuracy: 1e-9)
    }

    func testCostNilWhenPricingUnavailable() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertNil(a.costPerHour)
        // 定价缺失不得影响速率
        XCTAssertGreaterThan(a.tokensPerMinute, 0)
    }

    // MARK: 近期峰值

    func testRecentPeakTracksMaximum() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 10, input: 1000, key: "k2"))
        a.recompute()
        let peak = a.recentPeak
        XCTAssertGreaterThan(peak, 0)
        XCTAssertGreaterThanOrEqual(peak, a.tokensPerMinute)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenAggregatorTests
```

Expected: 编译失败——`TokenAggregator` 无 `init(pricing:retentionHours:idleTimeoutSeconds:now:)`。

- [ ] **Step 3: 写 SessionBlockCost**

创建 `client/VibeCompanion/Sources/Core/SessionBlockCost.swift`：

```swift
import Foundation

extension SessionBlock {
    /// 返回一个填入了 cost 的副本。
    func withCostUSD(_ cost: Double?) -> SessionBlock {
        SessionBlock(id: id, startTime: startTime, endTime: endTime,
                     actualEndTime: actualEndTime, isActive: isActive, isGap: isGap,
                     entries: entries, tokenCounts: tokenCounts, costUSD: cost)
    }
}

/// 计算一个 block 的总 cost。
///
/// **必须逐条 entry 计价后求和**，不可用聚合后的 `tokenCounts` 一次性算：
/// - 200K 边际分段是按**单次请求**判定的，聚合后会把多条小请求错误地推过阈值
/// - `fastMultiplier` 是 per-entry 的（取决于该条的 `usage.speed`）
/// - 一个 block 内可能混用多个模型，单价不同
///
/// 全部 entry 都未命中定价时返回 nil。部分命中时只累加命中的部分——
/// 未命中的 entry 其 token 仍照常计入 `tokenCounts`。
func blockCostUSD(_ block: SessionBlock, source: PricingSource) -> Double? {
    var total: Double = 0
    var matched = false
    for entry in block.entries {
        if let cost = calculateCost(counts: entry.counts, model: entry.model,
                                    isFast: entry.isFastSpeed, source: source) {
            total += cost
            matched = true
        }
    }
    return matched ? total : nil
}
```

- [ ] **Step 4: 重写 TokenAggregator**

把 `client/VibeCompanion/Sources/Core/TokenAggregator.swift` 整体替换为：

```swift
import Foundation

/// 维护有界窗口，按 ccusage 的 session block 模型计算 burn rate。
///
/// 与旧实现（60 秒滑窗内 token 求和）的根本差异：窗口以 **entry 自身的
/// timestamp** 为准而非到达时间，这样回扫进来的历史数据才能被正确分块。
@MainActor
final class TokenAggregator: ObservableObject {

    // MARK: 发布的状态

    /// 主速率，分子为 Total Tokens（含 cache_read）。空闲时为 0。
    @Published private(set) var tokensPerMinute: Double = 0
    /// 档位速率，分子仅 input + output。
    @Published private(set) var indicatorTokensPerMinute: Double = 0
    /// 由 `indicatorTokensPerMinute` 判定的档位。
    @Published private(set) var level: BurnRateLevel = .normal
    /// 估算花费速率；定价未就绪或未命中时为 nil。
    @Published private(set) var costPerHour: Double?
    /// false 表示活跃块不足以算出速率（只有一条 entry），UI 应显示 `--` 而非 `0`。
    @Published private(set) var hasBurnRate: Bool = false
    /// 距末条 entry 超过 idle 超时。
    @Published private(set) var isIdle: Bool = true
    /// 今日累计 Total Tokens。
    @Published private(set) var todayTotal: Int = 0
    /// 近期观察到的最大速率，供自适应量程使用。
    @Published private(set) var recentPeak: Double = 0

    // MARK: 内部状态

    /// 主窗口：只保留够算活跃块的时长。
    private let window: UsageWindow
    /// 今日累计窗口：主窗口装不下一整天，故单独维护。
    /// 复用 `UsageWindow` 使去重语义自动生效。
    private let dailyWindow: UsageWindow
    private let pricing: PricingSource?
    private let idleTimeout: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    init(pricing: PricingSource?,
         retentionHours: Double = 6,
         idleTimeoutSeconds: TimeInterval = 90,
         now: @escaping () -> Date = { Date() }) {
        self.window = UsageWindow(retentionHours: retentionHours)
        self.dailyWindow = UsageWindow(retentionHours: 25)
        self.pricing = pricing
        self.idleTimeout = idleTimeoutSeconds
        self.now = now
    }

    /// 启动周期性重算。测试中不调用，改为手动 `recompute()`。
    func startTicking(interval: TimeInterval = 2) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// 注入一条采集到的记录。不立即重算——一次 FSEvents 常带来几十行。
    func ingest(_ entry: UsageEntry) {
        window.insert(entry)
        dailyWindow.insert(entry)
    }

    /// 驱逐过期条目、重新分块、更新全部发布状态。
    func recompute() {
        let t = now()
        window.evict(now: t)
        dailyWindow.evict(now: t)

        updateTodayTotal(now: t)

        let blocks = identifySessionBlocks(window.snapshot(), now: t)
        guard let active = blocks.first(where: { $0.isActive && !$0.isGap }) else {
            reset()
            return
        }

        let withCost = pricing.map { active.withCostUSD(blockCostUSD(active, source: $0)) } ?? active
        guard let rate = calculateBurnRate(withCost) else {
            reset()
            return
        }

        // 空闲判定：距末条 entry 超时则归零（偏离 D1）。
        // ccusage 原生行为是冻结，但它是跑完即退的 CLI，本项目是常驻仪表。
        let idle = active.actualEndTime.map { t.timeIntervalSince($0) > idleTimeout } ?? true

        hasBurnRate = true
        isIdle = idle
        tokensPerMinute = idle ? 0 : rate.tokensPerMinute
        indicatorTokensPerMinute = idle ? 0 : rate.tokensPerMinuteForIndicator
        level = BurnRateLevel.from(indicator: indicatorTokensPerMinute)
        costPerHour = idle ? nil : rate.costPerHour
        recentPeak = max(recentPeak, rate.tokensPerMinute)
    }

    // MARK: - private

    private func reset() {
        hasBurnRate = false
        isIdle = true
        tokensPerMinute = 0
        indicatorTokensPerMinute = 0
        level = .normal
        costPerHour = nil
    }

    private func updateTodayTotal(now t: Date) {
        let today = Self.dayKey(t)
        todayTotal = dailyWindow.snapshot()
            .filter { Self.dayKey($0.timestamp) == today }
            .reduce(0) { $0 + $1.counts.total }
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
```

- [ ] **Step 5: 清理 Models.swift 与 AppConfig.swift**

把 `client/VibeCompanion/Sources/Core/Models.swift` 整体替换为：

```swift
import Foundation

// 旧的 UsageEvent 已被 Core/UsageEntry.swift 中的 UsageEntry 取代。
// 其 effectiveTokens 口径（input + output + cacheCreation）是本项目为压制
// 天文数字自创的，ccusage 无此概念；对应角色由 BurnRate 的
// tokensPerMinuteForIndicator（input + output）承担。
```

把 `client/VibeCompanion/Sources/Core/AppConfig.swift` 整体替换为：

```swift
import Foundation

/// 全局应用配置
enum AppConfig {
    /// 有界窗口保留时长（小时）。推导见 spec 6.2：
    /// 活跃块的首条 entry 不会早于 now-5h，加 1h 余量覆盖整点 floor 偏移。
    static let windowRetentionHours: Double = 6
    /// 空闲归零阈值（秒）。偏离 D1。
    static let idleTimeoutSeconds: TimeInterval = 90
    /// 重算周期（秒）。
    static let recomputeIntervalSeconds: TimeInterval = 2
    /// 回扫窗口（小时），与 windowRetentionHours 保持一致。
    static let backfillWindowHours: Double = 6
}
```

- [ ] **Step 6: 接上 AppCoordinator**

修改 `client/VibeCompanion/Sources/App/VibeCompanionApp.swift`。把 `AppCoordinator` 的属性与 `start()` 改为：

```swift
    let pricingStore = PricingStore(builtinSnapshot: loadBuiltinPricingSnapshot(),
                                    cache: FilePricingCache(),
                                    fetcher: URLSessionPricingFetcher())
    lazy var aggregator = TokenAggregator(pricing: pricingStore,
                                          retentionHours: AppConfig.windowRetentionHours,
                                          idleTimeoutSeconds: AppConfig.idleTimeoutSeconds)
```

并在 `start()` 中，`c.start()` 之后补上：

```swift
        aggregator.startTicking(interval: AppConfig.recomputeIntervalSeconds)
        // 定价异步刷新，失败不影响速率显示
        Task { await pricingStore.refresh() }
```

- [ ] **Step 7: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenAggregatorTests
```

Expected: `Executed 15 tests, with 0 failures`

- [ ] **Step 8: 跑全量测试并确认可构建**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

> `MenuBarContent.swift` 与 `SpeedometerView.swift` 仍在读 `aggregator.tokensPerMinute`，该属性保留，故应能编译。`SmokeTests.swift` 若引用了 `UsageEvent` 需一并调整。

- [ ] **Step 9: 提交**

```bash
git add -A client/VibeCompanion
git commit -m "$(cat <<'EOF'
feat(core): TokenAggregator 改用 session block burn rate

窗口以 entry 自身 timestamp 为准（而非到达时间），回扫的历史数据
才能正确分块；今日累计改用独立的 25h 窗口以复用去重语义；cost 逐条
entry 计价后求和；空闲超 90s 归零（偏离 D1）。删除 UsageEvent 与
自创的 effectiveTokens 口径。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Golden fixture 端到端校验

**Files:**
- Create: `client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl`
- Create: `client/VibeCompanion/Tests/GoldenFixtureTests.swift`
- Modify: `client/Package.swift`（给 testTarget 加 resources）

**Interfaces:**
- Consumes: 全部 P1/P2/P3 产出
- Produces: 无（纯验证）

**背景：** 这是"数据上与 ccusage 一致"这一宗旨的验收关口。fixture 必须**脱敏并固化**——只保留算法需要的字段，剔除对话内容；且必须是静态快照，否则测试会随本机数据漂移（同一个块在本次设计过程中先后算出 439k 与 760k，部分正是因为它仍在累积）。

- [ ] **Step 1: 生成脱敏 fixture**

```bash
mkdir -p client/VibeCompanion/Tests/Fixtures
cd ~/.claude/projects && python3 - <<'PY' > /Users/woody/Workspaces/vide-companion/client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl
import json, glob, sys
from datetime import datetime, timezone

rows = []
for f in glob.glob('**/*.jsonl', recursive=True):
    for line in open(f, errors='ignore'):
        try: o = json.loads(line)
        except Exception: continue
        m = o.get('message') or {}
        u = m.get('usage') or {}
        if not u or not o.get('timestamp'): continue
        rows.append((o['timestamp'], {
            "timestamp": o["timestamp"],
            "requestId": o.get("requestId"),
            "isSidechain": o.get("isSidechain", False),
            "message": {
                "id": m.get("id"),
                "model": m.get("model"),
                "usage": {
                    "input_tokens": u.get("input_tokens", 0),
                    "output_tokens": u.get("output_tokens", 0),
                    "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
                    "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
                    **({"cache_creation": u["cache_creation"]} if "cache_creation" in u else {}),
                    **({"speed": u["speed"]} if "speed" in u else {}),
                },
            },
        }))
rows.sort(key=lambda r: r[0])
for _, r in rows:
    print(json.dumps(r, separators=(',', ':')))
print(f"wrote {len(rows)} rows", file=sys.stderr)
PY
```

确认只含算法字段，无对话内容：

```bash
head -1 client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl | python3 -m json.tool
grep -c '"content"' client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl || echo "无 content 字段 ✓"
wc -l client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl
```

- [ ] **Step 2: 用参考脚本算出期望值**

```bash
cd /Users/woody/Workspaces/vide-companion && python3 - <<'PY'
import json
from datetime import datetime, timedelta

rows = []
for line in open('client/VibeCompanion/Tests/Fixtures/claude-golden.jsonl'):
    o = json.loads(line)
    m, u = o['message'], o['message']['usage']
    cc = u.get('cache_creation')
    cc5m = cc['ephemeral_5m_input_tokens'] if cc else u.get('cache_creation_input_tokens', 0)
    cc1h = cc['ephemeral_1h_input_tokens'] if cc else 0
    total = u['input_tokens'] + u['output_tokens'] + cc5m + cc1h + u['cache_read_input_tokens']
    key = f"{m['id']}:{o['requestId']}" if o.get('requestId') else m['id']
    rows.append((datetime.fromisoformat(o['timestamp'].replace('Z', '+00:00')), key,
                 o.get('isSidechain', False), 'speed' in u, total,
                 u['input_tokens'] + u['output_tokens']))
rows.sort(key=lambda r: r[0])

best = {}
for ts, k, sc, sp, total, io in rows:
    cur = best.get(k)
    if cur is None: best[k] = (ts, sc, sp, total, io); continue
    _, csc, csp, ctotal, _ = cur
    if sc != csc: replace = csc
    elif total != ctotal: replace = total > ctotal
    else: replace = sp and not csp
    if replace: best[k] = (ts, sc, sp, total, io)

ded = sorted((v[0], v[3], v[4]) for v in best.values())
print(f"raw {len(rows)} -> deduped {len(ded)}")

blocks, cur = [], None
for ts, total, io in ded:
    if cur and ts - cur['start'] <= timedelta(hours=5) and ts - cur['last'] <= timedelta(hours=5):
        cur['total'] += total; cur['io'] += io; cur['last'] = ts; cur['n'] += 1
    else:
        cur = {'start': ts.replace(minute=0, second=0, microsecond=0), 'first': ts,
               'last': ts, 'total': total, 'io': io, 'n': 1}
        blocks.append(cur)

print(f"{len(blocks)} blocks")
for b in blocks:
    d = (b['last'] - b['first']).total_seconds() / 60
    if d <= 0:
        print(f"  {b['start']:%Y-%m-%dT%H:%M:%SZ}  n={b['n']:<4} duration<=0 -> no burn rate")
    else:
        print(f"  {b['start']:%Y-%m-%dT%H:%M:%SZ}  n={b['n']:<4} dur={d:8.4f}min "
              f"total={b['total']:<12} tpm={b['total']/d:12.4f} ind={b['io']/d:10.4f}")
PY
```

把输出记下来，填进 Step 3 的期望值。

- [ ] **Step 3: 写测试**

创建 `client/VibeCompanion/Tests/GoldenFixtureTests.swift`。把 `expectedBlocks` 换成 Step 2 的真实输出：

```swift
import XCTest
@testable import VibeCompanion

/// 用固化的真实数据快照校验整条链路：解析 -> 去重 -> 分块 -> burn rate。
///
/// fixture 是**静态**的，不得改为实时读取 ~/.claude——活跃块会持续累积，
/// 那样测试会随本机数据漂移。
final class GoldenFixtureTests: XCTestCase {

    /// 每个块的期望值，来自计划 Task 7 Step 2 的参考脚本输出。
    /// 格式：(块起点 ISO8601, entry 数, tokensPerMinute, indicator)
    /// tokensPerMinute 为 nil 表示 duration <= 0（无 burn rate）。
    private let expectedBlocks: [(start: String, count: Int, tpm: Double?, indicator: Double?)] = [
        // TODO(执行者)：粘贴 Step 2 的输出，例如
        // ("2026-07-12T05:00:00Z", 89, 41080.1234, 762.5678),
        // ("2026-07-21T11:00:00Z", 2, nil, nil),
    ]

    private func loadEntries() throws -> [UsageEntry] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-golden",
                                                  withExtension: "jsonl"),
                                "fixture 未打包，检查 Package.swift 的 testTarget resources")
        let text = try String(contentsOf: url, encoding: .utf8)
        let adapter = ClaudeAdapter(roots: [])
        var ctx = ParseContext()
        return text.split(separator: "\n").compactMap {
            adapter.parse(line: String($0), context: &ctx)
        }
    }

    private func dedupedEntries() throws -> [UsageEntry] {
        let window = UsageWindow(retentionHours: 24 * 365 * 10)   // 不驱逐
        for e in try loadEntries() { window.insert(e) }
        return window.snapshot()
    }

    func testFixtureParses() throws {
        XCTAssertFalse(try loadEntries().isEmpty, "fixture 一条也没解析出来")
    }

    func testDeduplicationReducesEntryCount() throws {
        let raw = try loadEntries().count
        let deduped = try dedupedEntries().count
        XCTAssertLessThan(deduped, raw, "去重后条目数应显著减少（实测约掉 56%）")
    }

    func testBlockCountMatchesReference() throws {
        // now 取远未来，使所有块都非活跃——分块结果与 now 无关
        let blocks = identifySessionBlocks(try dedupedEntries(),
                                           now: Date(timeIntervalSince1970: 4_000_000_000))
            .filter { !$0.isGap }
        XCTAssertEqual(blocks.count, expectedBlocks.count)
    }

    func testEachBlockMatchesReferenceValues() throws {
        let blocks = identifySessionBlocks(try dedupedEntries(),
                                           now: Date(timeIntervalSince1970: 4_000_000_000))
            .filter { !$0.isGap }
        XCTAssertEqual(blocks.count, expectedBlocks.count, "块数不符，后续断言无意义")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)

        for (block, expected) in zip(blocks, expectedBlocks) {
            XCTAssertEqual(iso.string(from: block.startTime), expected.start)
            XCTAssertEqual(block.entries.count, expected.count, "块 \(expected.start) 条目数不符")

            let rate = calculateBurnRate(block)
            if let expectedTpm = expected.tpm {
                let r = try XCTUnwrap(rate, "块 \(expected.start) 应有 burn rate")
                XCTAssertEqual(r.tokensPerMinute, expectedTpm, accuracy: expectedTpm * 1e-6)
                XCTAssertEqual(r.tokensPerMinuteForIndicator, expected.indicator!,
                               accuracy: expected.indicator! * 1e-6)
            } else {
                XCTAssertNil(rate, "块 \(expected.start) 的 duration <= 0，应无 burn rate")
            }
        }
    }
}
```

- [ ] **Step 4: 把 fixture 挂到 testTarget**

修改 `client/Package.swift` 的 testTarget：

```swift
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests",
            resources: [
                .copy("Fixtures/claude-golden.jsonl")
            ]
        )
```

- [ ] **Step 5: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GoldenFixtureTests
```

Expected: `Executed 4 tests, with 0 failures`

若块数或数值不符，**不要调期望值去迁就实现**——先确认参考脚本与 Swift 实现哪一方偏离了 ccusage 源码，对照 `blocks.rs:17-71` 与 `adapter/claude/mod.rs:224-238` 逐条核。

- [ ] **Step 6: 与 ccusage 交叉验证**

这是宗旨的最终验收。运行：

```bash
npx ccusage@20 blocks --active
```

把它报告的 tokens/min 与 app 实际显示的值对比。两者应一致（允许因活跃块仍在累积而有的时间差）。若不一致，记录差异并排查，**不要**先合并。

- [ ] **Step 7: 提交**

```bash
git add client/VibeCompanion/Tests/Fixtures client/VibeCompanion/Tests/GoldenFixtureTests.swift client/Package.swift
git commit -m "$(cat <<'EOF'
test: 添加 golden fixture 端到端校验

用脱敏固化的真实 JSONL 快照校验解析->去重->分块->burn rate 整条链路。
fixture 为静态快照，避免测试随本机数据漂移。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 完成标准

- 速度表显示的数值与 `npx ccusage@20 blocks --active` 一致
- 全部测试通过；`swift build` 成功
- `DataSource.swift`、`ParserTests.swift`、`UsageEvent`、`effectiveTokens` 均已删除
- P4 可直接消费 `TokenAggregator` 发布的 7 个状态
