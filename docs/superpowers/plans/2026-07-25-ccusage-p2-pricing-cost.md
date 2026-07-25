# P2 定价与 Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 复刻 ccusage 的定价解析、模型名解析与 cost 计算，产出可注入的 `PricingSource`。

**Architecture:** 计算部分（`ModelPricing` / 模型名解析 / `calculateCost`）是纯函数，放 `Core/`；带 I/O 的 `PricingStore`（内置快照 + 磁盘缓存 + 线上抓取）通过 `PricingSource` 协议与计算层隔离，使 cost 单测无需联网。本计划**不修改** P1 产出，也不修改任何现有文件。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest / Foundation URLSession / macOS 13+

依赖：P1 的 `TokenCounts`。若 P1 尚未完成，本计划无法编译。
设计文档：`docs/superpowers/specs/2026-07-25-ccusage-burnrate-design.md` 第 5.5 节

## Global Constraints

- **测试命令必须带 `DEVELOPER_DIR`**：`cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`
- **`CostCalculator` 与模型名解析不得发起网络请求或读文件**，只能依赖注入的 `PricingSource`。仅 `PricingStore` 允许 I/O。
- **单价是极小的浮点数**（如 `5e-6`）。所有浮点断言必须带 `accuracy`，取值不大于期望值的 1e-9 倍量级；直接用 `XCTAssertEqual` 比较 `Double` 会因累加误差随机失败。
- **数值必须与 ccusage 一致。** 1 小时缓存单价是 `input × 2.0` 的**硬编码倍率**，不是 LiteLLM 的 key，也不是从 cache_creation 单价推导。
- 提交信息用中文，结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## File Structure

| 文件 | 职责 |
|---|---|
| `Core/ModelPricing.swift` | 单模型定价结构 + LiteLLM JSON 解码与缺省值规则 |
| `Core/PricingResolver.swift` | 模型名四步解析（精确 / 归一化 / 模糊 / 别名） |
| `Core/CostCalculator.swift` | `tieredCost` + `calculateCost` |
| `Core/PricingStore.swift` | `PricingSource` 实现：内置快照 → 磁盘缓存 → 线上抓取 |
| `Resources/litellm-pricing-snapshot.json` | 内置定价快照 |

---

### Task 1: ModelPricing 与 LiteLLM 解码

**Files:**
- Create: `client/VibeCompanion/Sources/Core/ModelPricing.swift`
- Test: `client/VibeCompanion/Tests/ModelPricingTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct ModelPricing: Equatable` — `input/output/cacheCreate/cacheRead: Double`、`cacheReadExplicit: Bool`、`inputAbove200k/outputAbove200k/cacheCreateAbove200k/cacheReadAbove200k: Double?`、`longContextThreshold: Int?`、`fastMultiplier: Double`
  - `enum PricingDefaults` — `cacheCreateMultiplier: Double = 1.25`、`cacheReadMultiplier: Double = 0.1`
  - `extension ModelPricing { init?(liteLLM: [String: Any]) }`
  - `func decodeLiteLLMPricing(_ json: [String: Any]) -> [String: ModelPricing]`

**背景：** LiteLLM 条目缺 `input_cost_per_token` 或 `output_cost_per_token` 时**整条跳过**。缺省规则：`cache_creation_input_token_cost` 缺失时为 `input × 1.25`；`cache_read_input_token_cost` 缺失时为 `input × 0.1`，且必须**记住它是否显式给出**（Codex 的计价分支依赖这个标志）。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/ModelPricingTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class ModelPricingTests: XCTestCase {

    private let eps = 1e-15

    func testDecodesAllExplicitFields() {
        let json: [String: Any] = [
            "input_cost_per_token": 5e-6,
            "output_cost_per_token": 25e-6,
            "cache_creation_input_token_cost": 6.25e-6,
            "cache_read_input_token_cost": 0.5e-6,
            "input_cost_per_token_above_200k_tokens": 10e-6,
            "output_cost_per_token_above_200k_tokens": 50e-6,
            "cache_creation_input_token_cost_above_200k_tokens": 12.5e-6,
            "cache_read_input_token_cost_above_200k_tokens": 1e-6,
        ]
        let p = ModelPricing(liteLLM: json)!
        XCTAssertEqual(p.input, 5e-6, accuracy: eps)
        XCTAssertEqual(p.output, 25e-6, accuracy: eps)
        XCTAssertEqual(p.cacheCreate, 6.25e-6, accuracy: eps)
        XCTAssertEqual(p.cacheRead, 0.5e-6, accuracy: eps)
        XCTAssertTrue(p.cacheReadExplicit)
        XCTAssertEqual(p.inputAbove200k!, 10e-6, accuracy: eps)
        XCTAssertEqual(p.outputAbove200k!, 50e-6, accuracy: eps)
        XCTAssertEqual(p.cacheCreateAbove200k!, 12.5e-6, accuracy: eps)
        XCTAssertEqual(p.cacheReadAbove200k!, 1e-6, accuracy: eps)
    }

    /// 缺 input 或 output -> 整条跳过
    func testReturnsNilWhenInputMissing() {
        XCTAssertNil(ModelPricing(liteLLM: ["output_cost_per_token": 25e-6]))
    }

    func testReturnsNilWhenOutputMissing() {
        XCTAssertNil(ModelPricing(liteLLM: ["input_cost_per_token": 5e-6]))
    }

    /// cacheCreate 缺省 = input × 1.25
    func testCacheCreateDefaultsToInputTimes125() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.cacheCreate, 5e-6, accuracy: eps)
    }

    /// cacheRead 缺省 = input × 0.1，且 explicit 标志为 false
    func testCacheReadDefaultsToInputTimes01AndMarksImplicit() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.cacheRead, 0.4e-6, accuracy: eps)
        XCTAssertFalse(p.cacheReadExplicit)
    }

    func testAbove200kFieldsAreNilWhenAbsent() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertNil(p.inputAbove200k)
        XCTAssertNil(p.outputAbove200k)
        XCTAssertNil(p.cacheCreateAbove200k)
        XCTAssertNil(p.cacheReadAbove200k)
    }

    func testFastMultiplierDefaultsToOne() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.fastMultiplier, 1.0, accuracy: eps)
    }

    func testFastMultiplierReadFromProviderSpecificEntry() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6,
                                       "provider_specific_entry": ["fast": 2.5]])!
        XCTAssertEqual(p.fastMultiplier, 2.5, accuracy: eps)
    }

    // MARK: 整表解码

    func testDecodeTableSkipsInvalidEntriesAndKeepsValid() {
        let table: [String: Any] = [
            "claude-opus-5": ["input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6],
            "broken-model": ["input_cost_per_token": 5e-6],           // 缺 output
            "sample_spec": ["note": "LiteLLM 表里的非模型条目"],
        ]
        let decoded = decodeLiteLLMPricing(table)
        XCTAssertEqual(Set(decoded.keys), ["claude-opus-5"])
        XCTAssertEqual(decoded["claude-opus-5"]!.input, 5e-6, accuracy: eps)
    }

    func testDecodeTableHandlesEmptyInput() {
        XCTAssertTrue(decodeLiteLLMPricing([:]).isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelPricingTests
```

Expected: 编译失败，`cannot find 'ModelPricing' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/ModelPricing.swift`：

```swift
import Foundation

/// 定价缺省规则。对齐 ccusage pricing.rs:315-318。
enum PricingDefaults {
    static let cacheCreateMultiplier: Double = 1.25
    static let cacheReadMultiplier: Double = 0.1
}

/// 单个模型的定价。对齐 ccusage `Pricing`（pricing.rs:28-45）。
struct ModelPricing: Equatable {
    let input: Double
    let output: Double
    let cacheCreate: Double
    let cacheRead: Double
    /// `cache_read_input_token_cost` 是否显式给出。
    /// Codex 的计价分支依赖它：未显式给出时 cached 按**完整 input 单价**计费，
    /// 而不是 Claude 路径的 `input × 0.1` 缺省。
    let cacheReadExplicit: Bool

    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheCreateAbove200k: Double?
    let cacheReadAbove200k: Double?

    /// 非 nil 时走 OpenAI 的"整请求选档"分支（由 input_tokens 单独决定档位）。
    /// Anthropic 模型为 nil，走按桶边际分段。
    let longContextThreshold: Int?
    let fastMultiplier: Double
}

extension ModelPricing {
    /// 从一条 LiteLLM 模型条目解码。缺 input 或 output 时返回 nil（整条跳过）。
    init?(liteLLM json: [String: Any]) {
        guard let input = json["input_cost_per_token"] as? Double,
              let output = json["output_cost_per_token"] as? Double else { return nil }

        let explicitCacheRead = json["cache_read_input_token_cost"] as? Double

        self.input = input
        self.output = output
        self.cacheCreate = (json["cache_creation_input_token_cost"] as? Double)
            ?? input * PricingDefaults.cacheCreateMultiplier
        self.cacheRead = explicitCacheRead ?? input * PricingDefaults.cacheReadMultiplier
        self.cacheReadExplicit = explicitCacheRead != nil

        self.inputAbove200k = json["input_cost_per_token_above_200k_tokens"] as? Double
        self.outputAbove200k = json["output_cost_per_token_above_200k_tokens"] as? Double
        self.cacheCreateAbove200k = json["cache_creation_input_token_cost_above_200k_tokens"] as? Double
        self.cacheReadAbove200k = json["cache_read_input_token_cost_above_200k_tokens"] as? Double

        // Anthropic 模型不设该阈值；OpenAI 的由 builtin 覆盖表补入（Task 4）。
        self.longContextThreshold = nil

        let providerEntry = json["provider_specific_entry"] as? [String: Any]
        self.fastMultiplier = (providerEntry?["fast"] as? Double) ?? 1.0
    }
}

/// 解码整张 LiteLLM 表，跳过所有非法/非模型条目。
func decodeLiteLLMPricing(_ json: [String: Any]) -> [String: ModelPricing] {
    var out: [String: ModelPricing] = [:]
    for (name, value) in json {
        guard let entry = value as? [String: Any],
              let pricing = ModelPricing(liteLLM: entry) else { continue }
        out[name] = pricing
    }
    return out
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ModelPricingTests
```

Expected: `Executed 11 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/ModelPricing.swift client/VibeCompanion/Tests/ModelPricingTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 ModelPricing 与 LiteLLM 解码

缺 input/output 的条目整条跳过；cacheCreate 缺省 input×1.25，
cacheRead 缺省 input×0.1 并记录是否显式给出。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 模型名解析

**Files:**
- Create: `client/VibeCompanion/Sources/Core/PricingResolver.swift`
- Test: `client/VibeCompanion/Tests/PricingResolverTests.swift`

**Interfaces:**
- Consumes: `ModelPricing`（Task 1）
- Produces:
  - `protocol PricingSource { func pricing(for model: String) -> ModelPricing? }`
  - `func normalizedPricingKey(_ s: String) -> String`
  - `func containsPricingKey(_ haystack: String, _ needle: String) -> Bool`
  - `struct PricingTable: PricingSource` — `init(entries: [String: ModelPricing], aliases: [String: String] = [:])`，`func pricing(for:) -> ModelPricing?`

**背景（匹配规则，逐条对应 ccusage pricing.rs:1243-1298）：**
1. 精确哈希查找
2. 归一化：`.` 与 `@` 替换为 `-`
3. 双向边界感知子串匹配，**最长 key 胜**，同长时字典序小者胜
   - 匹配起点前一字符须非字母数字（或为串首）
   - 匹配终点后一字符须非字母数字（或为串尾）
   - 若 key 以数字结尾且其后紧跟 `-<数字串>`，**拒绝**——除非该数字串恰好 **8** 位（Anthropic 的 `YYYYMMDD`）
4. 别名表

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/PricingResolverTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class PricingResolverTests: XCTestCase {

    private func p(_ input: Double) -> ModelPricing {
        ModelPricing(input: input, output: input * 5, cacheCreate: input * 1.25,
                     cacheRead: input * 0.1, cacheReadExplicit: false,
                     inputAbove200k: nil, outputAbove200k: nil,
                     cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                     longContextThreshold: nil, fastMultiplier: 1.0)
    }

    // MARK: 归一化

    func testNormalizeReplacesDotsAndAts() {
        XCTAssertEqual(normalizedPricingKey("claude-3.5-sonnet"), "claude-3-5-sonnet")
        XCTAssertEqual(normalizedPricingKey("claude-opus-4-8@default"), "claude-opus-4-8-default")
    }

    // MARK: 边界规则

    func testContainsRequiresNonAlphanumericBoundaryBefore() {
        // "opus" 出现在 "xopus-5" 中，但前一字符是字母 -> 不算匹配
        XCTAssertFalse(containsPricingKey("xopus-5", "opus"))
        XCTAssertTrue(containsPricingKey("x-opus-5", "opus"))
    }

    func testContainsAllowsMatchAtStart() {
        XCTAssertTrue(containsPricingKey("claude-opus-5", "claude"))
    }

    func testContainsAllowsExactEquality() {
        XCTAssertTrue(containsPricingKey("claude-opus-5", "claude-opus-5"))
    }

    func testContainsRejectsAlphanumericSuffix() {
        XCTAssertFalse(containsPricingKey("claude-opusX", "claude-opus"))
    }

    /// 8 位日期后缀允许剥离
    func testEightDigitDateSuffixIsAllowed() {
        XCTAssertTrue(containsPricingKey("claude-haiku-4-5-20251001", "claude-haiku-4-5"))
    }

    /// 非 8 位的数字后缀视为不同版本，拒绝
    func testNonEightDigitVersionSuffixIsRejected() {
        XCTAssertFalse(containsPricingKey("claude-opus-4-5", "claude-opus-4"))
        XCTAssertFalse(containsPricingKey("claude-opus-4-812", "claude-opus-4"))
    }

    // MARK: PricingTable.pricing(for:)

    func testExactLookupWins() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6), "claude": p(1e-6)])
        XCTAssertEqual(t.pricing(for: "claude-opus-5")!.input, 5e-6, accuracy: 1e-15)
    }

    func testProviderPrefixedModelMatchesBareKey() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertEqual(t.pricing(for: "anthropic/claude-opus-5")!.input, 5e-6, accuracy: 1e-15)
    }

    func testDatedModelMatchesUndatedKey() {
        let t = PricingTable(entries: ["claude-haiku-4-5": p(1e-6)])
        XCTAssertEqual(t.pricing(for: "claude-haiku-4-5-20251001")!.input, 1e-6, accuracy: 1e-15)
    }

    func testLongestMatchingKeyWins() {
        let t = PricingTable(entries: ["claude": p(1e-6),
                                       "claude-opus": p(2e-6),
                                       "claude-opus-5": p(3e-6)])
        XCTAssertEqual(t.pricing(for: "anthropic/claude-opus-5")!.input, 3e-6, accuracy: 1e-15)
    }

    func testDotNormalizationEnablesMatch() {
        let t = PricingTable(entries: ["claude-3-5-sonnet": p(3e-6)])
        XCTAssertEqual(t.pricing(for: "claude-3.5-sonnet")!.input, 3e-6, accuracy: 1e-15)
    }

    func testAliasTableIsConsulted() {
        let t = PricingTable(entries: ["gpt-5.3-codex-spark": p(7e-6)],
                             aliases: ["gpt-5.3-spark": "gpt-5.3-codex-spark"])
        XCTAssertEqual(t.pricing(for: "gpt-5.3-spark")!.input, 7e-6, accuracy: 1e-15)
    }

    func testMissReturnsNil() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertNil(t.pricing(for: "totally-unknown-model"))
    }

    /// `<synthetic>` 永远命中不了
    func testSyntheticModelNeverMatches() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertNil(t.pricing(for: "<synthetic>"))
    }

    func testOpusFourDoesNotMatchOpusFourFive() {
        let t = PricingTable(entries: ["claude-opus-4": p(1e-6)])
        XCTAssertNil(t.pricing(for: "claude-opus-4-5"))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PricingResolverTests
```

Expected: 编译失败，`cannot find 'PricingTable' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/PricingResolver.swift`：

```swift
import Foundation

/// 定价来源。计算层只依赖这个协议，不关心定价从哪来——
/// 这使 cost 单测无需联网或读文件。
protocol PricingSource {
    func pricing(for model: String) -> ModelPricing?
}

/// Anthropic 的日期后缀位数（`YYYYMMDD`）。
/// 对齐 ccusage `MODEL_DATE_SUFFIX_DIGITS`。
private let modelDateSuffixDigits = 8

/// `.` 与 `@` 归一化为 `-`。对齐 ccusage `normalized_pricing_key`。
func normalizedPricingKey(_ s: String) -> String {
    s.replacingOccurrences(of: ".", with: "-")
     .replacingOccurrences(of: "@", with: "-")
}

/// 边界感知的子串包含判定。对齐 ccusage `contains_pricing_key`
/// 与 `suffix_starts_with_numeric_model_version`（pricing.rs:1243-1298）。
///
/// - 匹配起点前一字符须非字母数字（或为串首）
/// - 匹配终点后一字符须非字母数字（或为串尾）
/// - key 以数字结尾且后接 `-<数字串>` 时拒绝，除非数字串恰好 8 位
func containsPricingKey(_ haystack: String, _ needle: String) -> Bool {
    guard !needle.isEmpty else { return false }
    let h = Array(haystack), n = Array(needle)
    guard h.count >= n.count else { return false }

    for start in 0...(h.count - n.count) {
        guard Array(h[start..<(start + n.count)]) == n else { continue }

        // 前边界
        if start > 0 {
            let prev = h[start - 1]
            if prev.isLetter || prev.isNumber { continue }
        }

        let end = start + n.count
        if end < h.count {
            let next = h[end]
            // 后边界
            if next.isLetter || next.isNumber { continue }
            // 版本号后缀规则
            if let lastChar = n.last, lastChar.isNumber, next == "-" {
                let digits = h[(end + 1)...].prefix { $0.isNumber }
                if !digits.isEmpty && digits.count != modelDateSuffixDigits { continue }
            }
        }
        return true
    }
    return false
}

/// 一张可查询的定价表。
struct PricingTable: PricingSource {
    private let entries: [String: ModelPricing]
    private let aliases: [String: String]

    init(entries: [String: ModelPricing], aliases: [String: String] = [:]) {
        self.entries = entries
        self.aliases = aliases
    }

    /// 四步解析：精确 → 归一化+模糊（最长胜） → 别名 → nil。
    func pricing(for model: String) -> ModelPricing? {
        if let exact = entries[model] { return exact }
        if let fuzzy = fuzzyLookup(model) { return fuzzy }
        if let aliased = aliases[model] {
            if let exact = entries[aliased] { return exact }
            return fuzzyLookup(aliased)
        }
        return nil
    }

    private func fuzzyLookup(_ model: String) -> ModelPricing? {
        let normalizedModel = normalizedPricingKey(model)
        let matched = entries.filter { key, _ in
            matches(candidate: key, model: model, normalizedModel: normalizedModel)
        }
        // 最长 key 胜；同长时字典序小者胜
        return matched.max { a, b in
            if a.key.count != b.key.count { return a.key.count < b.key.count }
            return a.key > b.key
        }?.value
    }

    private func matches(candidate: String, model: String, normalizedModel: String) -> Bool {
        if containsPricingKey(candidate, model) || containsPricingKey(model, candidate) {
            return true
        }
        let normalizedCandidate = normalizedPricingKey(candidate)
        return containsPricingKey(normalizedCandidate, normalizedModel)
            || containsPricingKey(normalizedModel, normalizedCandidate)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PricingResolverTests
```

Expected: `Executed 17 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/PricingResolver.swift client/VibeCompanion/Tests/PricingResolverTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 PricingSource 协议与模型名四步解析

边界感知的双向子串匹配，最长 key 胜；8 位日期后缀可剥离，
故 claude-haiku-4-5 命中 ...-20251001 而 claude-opus-4 不命中 -4-5。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: tieredCost 与 calculateCost

**Files:**
- Create: `client/VibeCompanion/Sources/Core/CostCalculator.swift`
- Test: `client/VibeCompanion/Tests/CostCalculatorTests.swift`

**Interfaces:**
- Consumes: `TokenCounts`（P1 Task 1）、`ModelPricing`（Task 1）、`PricingSource`（Task 2）
- Produces:
  - `enum CostConfig` — `cacheCreate1hInputMultiplier: Double = 2.0`、`defaultLongContextThreshold: Int = 200_000`
  - `func tieredCost(_ tokens: Int, base: Double, above: Double?, threshold: Int) -> Double`
  - `func calculateCost(counts: TokenCounts, pricing: ModelPricing, isFast: Bool) -> Double`
  - `func calculateCost(counts: TokenCounts, model: String?, isFast: Bool, source: PricingSource) -> Double?`

**背景：** 实测本机 375 条 entry 的 `cache_read` 超过 200K（最大 460,590），分段计价真实触发；990 条 `1h > 0`、1624 条 `5m > 0`，两档缓存都真实存在。任何简化都会改变数值。

模型名未命中时返回 `nil`（调用方记为无 cost），**不报错、不跳过该 entry 的 token**。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/CostCalculatorTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class CostCalculatorTests: XCTestCase {

    private let eps = 1e-12

    private func pricing(input: Double = 5e-6,
                         output: Double = 25e-6,
                         cacheCreate: Double = 6.25e-6,
                         cacheRead: Double = 0.5e-6,
                         cacheReadExplicit: Bool = true,
                         inputAbove: Double? = nil,
                         outputAbove: Double? = nil,
                         cacheCreateAbove: Double? = nil,
                         cacheReadAbove: Double? = nil,
                         longContextThreshold: Int? = nil,
                         fastMultiplier: Double = 1.0) -> ModelPricing {
        ModelPricing(input: input, output: output, cacheCreate: cacheCreate,
                     cacheRead: cacheRead, cacheReadExplicit: cacheReadExplicit,
                     inputAbove200k: inputAbove, outputAbove200k: outputAbove,
                     cacheCreateAbove200k: cacheCreateAbove, cacheReadAbove200k: cacheReadAbove,
                     longContextThreshold: longContextThreshold, fastMultiplier: fastMultiplier)
    }

    // MARK: tieredCost

    func testTieredCostZeroTokensIsZero() {
        XCTAssertEqual(tieredCost(0, base: 5e-6, above: 10e-6, threshold: 200_000), 0, accuracy: eps)
    }

    func testTieredCostBelowThresholdUsesBaseRate() {
        XCTAssertEqual(tieredCost(1000, base: 5e-6, above: 10e-6, threshold: 200_000),
                       1000 * 5e-6, accuracy: eps)
    }

    func testTieredCostExactlyAtThresholdUsesBaseRate() {
        XCTAssertEqual(tieredCost(200_000, base: 5e-6, above: 10e-6, threshold: 200_000),
                       200_000 * 5e-6, accuracy: eps)
    }

    /// 超出部分按 above 单价，是**边际**分段而非整体换档
    func testTieredCostAboveThresholdIsMarginal() {
        let got = tieredCost(300_000, base: 5e-6, above: 10e-6, threshold: 200_000)
        XCTAssertEqual(got, 200_000 * 5e-6 + 100_000 * 10e-6, accuracy: eps)
    }

    /// above 为 nil 时不分段，全部按 base
    func testTieredCostWithoutAboveRateDoesNotSplit() {
        XCTAssertEqual(tieredCost(300_000, base: 5e-6, above: nil, threshold: 200_000),
                       300_000 * 5e-6, accuracy: eps)
    }

    // MARK: calculateCost —— 五个桶

    func testEachBucketBilledAtItsOwnRate() {
        let c = TokenCounts(input: 1000, output: 2000, cacheCreation5m: 3000,
                            cacheCreation1h: 4000, cacheRead: 5000)
        let p = pricing()
        let expected = 1000 * 5e-6            // input
                     + 2000 * 25e-6           // output
                     + 3000 * 6.25e-6         // cacheCreate 5m
                     + 4000 * (5e-6 * 2.0)    // cacheCreate 1h = input × 2.0
                     + 5000 * 0.5e-6          // cacheRead
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    /// 1h 单价是 input×2.0，**不是** cacheCreate×2.0
    func testOneHourCacheRateDerivesFromInputNotCacheCreate() {
        let c = TokenCounts(cacheCreation1h: 1000)
        let p = pricing(input: 5e-6, cacheCreate: 999e-6)   // cacheCreate 故意设得很离谱
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false),
                       1000 * 10e-6, accuracy: eps)
    }

    func testExtraTotalIsNotBilled() {
        let c = TokenCounts(input: 1000, extraTotal: 999_999)
        XCTAssertEqual(calculateCost(counts: c, pricing: pricing(), isFast: false),
                       1000 * 5e-6, accuracy: eps)
    }

    // MARK: 分段（Anthropic 路径：按桶边际）

    func testPerBucketMarginalTiering() {
        let c = TokenCounts(cacheRead: 460_590)
        let p = pricing(cacheRead: 0.5e-6, cacheReadAbove: 1e-6)
        let expected = 200_000 * 0.5e-6 + 260_590 * 1e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    func testOneHourAboveRateIsInputAboveTimesTwo() {
        let c = TokenCounts(cacheCreation1h: 300_000)
        let p = pricing(input: 5e-6, inputAbove: 10e-6)
        let expected = 200_000 * (5e-6 * 2.0) + 100_000 * (10e-6 * 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    // MARK: OpenAI 路径（整请求选档，由 input 决定）

    func testOpenAIPathSelectsTierByInputTokensForAllBuckets() {
        let c = TokenCounts(input: 300_000, output: 1000, cacheRead: 1000)
        let p = pricing(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6,
                        inputAbove: 10e-6, outputAbove: 50e-6, cacheReadAbove: 1e-6,
                        longContextThreshold: 272_000)
        // input 超阈值 -> 所有桶整体按 above 单价
        let expected = 300_000 * 10e-6 + 1000 * 50e-6 + 1000 * 1e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    func testOpenAIPathBelowThresholdUsesBaseRatesEverywhere() {
        let c = TokenCounts(input: 1000, output: 1000, cacheRead: 300_000)
        let p = pricing(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6,
                        inputAbove: 10e-6, outputAbove: 50e-6, cacheReadAbove: 1e-6,
                        longContextThreshold: 272_000)
        // input 未超阈值 -> 即使 cacheRead 很大也全用 base
        let expected = 1000 * 5e-6 + 1000 * 25e-6 + 300_000 * 0.5e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    // MARK: fast 倍率

    func testFastMultiplierScalesWholeCost() {
        let c = TokenCounts(input: 1000)
        let p = pricing(fastMultiplier: 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: true),
                       1000 * 5e-6 * 2.0, accuracy: eps)
    }

    func testStandardSpeedIgnoresMultiplier() {
        let c = TokenCounts(input: 1000)
        let p = pricing(fastMultiplier: 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false),
                       1000 * 5e-6, accuracy: eps)
    }

    // MARK: 经由 PricingSource 的重载

    func testSourceOverloadResolvesModel() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        let c = TokenCounts(input: 1000)
        let got = calculateCost(counts: c, model: "claude-opus-5", isFast: false, source: table)
        XCTAssertEqual(got!, 1000 * 5e-6, accuracy: eps)
    }

    func testSourceOverloadReturnsNilOnMiss() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        let c = TokenCounts(input: 1000)
        XCTAssertNil(calculateCost(counts: c, model: "<synthetic>", isFast: false, source: table))
    }

    func testSourceOverloadReturnsNilForNilModel() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        XCTAssertNil(calculateCost(counts: TokenCounts(input: 1),
                                   model: nil, isFast: false, source: table))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CostCalculatorTests
```

Expected: 编译失败，`cannot find 'tieredCost' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/CostCalculator.swift`：

```swift
import Foundation

/// cost 计算常量。对齐 ccusage cost.rs:7 与 pricing.rs。
enum CostConfig {
    /// 1 小时缓存写入 = `input 单价 × 2.0`。
    /// 这是 ccusage 的**硬编码倍率**，不是 LiteLLM 的 key，
    /// 也**不是**从 cache_creation 单价推导。
    static let cacheCreate1hInputMultiplier: Double = 2.0
    static let defaultLongContextThreshold: Int = 200_000
}

/// 边际分段计价：阈值内按 base，超出部分按 above。
/// 对齐 ccusage `tiered_cost`（cost.rs）。`above` 为 nil 时不分段。
func tieredCost(_ tokens: Int, base: Double, above: Double?,
                threshold: Int = CostConfig.defaultLongContextThreshold) -> Double {
    guard tokens > 0 else { return 0 }
    if let above, tokens > threshold {
        return Double(threshold) * base + Double(tokens - threshold) * above
    }
    return Double(tokens) * base
}

/// 计算一条 entry 的 cost。对齐 ccusage `calculate_cost_from_pricing`（cost.rs:103-183）。
///
/// 两条分支：
/// - `longContextThreshold` 非 nil（OpenAI）：由 `input` 单独决定档位，
///   所有桶**整体**按该档单价计费
/// - 否则（Anthropic）：每个桶**独立**做 200K 边际分段
///
/// `extraTotal` 不计费——它是 total 与分项之差，无对应单价。
func calculateCost(counts: TokenCounts, pricing: ModelPricing, isFast: Bool) -> Double {
    let cc1hRate = pricing.input * CostConfig.cacheCreate1hInputMultiplier
    let cc1hAbove = pricing.inputAbove200k.map { $0 * CostConfig.cacheCreate1hInputMultiplier }

    let base: Double
    if let threshold = pricing.longContextThreshold {
        let isLong = counts.input > threshold
        func rate(_ b: Double, _ a: Double?) -> Double { isLong ? (a ?? b) : b }
        base = Double(counts.input) * rate(pricing.input, pricing.inputAbove200k)
             + Double(counts.output) * rate(pricing.output, pricing.outputAbove200k)
             + Double(counts.cacheCreation5m) * rate(pricing.cacheCreate, pricing.cacheCreateAbove200k)
             + Double(counts.cacheCreation1h) * rate(cc1hRate, cc1hAbove)
             + Double(counts.cacheRead) * rate(pricing.cacheRead, pricing.cacheReadAbove200k)
    } else {
        let t = CostConfig.defaultLongContextThreshold
        base = tieredCost(counts.input, base: pricing.input,
                          above: pricing.inputAbove200k, threshold: t)
             + tieredCost(counts.output, base: pricing.output,
                          above: pricing.outputAbove200k, threshold: t)
             + tieredCost(counts.cacheCreation5m, base: pricing.cacheCreate,
                          above: pricing.cacheCreateAbove200k, threshold: t)
             + tieredCost(counts.cacheCreation1h, base: cc1hRate,
                          above: cc1hAbove, threshold: t)
             + tieredCost(counts.cacheRead, base: pricing.cacheRead,
                          above: pricing.cacheReadAbove200k, threshold: t)
    }

    return base * (isFast ? pricing.fastMultiplier : 1.0)
}

/// 经由 `PricingSource` 解析模型名后计算。
/// 模型名为 nil 或未命中定价表时返回 nil——调用方应记为"无 cost"，
/// 但**仍需照常统计该 entry 的 token**。
func calculateCost(counts: TokenCounts, model: String?,
                   isFast: Bool, source: PricingSource) -> Double? {
    guard let model, let pricing = source.pricing(for: model) else { return nil }
    return calculateCost(counts: counts, pricing: pricing, isFast: isFast)
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CostCalculatorTests
```

Expected: `Executed 17 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/CostCalculator.swift client/VibeCompanion/Tests/CostCalculatorTests.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 tieredCost 与 calculateCost

五个桶各自计价，1h 缓存单价为 input×2.0；Anthropic 走按桶边际
分段，OpenAI 走由 input 决定的整请求选档；fast 倍率整体缩放。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: PricingStore 分层加载

**Files:**
- Create: `client/VibeCompanion/Sources/Core/PricingStore.swift`
- Create: `client/VibeCompanion/Resources/litellm-pricing-snapshot.json`
- Modify: `client/Package.swift`（给 executableTarget 加 resources）
- Test: `client/VibeCompanion/Tests/PricingStoreTests.swift`

**Interfaces:**
- Consumes: `ModelPricing`（Task 1）、`PricingTable` / `PricingSource`（Task 2）
- Produces:
  - `protocol PricingFetcher { func fetch() async throws -> [String: Any] }`
  - `protocol PricingCache { func read() -> (json: [String: Any], age: TimeInterval)?; func write(_ json: [String: Any]) }`
  - `func builtinPricingOverrides() -> [String: ModelPricing]`
  - `final class PricingStore: PricingSource` — `init(builtinSnapshot:cache:fetcher:cacheTTL:)`、`func pricing(for:) -> ModelPricing?`、`func refresh() async`

**背景：** 分层顺序（后者覆盖前者）：内置快照 → builtin 硬编码表 → 磁盘缓存 → 线上抓取。
builtin 表必须包含 `claude-opus-4-8`（本机 855 条记录，LiteLLM 可能缺失）。
磁盘缓存是**对 ccusage 的偏离 D2**——ccusage 无磁盘缓存，但它是 CLI；本项目是频繁重启的常驻应用。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/PricingStoreTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class PricingStoreTests: XCTestCase {

    private let eps = 1e-15

    private final class FakeCache: PricingCache {
        var stored: [String: Any]?
        var age: TimeInterval = 0
        var writeCount = 0
        func read() -> (json: [String: Any], age: TimeInterval)? {
            stored.map { ($0, age) }
        }
        func write(_ json: [String: Any]) { stored = json; writeCount += 1 }
    }

    private struct FakeFetcher: PricingFetcher {
        let result: Result<[String: Any], Error>
        func fetch() async throws -> [String: Any] { try result.get() }
    }

    private struct BoomError: Error {}

    private func entry(_ input: Double) -> [String: Any] {
        ["input_cost_per_token": input, "output_cost_per_token": input * 5]
    }

    func testFallsBackToBuiltinSnapshotWhenNothingElseAvailable() {
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
    }

    /// builtin 硬编码表覆盖内置快照
    func testBuiltinOverridesBeatSnapshot() {
        let store = PricingStore(builtinSnapshot: ["claude-opus-4-8": entry(999e-6)],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        // builtin 表里 claude-opus-4-8 的 input 是 5e-6
        XCTAssertEqual(store.pricing(for: "claude-opus-4-8")!.input, 5e-6, accuracy: eps)
    }

    func testBuiltinOverridesIncludeOpus48() {
        let overrides = builtinPricingOverrides()
        XCTAssertNotNil(overrides["claude-opus-4-8"])
        XCTAssertEqual(overrides["claude-opus-4-8"]!.fastMultiplier, 2.0, accuracy: eps)
    }

    /// 未过期的磁盘缓存覆盖 builtin
    func testFreshCacheOverridesBuiltin() {
        let cache = FakeCache()
        cache.stored = ["model-a": entry(7e-6)]
        cache.age = 3600                     // 1h < TTL 24h
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 7e-6, accuracy: eps)
    }

    /// 过期缓存被忽略
    func testStaleCacheIsIgnored() {
        let cache = FakeCache()
        cache.stored = ["model-a": entry(7e-6)]
        cache.age = 48 * 3600                // 48h > TTL 24h
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
    }

    func testRefreshAppliesFetchedPricingAndWritesCache() async {
        let cache = FakeCache()
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .success(["model-a": entry(9e-6)])))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 9e-6, accuracy: eps)
        XCTAssertEqual(cache.writeCount, 1)
    }

    /// 抓取失败不得破坏已有定价
    func testFailedRefreshKeepsPreviousPricing() async {
        let cache = FakeCache()
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
        XCTAssertEqual(cache.writeCount, 0)
    }

    /// 线上抓取覆盖 builtin 硬编码表
    func testFetchedPricingOverridesBuiltin() async {
        let store = PricingStore(builtinSnapshot: [:],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .success(["claude-opus-4-8": entry(3e-6)])))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "claude-opus-4-8")!.input, 3e-6, accuracy: eps)
    }

    func testUnknownModelReturnsNil() {
        let store = PricingStore(builtinSnapshot: [:],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertNil(store.pricing(for: "nope"))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PricingStoreTests
```

Expected: 编译失败，`cannot find 'PricingStore' in scope`。

- [ ] **Step 3: 生成内置定价快照**

从 LiteLLM 抓一份快照，只保留与本项目相关的模型，减小体积：

```bash
mkdir -p client/VibeCompanion/Resources
curl -sL https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json \
  | python3 -c "
import json, sys
src = json.load(sys.stdin)
keep = ('claude-', 'anthropic.', 'anthropic/', 'us.anthropic.', 'eu.anthropic.',
        'global.anthropic.', 'gpt-', 'openai/', 'azure/', 'openrouter/openai/')
out = {k: v for k, v in src.items()
       if isinstance(v, dict) and k.startswith(keep)
       and 'input_cost_per_token' in v and 'output_cost_per_token' in v}
json.dump(out, sys.stdout, separators=(',', ':'), sort_keys=True)
print(f'kept {len(out)} of {len(src)} entries', file=sys.stderr)
" > client/VibeCompanion/Resources/litellm-pricing-snapshot.json
```

确认文件非空且是合法 JSON：

```bash
python3 -c "import json;d=json.load(open('client/VibeCompanion/Resources/litellm-pricing-snapshot.json'));print(len(d),'entries');print('claude-opus-5' in d)"
```

- [ ] **Step 4: 把资源挂到 SwiftPM target**

修改 `client/Package.swift`，把 `executableTarget` 改为：

```swift
        .executableTarget(
            name: "VibeCompanion",
            path: "VibeCompanion/Sources",
            resources: [
                .copy("../Resources/litellm-pricing-snapshot.json")
            ]
        ),
```

- [ ] **Step 5: 写最小实现**

创建 `client/VibeCompanion/Sources/Core/PricingStore.swift`：

```swift
import Foundation

/// 线上定价抓取。抽成协议以便测试注入。
protocol PricingFetcher {
    func fetch() async throws -> [String: Any]
}

/// 磁盘缓存。抽成协议以便测试注入。
protocol PricingCache {
    /// 返回缓存内容与其年龄；无缓存时返回 nil。
    func read() -> (json: [String: Any], age: TimeInterval)?
    func write(_ json: [String: Any])
}

/// LiteLLM 定价 JSON 的线上地址。对齐 ccusage `LITELLM_PRICING_URL`。
let liteLLMPricingURL = URL(string:
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

/// 硬编码定价覆盖表。对齐 ccusage `put_builtin_pricing()`（pricing.rs:667-1173）。
///
/// 存在的理由：这些模型可能尚未进入 LiteLLM，或 LiteLLM 的数据不准。
/// 实测本机有 855 条 `claude-opus-4-8` 记录。
func builtinPricingOverrides() -> [String: ModelPricing] {
    func anthropic(input: Double, output: Double, cacheCreate: Double, cacheRead: Double,
                   fast: Double = 1.0) -> ModelPricing {
        ModelPricing(input: input, output: output, cacheCreate: cacheCreate,
                     cacheRead: cacheRead, cacheReadExplicit: true,
                     inputAbove200k: nil, outputAbove200k: nil,
                     cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                     longContextThreshold: nil, fastMultiplier: fast)
    }
    return [
        "claude-opus-4-8": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 2.0),
        "claude-opus-4-7": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 6.0),
        "claude-opus-4-6": anthropic(input: 5e-6, output: 25e-6,
                                     cacheCreate: 6.25e-6, cacheRead: 0.5e-6, fast: 6.0),
    ]
}

/// 分层定价源：内置快照 → builtin 覆盖 → 磁盘缓存 → 线上抓取。
///
/// **非线程安全**——`refresh()` 与 `pricing(for:)` 需由调用方串行化
/// （P3 中由 `@MainActor` 保证）。
final class PricingStore: PricingSource {
    private var table: PricingTable
    private var snapshot: [String: Any]
    private let cache: PricingCache
    private let fetcher: PricingFetcher
    private let cacheTTL: TimeInterval

    init(builtinSnapshot: [String: Any],
         cache: PricingCache,
         fetcher: PricingFetcher,
         cacheTTL: TimeInterval = 24 * 3600) {
        self.snapshot = builtinSnapshot
        self.cache = cache
        self.fetcher = fetcher
        self.cacheTTL = cacheTTL
        self.table = PricingTable(entries: [:])
        rebuild(withFetched: nil)
    }

    func pricing(for model: String) -> ModelPricing? {
        table.pricing(for: model)
    }

    /// 抓取线上定价并覆盖。失败时静默保留现有定价——
    /// 网络问题绝不能影响速率显示。
    func refresh() async {
        guard let fetched = try? await fetcher.fetch(), !fetched.isEmpty else { return }
        cache.write(fetched)
        rebuild(withFetched: fetched)
    }

    // MARK: - private

    private func rebuild(withFetched fetched: [String: Any]?) {
        // 1. 内置快照
        var entries = decodeLiteLLMPricing(snapshot)
        // 2. builtin 硬编码表覆盖
        for (k, v) in builtinPricingOverrides() { entries[k] = v }
        // 3. 未过期的磁盘缓存覆盖
        if let (cached, age) = cache.read(), age <= cacheTTL {
            for (k, v) in decodeLiteLLMPricing(cached) { entries[k] = v }
        }
        // 4. 本次抓取结果覆盖
        if let fetched {
            for (k, v) in decodeLiteLLMPricing(fetched) { entries[k] = v }
        }
        table = PricingTable(entries: entries, aliases: ["gpt-5.3-spark": "gpt-5.3-codex-spark"])
    }
}

// MARK: - 生产实现

/// 走 URLSession 的抓取器，10 秒超时（对齐 ccusage `PRICING_FETCH_TIMEOUT_SECONDS`）。
struct URLSessionPricingFetcher: PricingFetcher {
    func fetch() async throws -> [String: Any] {
        var request = URLRequest(url: liteLLMPricingURL)
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// 写到 `~/Library/Application Support/VibeCompanion/pricing-cache.json`。
struct FilePricingCache: PricingCache {
    private var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VibeCompanion", isDirectory: true)
            .appendingPathComponent("pricing-cache.json")
    }

    func read() -> (json: [String: Any], age: TimeInterval)? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                  .contentModificationDate
        else { return nil }
        return (json, Date().timeIntervalSince(modified))
    }

    func write(_ json: [String: Any]) {
        guard let url, let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// 从 app bundle 读取内置快照。
func loadBuiltinPricingSnapshot() -> [String: Any] {
    guard let url = Bundle.module.url(forResource: "litellm-pricing-snapshot",
                                      withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PricingStoreTests
```

Expected: `Executed 9 tests, with 0 failures`

> 若 `Bundle.module` 报错找不到，说明 Step 4 的 `resources:` 路径没生效。SwiftPM 要求资源路径相对 target 的 `path`。本 target 的 `path` 是 `VibeCompanion/Sources`，而资源在 `VibeCompanion/Resources`，故用 `../Resources/...`。若 SwiftPM 拒绝跨目录引用，改为把 JSON 放到 `VibeCompanion/Sources/Resources/` 并写 `.copy("Resources/litellm-pricing-snapshot.json")`。

- [ ] **Step 7: 跑全量测试**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: 全部通过。

- [ ] **Step 8: 提交**

```bash
git add client/VibeCompanion/Sources/Core/PricingStore.swift client/VibeCompanion/Tests/PricingStoreTests.swift client/VibeCompanion/Resources/litellm-pricing-snapshot.json client/Package.swift
git commit -m "$(cat <<'EOF'
feat(core): 添加 PricingStore 分层定价加载

内置快照 -> builtin 硬编码覆盖 -> 磁盘缓存(TTL 24h) -> 线上抓取。
磁盘缓存是对 ccusage 的偏离 D2：它是 CLI 跑完即退，本项目是常驻
应用，不应每次启动都发网络请求。抓取失败静默保留现有定价。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 完成标准

- `Core/` 新增 4 个文件 + 1 个资源文件，`Package.swift` 挂上资源
- 新增 54 个测试全部通过，P1 与原有测试不受影响
- `CostCalculator` 与 `PricingResolver` 全程无 I/O，单测不联网
- P3 可直接注入 `PricingStore` 为 `SessionBlock.costUSD` 供数
