# P1 算法核心 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用 Swift 复刻 ccusage 的 session block + burn rate 算法核心，产出一组不依赖 I/O 的纯类型与纯函数。

**Architecture:** 全部代码落在 `client/VibeCompanion/Sources/Core/`。本计划**不修改**任何现有文件，只新增——现有的 `TokenAggregator`、`Collector`、速度表继续按旧逻辑运行，直到 P3 才切换。这样每个任务都能独立提交且 app 始终可编译。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest / macOS 13+

参考实现：ccusage v20.0.18（commit `739e88f`），路径均相对 `rust/crates/ccusage/src/`。
设计文档：`docs/superpowers/specs/2026-07-25-ccusage-burnrate-design.md`

## Global Constraints

- **测试命令必须带 `DEVELOPER_DIR`。** 本机 `xcode-select` 指向 CommandLineTools，其中没有 XCTest，直接 `swift test` 会因 `no such module 'XCTest'` 全量失败。所有命令一律写作：
  `cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`
- **`Core/` 下不得出现 I/O。** 不得 import 除 `Foundation` 外的框架，不得读文件、发网络请求、取系统时间。所有需要"现在"的函数以参数形式接收 `now: Date`。
- **测试风格follow 现有文件**：`import XCTest` + `@testable import VibeCompanion`，类声明为 `final class XxxTests: XCTestCase`。现有文件带 `@MainActor`，但本计划的类型均非 `@MainActor`，故新测试类**不加** `@MainActor`。
- **数值必须与 ccusage 一致。** 任何"看起来更合理"的改动都不允许。边界一律用严格大于/小于，与 Rust 源码逐字对应。
- 提交信息用中文，结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## File Structure

| 文件 | 职责 |
|---|---|
| `Core/TokenCounts.swift` | 归一化 token 分桶 + `total` + 加法 |
| `Core/UsageEntry.swift` | 单条用量记录（含去重所需的元信息） |
| `Core/UsageDeduplicator.swift` | `shouldReplace` 三级优先级判定 |
| `Core/SessionBlocks.swift` | `floorToUTCHour` / `SessionBlock` / `identifySessionBlocks` |
| `Core/BurnRate.swift` | `BurnRate` / `calculateBurnRate` / `BurnRateLevel` |
| `Core/UsageWindow.swift` | 有界有序窗口，承载去重与驱逐 |

对应测试文件同名加 `Tests` 后缀，放在 `client/VibeCompanion/Tests/`。

---

### Task 1: TokenCounts

**Files:**
- Create: `client/VibeCompanion/Sources/Core/TokenCounts.swift`
- Test: `client/VibeCompanion/Tests/TokenCountsTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `struct TokenCounts` — 成员 `input/output/cacheCreation5m/cacheCreation1h/cacheRead/extraTotal: Int`（全部默认 0），计算属性 `total: Int`、`cacheCreationTotal: Int`、`inputPlusOutput: Int`，静态方法 `+` 与 `+=`。后续所有任务都依赖这些名字。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/TokenCountsTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class TokenCountsTests: XCTestCase {

    /// 对齐 ccusage types.rs:86-91 —— total 含全部六个桶
    func testTotalSumsAllBuckets() {
        let c = TokenCounts(input: 1, output: 2, cacheCreation5m: 4,
                            cacheCreation1h: 8, cacheRead: 16, extraTotal: 32)
        XCTAssertEqual(c.total, 63)
    }

    func testDefaultsAreZero() {
        XCTAssertEqual(TokenCounts().total, 0)
    }

    /// cacheCreationTotal 等价于 ccusage 的 cache_creation_token_count()
    func testCacheCreationTotalMergesBothTiers() {
        let c = TokenCounts(cacheCreation5m: 30, cacheCreation1h: 12)
        XCTAssertEqual(c.cacheCreationTotal, 42)
    }

    /// indicator 速率的分子：两个 cache 桶都排除
    func testInputPlusOutputExcludesCacheBuckets() {
        let c = TokenCounts(input: 7, output: 3, cacheCreation5m: 100,
                            cacheCreation1h: 200, cacheRead: 400)
        XCTAssertEqual(c.inputPlusOutput, 10)
    }

    func testAdditionCombinesBucketwise() {
        let a = TokenCounts(input: 1, output: 2, cacheCreation5m: 3,
                            cacheCreation1h: 4, cacheRead: 5, extraTotal: 6)
        let b = TokenCounts(input: 10, output: 20, cacheCreation5m: 30,
                            cacheCreation1h: 40, cacheRead: 50, extraTotal: 60)
        let s = a + b
        XCTAssertEqual(s, TokenCounts(input: 11, output: 22, cacheCreation5m: 33,
                                      cacheCreation1h: 44, cacheRead: 55, extraTotal: 66))
    }

    func testPlusEqualsAccumulates() {
        var acc = TokenCounts()
        acc += TokenCounts(input: 5)
        acc += TokenCounts(input: 5, output: 1)
        XCTAssertEqual(acc, TokenCounts(input: 10, output: 1))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenCountsTests
```

Expected: 编译失败，`cannot find 'TokenCounts' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/TokenCounts.swift`：

```swift
import Foundation

/// 归一化的 token 分桶。对齐 ccusage `TokenCounts`（types.rs:76-91）。
///
/// cacheCreation 拆成 5m / 1h 两个桶：计数场景两者等价合并
/// （见 `cacheCreationTotal`），但计价场景单价不同，必须分开。
struct TokenCounts: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation5m: Int = 0
    var cacheCreation1h: Int = 0
    var cacheRead: Int = 0
    /// 未归类 token（gemini 等 agent 声明的 total 超出分项之和的部分）。
    /// claude / codex 恒为 0。
    var extraTotal: Int = 0

    /// ccusage `TokenCounts::total()`——burn rate 的分子（Total Tokens 口径）。
    var total: Int {
        input + output + cacheCreation5m + cacheCreation1h + cacheRead + extraTotal
    }

    /// ccusage `cache_creation_token_count()`——计数场景下两档缓存写入合并。
    var cacheCreationTotal: Int { cacheCreation5m + cacheCreation1h }

    /// `tokensPerMinuteForIndicator` 的分子——两个 cache 桶均排除。
    var inputPlusOutput: Int { input + output }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheCreation5m: lhs.cacheCreation5m + rhs.cacheCreation5m,
                    cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    extraTotal: lhs.extraTotal + rhs.extraTotal)
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenCountsTests
```

Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/TokenCounts.swift client/VibeCompanion/Tests/TokenCountsTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 TokenCounts 归一化分桶

对齐 ccusage TokenCounts::total()，cacheCreation 拆 5m/1h 两档
以支持后续按不同单价计价。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: floorToUTCHour

**Files:**
- Create: `client/VibeCompanion/Sources/Core/SessionBlocks.swift`
- Test: `client/VibeCompanion/Tests/SessionBlocksTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `func floorToUTCHourMillis(_ ms: Int64) -> Int64`、`func floorToUTCHour(_ date: Date) -> Date`、`enum SessionBlockConfig { static let durationHours: Double = 5 }`

**背景：** ccusage 用 Rust 的 `div_euclid`（向下取整除法），Swift 的 `/` 是向零截断。对负时间戳（1970 年前）两者结果不同。虽然真实数据不会出现负时间戳，但这是算法忠实度的一部分，且写错了在测试中不会自动暴露——所以显式测它。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/SessionBlocksTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class SessionBlocksTests: XCTestCase {

    private let hourMs: Int64 = 3_600_000

    func testFloorOnExactHourIsIdentity() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs), 5 * hourMs)
    }

    func testFloorMidHourRoundsDown() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs + 1), 5 * hourMs)
        XCTAssertEqual(floorToUTCHourMillis(6 * hourMs - 1), 5 * hourMs)
    }

    func testFloorAtZero() {
        XCTAssertEqual(floorToUTCHourMillis(0), 0)
    }

    /// 关键：欧几里得除法而非截断除法。
    /// -1 ms 属于 [-1h, 0) 这个小时，应向下取整到 -1h，而不是 0。
    func testFloorNegativeUsesEuclideanDivision() {
        XCTAssertEqual(floorToUTCHourMillis(-1), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs - 1), -2 * hourMs)
    }

    /// Date 包装版：2026-07-25T17:22:13.456Z -> 2026-07-25T17:00:00Z
    func testFloorDateDropsMinutesSecondsMillis() {
        let d = Date(timeIntervalSince1970: 1_785_000_133.456)
        let floored = floorToUTCHour(d)
        let secs = floored.timeIntervalSince1970
        XCTAssertEqual(secs.truncatingRemainder(dividingBy: 3600), 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(floored, d)
        XCTAssertLessThan(d.timeIntervalSince(floored), 3600)
    }

    func testSessionDurationIsFiveHours() {
        XCTAssertEqual(SessionBlockConfig.durationHours, 5.0)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionBlocksTests
```

Expected: 编译失败，`cannot find 'floorToUTCHourMillis' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/SessionBlocks.swift`：

```swift
import Foundation

/// session block 常量。对齐 ccusage `DEFAULT_SESSION_DURATION_HOURS`（main.rs:65）。
enum SessionBlockConfig {
    static let durationHours: Double = 5
    static let durationSeconds: TimeInterval = 5 * 3600
    static let millisPerHour: Int64 = 3_600_000
}

/// 向下取整到 UTC 整点（毫秒时间戳）。
///
/// 对齐 ccusage `TimestampMs::floor_to_hour()`（date_utils.rs:58-60），
/// 它用 Rust 的 `div_euclid`——**向下取整**除法。Swift 的 `/` 是向零截断，
/// 对负数结果不同，故此处显式修正。
func floorToUTCHourMillis(_ ms: Int64) -> Int64 {
    let h = SessionBlockConfig.millisPerHour
    let q = ms / h
    let r = ms % h
    return (r < 0 ? q - 1 : q) * h
}

/// `floorToUTCHourMillis` 的 Date 包装。
func floorToUTCHour(_ date: Date) -> Date {
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    return Date(timeIntervalSince1970: Double(floorToUTCHourMillis(ms)) / 1000)
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionBlocksTests
```

Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/SessionBlocks.swift client/VibeCompanion/Tests/SessionBlocksTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 floorToUTCHour 与 session block 常量

用欧几里得除法而非 Swift 默认的截断除法，对齐 ccusage
TimestampMs::floor_to_hour 在负时间戳上的语义。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: UsageEntry 与去重判定

**Files:**
- Create: `client/VibeCompanion/Sources/Core/UsageEntry.swift`
- Create: `client/VibeCompanion/Sources/Core/UsageDeduplicator.swift`
- Test: `client/VibeCompanion/Tests/UsageDeduplicatorTests.swift`

**Interfaces:**
- Consumes: `TokenCounts`（Task 1）
- Produces:
  - `struct UsageEntry: Equatable` — 成员 `timestamp: Date`、`agent: String`、`sessionId: String?`、`model: String?`、`counts: TokenCounts`、`isSidechain: Bool`、`hasSpeed: Bool`、`isFastSpeed: Bool`、`dedupKey: String?`
  - `func claudeDedupKey(messageId: String?, requestId: String?) -> String?`
  - `func shouldReplace(candidate: UsageEntry, existing: UsageEntry) -> Bool`

**背景：** 实测本机 2083 条原始行去重后仅剩 917 条（掉 56%），其中 441/2374 为 sidechain（18.6%）。去重是**替换**语义而非跳过——token 更多的重复条目会覆盖已存条目，这直接改变数值（同一区块曾算出 439k vs 760k）。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/UsageDeduplicatorTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class UsageDeduplicatorTests: XCTestCase {

    private func entry(total: Int = 100,
                       isSidechain: Bool = false,
                       hasSpeed: Bool = false,
                       key: String? = "m1:r1") -> UsageEntry {
        UsageEntry(timestamp: Date(timeIntervalSince1970: 1000),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: total),
                   isSidechain: isSidechain, hasSpeed: hasSpeed,
                   isFastSpeed: false, dedupKey: key)
    }

    // MARK: dedupKey 构造

    func testDedupKeyJoinsMessageIdAndRequestId() {
        XCTAssertEqual(claudeDedupKey(messageId: "msg_1", requestId: "req_1"), "msg_1:req_1")
    }

    /// v19.0.3 语义：requestId 缺失时退化为仅用 messageId
    func testDedupKeyFallsBackToMessageIdAlone() {
        XCTAssertEqual(claudeDedupKey(messageId: "msg_1", requestId: nil), "msg_1")
    }

    /// messageId 缺失 -> nil，该条目永不参与去重
    func testDedupKeyNilWithoutMessageId() {
        XCTAssertNil(claudeDedupKey(messageId: nil, requestId: "req_1"))
        XCTAssertNil(claudeDedupKey(messageId: nil, requestId: nil))
    }

    // MARK: 优先级 1 —— 非 sidechain 胜过 sidechain

    func testNonSidechainReplacesSidechain() {
        let existing = entry(total: 10, isSidechain: true)
        let candidate = entry(total: 5, isSidechain: false)   // token 更少也要赢
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    func testSidechainDoesNotReplaceNonSidechain() {
        let existing = entry(total: 5, isSidechain: false)
        let candidate = entry(total: 10, isSidechain: true)   // token 更多也要输
        XCTAssertFalse(shouldReplace(candidate: candidate, existing: existing))
    }

    // MARK: 优先级 2 —— sidechain 状态相同时，token 总量大的胜

    func testLargerTotalReplacesSmaller() {
        XCTAssertTrue(shouldReplace(candidate: entry(total: 200), existing: entry(total: 100)))
    }

    func testSmallerTotalDoesNotReplace() {
        XCTAssertFalse(shouldReplace(candidate: entry(total: 50), existing: entry(total: 100)))
    }

    func testPriorityTwoAppliesWithinSidechainPairs() {
        let existing = entry(total: 100, isSidechain: true)
        let candidate = entry(total: 200, isSidechain: true)
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    // MARK: 优先级 3 —— 总量相同时，带 speed 字段的胜

    func testHasSpeedReplacesWhenTotalsEqual() {
        let existing = entry(total: 100, hasSpeed: false)
        let candidate = entry(total: 100, hasSpeed: true)
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    func testNoSpeedDoesNotReplaceWhenTotalsEqual() {
        let existing = entry(total: 100, hasSpeed: true)
        let candidate = entry(total: 100, hasSpeed: false)
        XCTAssertFalse(shouldReplace(candidate: candidate, existing: existing))
    }

    func testIdenticalEntriesDoNotReplace() {
        XCTAssertFalse(shouldReplace(candidate: entry(), existing: entry()))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageDeduplicatorTests
```

Expected: 编译失败，`cannot find 'UsageEntry' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/UsageEntry.swift`：

```swift
import Foundation

/// 一条归一化的 token 用量记录。
///
/// 与 `Models.swift` 中的旧 `UsageEvent` 并存——旧类型服务于尚未切换的
/// `TokenAggregator`，P3 完成切换后删除。
struct UsageEntry: Equatable {
    /// 记录自身的时间戳（**不是**采集到的时间）。分块与窗口全部以此为准。
    let timestamp: Date
    let agent: String              // "claude" | "codex"
    let sessionId: String?
    let model: String?
    let counts: TokenCounts

    /// 去重优先级 1：ccusage 认为非 sidechain 条目更可信。
    let isSidechain: Bool
    /// 去重优先级 3：`usage.speed` 字段是否存在。
    let hasSpeed: Bool
    /// 计价用：`usage.speed == "fast"` 时套用 fast 倍率。
    let isFastSpeed: Bool

    /// `nil` 表示该条目永不参与去重（缺少 message.id）。
    let dedupKey: String?
}
```

创建 `client/VibeCompanion/Sources/Core/UsageDeduplicator.swift`：

```swift
import Foundation

/// Claude 的去重键：`messageId:requestId`。
///
/// 对齐 ccusage `createUniqueHash`（v19.0.3 data-loader.ts）：
/// messageId 缺失则返回 nil（永不去重）；requestId 缺失则退化为仅用 messageId。
///
/// 注意**不是** JSONL 行内的 `uuid`——Claude 把一次响应写成多行，
/// 各行 uuid 不同但 messageId/requestId 相同。
func claudeDedupKey(messageId: String?, requestId: String?) -> String? {
    guard let messageId, !messageId.isEmpty else { return nil }
    guard let requestId, !requestId.isEmpty else { return messageId }
    return "\(messageId):\(requestId)"
}

/// 同键条目冲突时，新条目是否应取代已存条目。
///
/// 对齐 ccusage `should_replace_deduped_entry`（adapter/claude/mod.rs:224-238）。
/// 这是**替换**语义而非跳过——顺序无关，最终留下的总是"最优"那条。
func shouldReplace(candidate: UsageEntry, existing: UsageEntry) -> Bool {
    // 1. 非 sidechain 胜过 sidechain（与 token 多少无关）
    if candidate.isSidechain != existing.isSidechain {
        return existing.isSidechain
    }
    // 2. sidechain 状态相同：token 总量大的胜
    let candidateTotal = candidate.counts.total
    let existingTotal = existing.counts.total
    if candidateTotal != existingTotal {
        return candidateTotal > existingTotal
    }
    // 3. 总量也相同：带 speed 字段的胜
    return candidate.hasSpeed && !existing.hasSpeed
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageDeduplicatorTests
```

Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/UsageEntry.swift client/VibeCompanion/Sources/Core/UsageDeduplicator.swift client/VibeCompanion/Tests/UsageDeduplicatorTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 UsageEntry 与去重替换判定

去重键改为 messageId:requestId（非行内 uuid），并实现 ccusage 的
三级替换优先级：非 sidechain > token 总量大 > 带 speed 字段。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: identifySessionBlocks

**Files:**
- Modify: `client/VibeCompanion/Sources/Core/SessionBlocks.swift`（在 Task 2 的内容后追加）
- Modify: `client/VibeCompanion/Tests/SessionBlocksTests.swift`（追加测试）

**Interfaces:**
- Consumes: `TokenCounts`（Task 1）、`floorToUTCHour`（Task 2）、`UsageEntry`（Task 3）
- Produces:
  - `struct SessionBlock: Equatable` — 成员 `id: String`、`startTime: Date`、`endTime: Date`、`actualEndTime: Date?`、`isActive: Bool`、`isGap: Bool`、`entries: [UsageEntry]`、`tokenCounts: TokenCounts`、`costUSD: Double?`
  - `func identifySessionBlocks(_ entries: [UsageEntry], sessionDurationHours: Double, now: Date) -> [SessionBlock]`

**背景（实现要点）：**
- 两个**独立**的开新块条件，均为**严格大于**：`entry.ts - blockStart > 5h` 或 `entry.ts - lastEntry.ts > 5h`
- gap 伪块**只在第二个条件**触发时插入，跨度 `lastEntry.ts + 5h → entry.ts`
- `isActive` 需**两个条件同时成立**：`now - lastEntry.ts < 5h` 且 `now < blockEnd`
- 块起点 floor 到整点，故首块墙钟跨度在 4h00m–5h00m 之间
- `costUSD` 在 P1 恒为 `nil`，由 P2 填充

- [ ] **Step 1: 写失败的测试**

在 `client/VibeCompanion/Tests/SessionBlocksTests.swift` 的最后一个 `}` 之前追加：

```swift
    // MARK: - identifySessionBlocks

    /// 基准时刻 2026-07-25T00:00:00Z，正好是整点，便于推算
    private var base: Date { Date(timeIntervalSince1970: 1_784_937_600) }

    private func mkEntry(offsetHours: Double, tokens: Int = 10) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(offsetHours * 3600),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: tokens),
                   isSidechain: false, hasSpeed: false, isFastSpeed: false,
                   dedupKey: "m\(offsetHours):r")
    }

    private func blocks(_ entries: [UsageEntry], nowOffsetHours: Double) -> [SessionBlock] {
        identifySessionBlocks(entries,
                              sessionDurationHours: 5,
                              now: base.addingTimeInterval(nowOffsetHours * 3600))
    }

    func testEmptyInputYieldsNoBlocks() {
        XCTAssertTrue(blocks([], nowOffsetHours: 1).isEmpty)
    }

    func testEntriesWithinFiveHoursFormOneBlock() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 2), mkEntry(offsetHours: 4)],
                       nowOffsetHours: 4.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.count, 3)
        XCTAssertEqual(b[0].tokenCounts.total, 30)
    }

    /// 恰好 5h 不开新块（严格大于才开）
    func testExactlyFiveHoursDoesNotSplit() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 5)], nowOffsetHours: 5.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.count, 2)
    }

    /// 触发条件一：距块起点超过 5h。两条 entry 间隔仅 4h，不触发 gap。
    func testSplitsWhenExceedingBlockStart() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 2),
                        mkEntry(offsetHours: 4), mkEntry(offsetHours: 5.5)],
                       nowOffsetHours: 6)
        XCTAssertEqual(b.count, 2)
        XCTAssertFalse(b.contains { $0.isGap })
        XCTAssertEqual(b[0].entries.count, 3)
        XCTAssertEqual(b[1].entries.count, 1)
    }

    /// 触发条件二：距上一条超过 5h，额外插入 gap 块
    func testGapBlockInsertedOnLongSilence() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 7)], nowOffsetHours: 7.5)
        XCTAssertEqual(b.count, 3)
        XCTAssertFalse(b[0].isGap)
        XCTAssertTrue(b[1].isGap)
        XCTAssertFalse(b[2].isGap)
        // gap 跨度 = 上一条 + 5h  ->  下一条
        XCTAssertEqual(b[1].startTime, base.addingTimeInterval(5 * 3600))
        XCTAssertEqual(b[1].endTime, base.addingTimeInterval(7 * 3600))
        XCTAssertTrue(b[1].entries.isEmpty)
    }

    /// 块起点 floor 到整点：07:42 起的块，startTime 应为 07:00
    func testBlockStartFlooredToHour() {
        let e = UsageEntry(timestamp: base.addingTimeInterval(7 * 3600 + 42 * 60),
                           agent: "claude", sessionId: nil, model: nil,
                           counts: TokenCounts(input: 1), isSidechain: false,
                           hasSpeed: false, isFastSpeed: false, dedupKey: "x:y")
        let b = blocks([e], nowOffsetHours: 8)
        XCTAssertEqual(b[0].startTime, base.addingTimeInterval(7 * 3600))
        XCTAssertEqual(b[0].endTime, base.addingTimeInterval(12 * 3600))
    }

    /// isActive 需两条件同时成立
    func testIsActiveRequiresBothConditions() {
        // now 距末条 1h（<5h），且 now < blockEnd  -> active
        XCTAssertTrue(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 1)[0].isActive)
        // now 距末条 6h（>=5h）-> 不 active
        XCTAssertFalse(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 6)[0].isActive)
    }

    func testGapBlockIsNeverActive() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 7)], nowOffsetHours: 7.1)
        XCTAssertFalse(b[1].isActive)
    }

    /// 乱序输入必须先排序再分块
    func testUnorderedInputIsSortedFirst() {
        let b = blocks([mkEntry(offsetHours: 4), mkEntry(offsetHours: 0), mkEntry(offsetHours: 2)],
                       nowOffsetHours: 4.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.map(\.timestamp),
                       [0.0, 2.0, 4.0].map { base.addingTimeInterval($0 * 3600) })
    }

    func testCostIsNilBeforePricingIsWired() {
        XCTAssertNil(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 1)[0].costUSD)
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionBlocksTests
```

Expected: 编译失败，`cannot find 'identifySessionBlocks' in scope`。

- [ ] **Step 3: 写最小实现**

在 `client/VibeCompanion/Sources/Core/SessionBlocks.swift` 末尾追加：

```swift
/// 一个 5 小时计费块。对齐 ccusage `SessionBlock`（blocks.rs）。
struct SessionBlock: Equatable {
    let id: String
    /// 已 floor 到 UTC 整点的块起点。
    let startTime: Date
    /// `startTime + 5h`。
    let endTime: Date
    /// 块内末条 entry 的时间戳；gap 块为 nil。
    let actualEndTime: Date?
    let isActive: Bool
    let isGap: Bool
    let entries: [UsageEntry]
    let tokenCounts: TokenCounts
    /// 块内各 entry 单独计价后求和。P1 恒为 nil，由 P2 填充。
    let costUSD: Double?
}

/// 把 entry 切成 5 小时计费块。对齐 ccusage `identify_session_blocks`（blocks.rs:17-71）。
///
/// 两个**独立**的开新块条件，均为**严格大于**：
///   1. `entry.ts - blockStart > duration`
///   2. `entry.ts - lastEntry.ts > duration`
/// 仅条件 2 触发时额外插入一个 gap 伪块。
func identifySessionBlocks(_ entries: [UsageEntry],
                           sessionDurationHours: Double = SessionBlockConfig.durationHours,
                           now: Date) -> [SessionBlock] {
    guard !entries.isEmpty else { return [] }
    let duration = sessionDurationHours * 3600
    let sorted = entries.sorted { $0.timestamp < $1.timestamp }

    var blocks: [SessionBlock] = []
    var currentStart: Date?
    var current: [UsageEntry] = []

    for entry in sorted {
        if let start = currentStart {
            let lastTime = current.last?.timestamp ?? start
            let sinceStart = entry.timestamp.timeIntervalSince(start)
            let sinceLast = entry.timestamp.timeIntervalSince(lastTime)
            if sinceStart > duration || sinceLast > duration {
                blocks.append(makeSessionBlock(start: start, entries: current,
                                               now: now, duration: duration))
                if sinceLast > duration {
                    blocks.append(makeGapBlock(last: lastTime, next: entry.timestamp,
                                               duration: duration))
                }
                current = []
                currentStart = floorToUTCHour(entry.timestamp)
            }
        } else {
            currentStart = floorToUTCHour(entry.timestamp)
        }
        current.append(entry)
    }

    if let start = currentStart, !current.isEmpty {
        blocks.append(makeSessionBlock(start: start, entries: current,
                                       now: now, duration: duration))
    }
    return blocks
}

private func makeSessionBlock(start: Date, entries: [UsageEntry],
                              now: Date, duration: TimeInterval) -> SessionBlock {
    let end = start.addingTimeInterval(duration)
    let actualEnd = entries.last?.timestamp
    // 两个条件必须同时成立（blocks.rs:75）
    let isActive = actualEnd.map { now.timeIntervalSince($0) < duration && now < end } ?? false
    var counts = TokenCounts()
    for e in entries { counts += e.counts }
    return SessionBlock(id: iso8601Millis(start), startTime: start, endTime: end,
                        actualEndTime: actualEnd, isActive: isActive, isGap: false,
                        entries: entries, tokenCounts: counts, costUSD: nil)
}

private func makeGapBlock(last: Date, next: Date, duration: TimeInterval) -> SessionBlock {
    let start = last.addingTimeInterval(duration)
    return SessionBlock(id: "gap-\(iso8601Millis(start))", startTime: start, endTime: next,
                        actualEndTime: nil, isActive: false, isGap: true,
                        entries: [], tokenCounts: TokenCounts(), costUSD: nil)
}

private let blockIdFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

private func iso8601Millis(_ date: Date) -> String {
    blockIdFormatter.string(from: date)
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionBlocksTests
```

Expected: `Executed 16 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/SessionBlocks.swift client/VibeCompanion/Tests/SessionBlocksTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 identifySessionBlocks 五小时分块

两个独立的开新块条件（均严格大于），仅"距上条超时"会额外插入
gap 伪块；isActive 需 now 距末条 <5h 且 now < blockEnd 同时成立。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: calculateBurnRate 与档位

**Files:**
- Create: `client/VibeCompanion/Sources/Core/BurnRate.swift`
- Test: `client/VibeCompanion/Tests/BurnRateTests.swift`

**Interfaces:**
- Consumes: `SessionBlock`（Task 4）、`TokenCounts`（Task 1）、`UsageEntry`（Task 3）
- Produces:
  - `struct BurnRate: Equatable` — `tokensPerMinute: Double`、`tokensPerMinuteForIndicator: Double`、`costPerHour: Double?`
  - `func calculateBurnRate(_ block: SessionBlock) -> BurnRate?`
  - `enum BurnRateLevel: Equatable { case normal, moderate, high; static func from(indicator: Double) -> BurnRateLevel }`

**背景：** 分母是**首条 entry → 末条 entry**，不是块起点也不是 now——空闲不稀释速率。这正是 D1 偏离（90s 归零）存在的原因，但归零发生在展示层，本函数不参与。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/BurnRateTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class BurnRateTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_784_937_600)

    private func entry(minuteOffset: Double, counts: TokenCounts) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(minuteOffset * 60),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: counts, isSidechain: false, hasSpeed: false,
                   isFastSpeed: false, dedupKey: "m\(minuteOffset):r")
    }

    private func block(_ entries: [UsageEntry],
                       isGap: Bool = false,
                       costUSD: Double? = nil) -> SessionBlock {
        var counts = TokenCounts()
        for e in entries { counts += e.counts }
        return SessionBlock(id: "b", startTime: base,
                            endTime: base.addingTimeInterval(5 * 3600),
                            actualEndTime: entries.last?.timestamp,
                            isActive: true, isGap: isGap,
                            entries: entries, tokenCounts: counts, costUSD: costUSD)
    }

    // MARK: 三个 nil 守卫

    func testNilForEmptyBlock() {
        XCTAssertNil(calculateBurnRate(block([])))
    }

    func testNilForGapBlock() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 10)),
                 entry(minuteOffset: 10, counts: TokenCounts(input: 10))]
        XCTAssertNil(calculateBurnRate(block(e, isGap: true)))
    }

    /// 单条 entry -> duration == 0 -> nil（不是 0 速率）
    func testNilForSingleEntryBlock() {
        XCTAssertNil(calculateBurnRate(block([entry(minuteOffset: 0, counts: TokenCounts(input: 10))])))
    }

    func testNilWhenAllEntriesShareTimestamp() {
        let e = [entry(minuteOffset: 3, counts: TokenCounts(input: 10)),
                 entry(minuteOffset: 3, counts: TokenCounts(input: 20))]
        XCTAssertNil(calculateBurnRate(block(e)))
    }

    // MARK: 两个分子

    /// tokensPerMinute 用 Total（含 cache_read）；indicator 只用 input+output
    func testTwoNumeratorsDifferOnCacheBuckets() {
        let counts = TokenCounts(input: 100, output: 200, cacheCreation5m: 400,
                                 cacheCreation1h: 800, cacheRead: 1600)
        let e = [entry(minuteOffset: 0, counts: counts),
                 entry(minuteOffset: 10, counts: counts)]
        let r = calculateBurnRate(block(e))!
        // total = 3100 * 2 = 6200，跨 10 分钟
        XCTAssertEqual(r.tokensPerMinute, 620, accuracy: 0.0001)
        // indicator = 300 * 2 = 600，跨 10 分钟
        XCTAssertEqual(r.tokensPerMinuteForIndicator, 60, accuracy: 0.0001)
    }

    /// 分母是首条->末条，与块起点和 now 均无关
    func testDenominatorIsFirstToLastEntry() {
        let e = [entry(minuteOffset: 60, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 62, counts: TokenCounts(input: 100))]
        let r = calculateBurnRate(block(e))!
        XCTAssertEqual(r.tokensPerMinute, 100, accuracy: 0.0001)   // 200 / 2min
    }

    func testCostPerHourUsesSameDenominator() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 30, counts: TokenCounts(input: 100))]
        let r = calculateBurnRate(block(e, costUSD: 1.5))!
        // 1.5 USD / 30min * 60 = 3.0 USD/h
        XCTAssertEqual(r.costPerHour!, 3.0, accuracy: 0.0001)
    }

    func testCostPerHourNilWhenBlockCostNil() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 30, counts: TokenCounts(input: 100))]
        XCTAssertNil(calculateBurnRate(block(e))!.costPerHour)
    }

    // MARK: 档位阈值（对 indicator 生效）

    func testLevelBoundaries() {
        XCTAssertEqual(BurnRateLevel.from(indicator: 0), .normal)
        XCTAssertEqual(BurnRateLevel.from(indicator: 1999.9), .normal)
        XCTAssertEqual(BurnRateLevel.from(indicator: 2000), .moderate)
        XCTAssertEqual(BurnRateLevel.from(indicator: 4999.9), .moderate)
        XCTAssertEqual(BurnRateLevel.from(indicator: 5000), .high)
        XCTAssertEqual(BurnRateLevel.from(indicator: 100_000), .high)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BurnRateTests
```

Expected: 编译失败，`cannot find 'calculateBurnRate' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/BurnRate.swift`：

```swift
import Foundation

/// token 消耗速率。对齐 ccusage `BurnRate`（blocks.rs:535-552）。
struct BurnRate: Equatable {
    /// 主速率：分子为 `TokenCounts.total`（**含** cache_read）。
    /// 驱动速度表指针、数字与配色。
    let tokensPerMinute: Double
    /// 档位速率：分子仅 `input + output`（两个 cache 桶均排除）。
    /// ccusage 用它保持与 prompt cache 出现之前的阈值可比。
    let tokensPerMinuteForIndicator: Double
    /// `costUSD / durationMinutes * 60`；块无 cost 时为 nil。
    let costPerHour: Double?
}

/// 档位阈值。对齐 ccusage statusline（commands/mod.rs:467-473）。
///
/// 注意：v17 时代的 `{HIGH: 1000, MODERATE: 500}` 已随 live monitor
/// 在 v18 移除，**不要使用**。
enum BurnRateLevel: Equatable {
    case normal, moderate, high

    static let moderateThreshold: Double = 2000
    static let highThreshold: Double = 5000

    /// 判定依据是 `tokensPerMinuteForIndicator`，**不是** `tokensPerMinute`。
    static func from(indicator: Double) -> BurnRateLevel {
        if indicator < moderateThreshold { return .normal }
        if indicator < highThreshold { return .moderate }
        return .high
    }
}

/// 计算块的 burn rate。对齐 ccusage `calculate_burn_rate`（blocks.rs:535-552）。
///
/// 分母是**首条 entry → 末条 entry**，不是块起点，也不是 now——
/// 因此空闲时间不会稀释速率，速率会"冻结"。展示层的空闲归零
/// （偏离 D1）在别处处理，本函数保持与 ccusage 一致。
func calculateBurnRate(_ block: SessionBlock) -> BurnRate? {
    guard !block.entries.isEmpty, !block.isGap else { return nil }
    guard let first = block.entries.first?.timestamp,
          let last = block.entries.last?.timestamp else { return nil }

    let durationMinutes = last.timeIntervalSince(first) / 60
    guard durationMinutes > 0 else { return nil }

    return BurnRate(
        tokensPerMinute: Double(block.tokenCounts.total) / durationMinutes,
        tokensPerMinuteForIndicator: Double(block.tokenCounts.inputPlusOutput) / durationMinutes,
        costPerHour: block.costUSD.map { $0 / durationMinutes * 60 }
    )
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter BurnRateTests
```

Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/BurnRate.swift client/VibeCompanion/Tests/BurnRateTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 calculateBurnRate 与档位阈值

分母为首条->末条 entry；主速率用 Total（含 cache_read），档位速率
仅用 input+output，阈值 2000/5000（v18 后的现行值）。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: UsageWindow 有界有序窗口

**Files:**
- Create: `client/VibeCompanion/Sources/Core/UsageWindow.swift`
- Test: `client/VibeCompanion/Tests/UsageWindowTests.swift`

**Interfaces:**
- Consumes: `UsageEntry`（Task 3）、`shouldReplace`（Task 3）
- Produces: `final class UsageWindow` — `init(retentionHours: Double = 6)`、`@discardableResult func insert(_ entry: UsageEntry) -> Bool`、`func evict(now: Date)`、`func snapshot() -> [UsageEntry]`、`var count: Int`

**背景：** 这是架构方案 C 的载体。多个 session 文件由 FSEvents 并发触发、回扫与实时 tail 交错，**到达顺序不等于时间戳顺序**，而分块规则对顺序敏感，所以必须有序插入。保留窗口 6 小时的推导见 spec 6.2。

替换发生时旧条目须先从有序数组移除再插入新条目——新旧 timestamp 可能不同，不能原地覆盖。数组规模上界约 1000（实测最大块 716 条），故移除用线性查找即可。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/UsageWindowTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class UsageWindowTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_784_937_600)

    private func entry(min: Double, total: Int = 10, key: String?,
                       isSidechain: Bool = false, hasSpeed: Bool = false) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(min * 60),
                   agent: "claude", sessionId: nil, model: nil,
                   counts: TokenCounts(input: total),
                   isSidechain: isSidechain, hasSpeed: hasSpeed,
                   isFastSpeed: false, dedupKey: key)
    }

    func testInsertKeepsSortedOrderDespiteUnorderedArrival() {
        let w = UsageWindow()
        w.insert(entry(min: 30, key: "c"))
        w.insert(entry(min: 10, key: "a"))
        w.insert(entry(min: 20, key: "b"))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["a", "b", "c"])
    }

    func testDuplicateKeyWithLowerTotalIsRejected() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 100, key: "k"))
        XCTAssertFalse(w.insert(entry(min: 1, total: 50, key: "k")))
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.snapshot()[0].counts.total, 100)
    }

    /// 替换时旧条目必须从有序数组移除，不能残留
    func testReplacementRemovesOldEntryFromArray() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 100, key: "k"))
        XCTAssertTrue(w.insert(entry(min: 5, total: 200, key: "k")))
        XCTAssertEqual(w.count, 1)
        let only = w.snapshot()[0]
        XCTAssertEqual(only.counts.total, 200)
        XCTAssertEqual(only.timestamp, base.addingTimeInterval(5 * 60))
    }

    func testReplacementKeepsArraySorted() {
        let w = UsageWindow()
        w.insert(entry(min: 10, total: 100, key: "a"))
        w.insert(entry(min: 20, total: 100, key: "b"))
        // b 的替代条目时间戳提前到 5min，应重新排到最前
        w.insert(entry(min: 5, total: 999, key: "b"))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["b", "a"])
    }

    func testSidechainPriorityAppliesOnInsert() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 500, key: "k", isSidechain: true))
        // 非 sidechain 即使 token 更少也应取代
        XCTAssertTrue(w.insert(entry(min: 0, total: 1, key: "k", isSidechain: false)))
        XCTAssertEqual(w.snapshot()[0].counts.total, 1)
    }

    /// dedupKey == nil 的条目永不去重，可重复插入
    func testNilKeyEntriesAreNeverDeduped() {
        let w = UsageWindow()
        w.insert(entry(min: 0, key: nil))
        w.insert(entry(min: 0, key: nil))
        w.insert(entry(min: 0, key: nil))
        XCTAssertEqual(w.count, 3)
    }

    // MARK: 驱逐

    func testEvictDropsEntriesOlderThanRetention() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, key: "old"))          // base
        w.insert(entry(min: 60 * 5, key: "keep"))    // base + 5h
        w.evict(now: base.addingTimeInterval(6.5 * 3600))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["keep"])
    }

    func testEvictBoundaryIsInclusiveOfCutoff() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, key: "atCutoff"))
        // now - 6h == entry.timestamp，恰好在边界上，应保留
        w.evict(now: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(w.count, 1)
    }

    func testEvictAlsoClearsDedupIndex() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, total: 100, key: "k"))
        w.evict(now: base.addingTimeInterval(7 * 3600))
        XCTAssertEqual(w.count, 0)
        // 索引已清，同键条目应能重新插入（即使 token 更少）
        XCTAssertTrue(w.insert(entry(min: 60 * 7, total: 1, key: "k")))
        XCTAssertEqual(w.count, 1)
    }

    func testEvictOnEmptyWindowIsNoop() {
        let w = UsageWindow()
        w.evict(now: base)
        XCTAssertEqual(w.count, 0)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageWindowTests
```

Expected: 编译失败，`cannot find 'UsageWindow' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/UsageWindow.swift`：

```swift
import Foundation

/// 有界、有序、自去重的 entry 窗口。
///
/// 架构方案 C 的载体：只保留最近 `retentionHours` 小时的原始 entry，
/// 每次变化后对这个有界集合重跑 ccusage 的分块与 burn rate。
/// 这样既拿到"全量重算"的正确性（乱序免疫、可实现去重替换语义），
/// 又有确定的内存上界。
///
/// **非线程安全**——调用方需保证串行访问（P3 中由 `@MainActor` 保证）。
final class UsageWindow {
    /// 按 timestamp 升序。
    private var sorted: [UsageEntry] = []
    /// dedupKey -> 当前留存的条目。
    private var byKey: [String: UsageEntry] = [:]
    private let retention: TimeInterval

    init(retentionHours: Double = 6) {
        self.retention = retentionHours * 3600
    }

    var count: Int { sorted.count }

    /// 插入一条 entry。返回 false 表示因去重被拒绝。
    @discardableResult
    func insert(_ entry: UsageEntry) -> Bool {
        if let key = entry.dedupKey {
            if let existing = byKey[key] {
                guard shouldReplace(candidate: entry, existing: existing) else { return false }
                remove(existing)
            }
            byKey[key] = entry
        }
        insertSorted(entry)
        return true
    }

    /// 丢弃 timestamp 早于 `now - retention` 的条目。边界值保留。
    func evict(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let keepFrom = sorted.firstIndex { $0.timestamp >= cutoff } ?? sorted.count
        guard keepFrom > 0 else { return }
        for e in sorted[..<keepFrom] {
            if let k = e.dedupKey, byKey[k] == e { byKey.removeValue(forKey: k) }
        }
        sorted.removeFirst(keepFrom)
    }

    /// 有序、已去重的快照，可直接喂给 `identifySessionBlocks`。
    func snapshot() -> [UsageEntry] { sorted }

    // MARK: - private

    /// 二分查找插入位置，保持稳定（同 timestamp 时后插入者靠后）。
    private func insertSorted(_ entry: UsageEntry) {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].timestamp <= entry.timestamp { lo = mid + 1 } else { hi = mid }
        }
        sorted.insert(entry, at: lo)
    }

    /// 线性查找移除。数组规模上界约 1000（实测最大块 716 条），无需优化。
    private func remove(_ entry: UsageEntry) {
        if let i = sorted.firstIndex(where: { $0 == entry }) {
            sorted.remove(at: i)
        }
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UsageWindowTests
```

Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 5: 跑全量测试确认没破坏现有行为**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: 原有 23 个测试 + 本计划新增 54 个，全部通过。

- [ ] **Step 6: 提交**

```bash
git add client/VibeCompanion/Sources/Core/UsageWindow.swift client/VibeCompanion/Tests/UsageWindowTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 UsageWindow 有界有序窗口

二分插入保证乱序到达仍有序；承载去重替换语义（替换时旧条目
从有序数组移除后重新插入）；按 6 小时保留窗口驱逐。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 完成标准

P1 完成时：

- `Core/` 下新增 6 个文件，全部不含 I/O，不 import 除 Foundation 外的框架
- 新增 54 个测试全部通过，原有 23 个测试不受影响
- 现有 app 行为**完全未变**——`TokenAggregator`、`Collector`、速度表仍走旧逻辑
- P3 可以直接消费 `UsageWindow` + `identifySessionBlocks` + `calculateBurnRate` 这条链路
