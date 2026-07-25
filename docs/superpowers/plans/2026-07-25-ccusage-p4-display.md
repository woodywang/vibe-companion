# P4 展示层 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把速度表量程做成用户可选，配色与指针角度保持一致，并补齐 indicator 与 cost 的文字展示。

**Architecture:** 用 `GaugeScale` 协议替换写死的量程常量，内置线性/对数/自适应三种实现；配色阈值定义为**当前量程的比例**而非绝对值，故对任何 scale 都成立。算法层零改动。

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest / macOS 13+

依赖：P1 全部、P3b Task 6（`TokenAggregator` 发布的 7 个状态）。
设计文档：`docs/superpowers/specs/2026-07-25-ccusage-burnrate-design.md` 第 7 节

## Global Constraints

- **测试命令必须带 `DEVELOPER_DIR`**：`cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`
- **不得修改 `Core/` 下的算法文件。** 本计划只碰 `Overlay/`、`Settings/`、`App/` 与 `Core/Settings.swift`。
- **指针角度、LCD 数字、配色三者必须同源**，全部由 `tokensPerMinute`（Total）驱动。这是用户明确要求的"颜色和角度保持一致"。
- 提交信息用中文，结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## 背景：为什么量程要可选

实测真实分布 41k – 760k tok/min，跨度近 20 倍。现有 `SpeedometerLogic.swift:8` 的 `valueMax = 500_000` **兜不住**最高的块（760k 会被 clamp 在红线尽头不动）。而单纯放大到 1M 又会让 41k 那类常见低速块的指针几乎贴在零点。没有单一量程能同时满足，故交给用户选。

---

### Task 1: GaugeScale 协议与三种实现

**Files:**
- Create: `client/VibeCompanion/Sources/Overlay/GaugeScale.swift`
- Test: `client/VibeCompanion/Tests/GaugeScaleTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `protocol GaugeScale { var id: String { get }; var displayName: String { get }; var majorTicks: [Double] { get }; var maxValue: Double { get }; func angle(for value: Double) -> Double }`
  - `enum GaugeGeometry { static let angleMin: Double = -135; static let angleMax: Double = 135 }`
  - `struct LinearGaugeScale: GaugeScale` — `init(maxValue: Double = 1_000_000)`
  - `struct LogGaugeScale: GaugeScale` — `init(minValue: Double = 10_000, maxValue: Double = 1_000_000)`
  - `struct AdaptiveGaugeScale: GaugeScale` — `init(recentPeak: Double)`
  - `func gaugeScale(id: String, recentPeak: Double) -> GaugeScale`
  - `let allGaugeScaleIDs: [String]`

**设计要点：**
- `angle(for:)` 一律 clamp 在 `[-135, 135]`
- `LogGaugeScale` 在 `value <= minValue` 时返回 `angleMin`（对数在 0 处无定义）
- `AdaptiveGaugeScale` 的量程 = `max(recentPeak * 1.2, 100_000)`，下界保证刚启动时刻度不至于荒谬

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/GaugeScaleTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class GaugeScaleTests: XCTestCase {

    private let eps = 1e-9

    // MARK: 所有 scale 共用的性质

    private var allScales: [GaugeScale] {
        [LinearGaugeScale(), LogGaugeScale(), AdaptiveGaugeScale(recentPeak: 500_000)]
    }

    func testAllScalesStartAtAngleMin() {
        for s in allScales {
            XCTAssertEqual(s.angle(for: 0), GaugeGeometry.angleMin, accuracy: eps,
                           "\(s.id) 在 0 处应指向最左")
        }
    }

    func testAllScalesEndAtAngleMaxAtTheirMax() {
        for s in allScales {
            XCTAssertEqual(s.angle(for: s.maxValue), GaugeGeometry.angleMax, accuracy: eps,
                           "\(s.id) 在量程上限处应指向最右")
        }
    }

    func testAllScalesClampAboveMax() {
        for s in allScales {
            XCTAssertEqual(s.angle(for: s.maxValue * 10), GaugeGeometry.angleMax,
                           accuracy: eps, "\(s.id) 超量程应 clamp")
        }
    }

    func testAllScalesClampBelowZero() {
        for s in allScales {
            XCTAssertEqual(s.angle(for: -1000), GaugeGeometry.angleMin,
                           accuracy: eps, "\(s.id) 负值应 clamp")
        }
    }

    func testAllScalesAreMonotonic() {
        for s in allScales {
            var previous = s.angle(for: 0)
            for step in stride(from: 0.0, through: s.maxValue, by: s.maxValue / 50) {
                let current = s.angle(for: step)
                XCTAssertGreaterThanOrEqual(current, previous - eps, "\(s.id) 应单调不减")
                previous = current
            }
        }
    }

    func testAllScalesHaveNonEmptyTicksWithinRange() {
        for s in allScales {
            XCTAssertFalse(s.majorTicks.isEmpty, "\(s.id) 应有刻度")
            for t in s.majorTicks {
                XCTAssertGreaterThanOrEqual(t, 0)
                XCTAssertLessThanOrEqual(t, s.maxValue + eps, "\(s.id) 刻度 \(t) 超出量程")
            }
        }
    }

    func testAllScaleIDsAreUniqueAndResolvable() {
        XCTAssertEqual(Set(allGaugeScaleIDs).count, allGaugeScaleIDs.count)
        for id in allGaugeScaleIDs {
            XCTAssertEqual(gaugeScale(id: id, recentPeak: 500_000).id, id)
        }
    }

    func testUnknownIdFallsBackToLinear() {
        XCTAssertEqual(gaugeScale(id: "nope", recentPeak: 0).id, LinearGaugeScale().id)
    }

    // MARK: 线性

    func testLinearMidpointIsCenter() {
        let s = LinearGaugeScale(maxValue: 1_000_000)
        XCTAssertEqual(s.angle(for: 500_000), 0, accuracy: eps)
    }

    func testLinearIsProportional() {
        let s = LinearGaugeScale(maxValue: 1_000_000)
        // 1/4 量程 -> -135 + 0.25*270 = -67.5
        XCTAssertEqual(s.angle(for: 250_000), -67.5, accuracy: eps)
    }

    // MARK: 对数

    func testLogBelowMinClampsToStart() {
        let s = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        XCTAssertEqual(s.angle(for: 0), GaugeGeometry.angleMin, accuracy: eps)
        XCTAssertEqual(s.angle(for: 5_000), GaugeGeometry.angleMin, accuracy: eps)
        XCTAssertEqual(s.angle(for: 10_000), GaugeGeometry.angleMin, accuracy: eps)
    }

    /// 10k -> 1M 共两个数量级，100k 正好是几何中点
    func testLogGeometricMidpointIsCenter() {
        let s = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        XCTAssertEqual(s.angle(for: 100_000), 0, accuracy: 1e-6)
    }

    /// 关键收益：低速区在对数量程下有分辨率，而线性量程下几乎贴零
    func testLogGivesLowRangeMoreResolutionThanLinear() {
        let log = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        let linear = LinearGaugeScale(maxValue: 1_000_000)
        let value = 41_000.0    // 实测中最低的那个块
        XCTAssertGreaterThan(log.angle(for: value), linear.angle(for: value) + 30)
    }

    // MARK: 自适应

    func testAdaptiveMaxTracksPeakWithHeadroom() {
        XCTAssertEqual(AdaptiveGaugeScale(recentPeak: 500_000).maxValue, 600_000, accuracy: eps)
    }

    func testAdaptiveHasFloorWhenPeakIsTiny() {
        XCTAssertEqual(AdaptiveGaugeScale(recentPeak: 0).maxValue, 100_000, accuracy: eps)
    }

    func testAdaptiveNeverClampsTheObservedPeak() {
        let s = AdaptiveGaugeScale(recentPeak: 760_582)
        XCTAssertLessThan(s.angle(for: 760_582), GaugeGeometry.angleMax)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GaugeScaleTests
```

Expected: 编译失败，`cannot find 'GaugeScale' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Overlay/GaugeScale.swift`：

```swift
import Foundation

/// 表盘几何常量。
enum GaugeGeometry {
    static let angleMin: Double = -135   // 最左
    static let angleMax: Double = 135    // 最右
    static var sweep: Double { angleMax - angleMin }
}

/// 速度表量程。
///
/// 实测真实速率跨度近 20 倍（41k – 760k tok/min），没有单一量程能兼顾
/// 低速分辨率与高速不溢出，故做成可插拔、由用户在设置中选择。
///
/// 算法层不认识本协议——`tokensPerMinute` 是纯数值，量程纯属展示决策。
protocol GaugeScale {
    /// 持久化标识。
    var id: String { get }
    var displayName: String { get }
    /// 需要绘制数字的刻度值。
    var majorTicks: [Double] { get }
    /// 量程上限，也是配色比例的分母。
    var maxValue: Double { get }
    /// 映射到指针角度，clamp 在 [angleMin, angleMax]。
    func angle(for value: Double) -> Double
}

private func clampAngle(_ a: Double) -> Double {
    min(max(a, GaugeGeometry.angleMin), GaugeGeometry.angleMax)
}

/// 线性量程：指针位置与数值成正比，最符合直觉。
struct LinearGaugeScale: GaugeScale {
    let id = "linear"
    let displayName = "线性 (0 – 1M)"
    let maxValue: Double

    init(maxValue: Double = 1_000_000) {
        self.maxValue = maxValue
    }

    var majorTicks: [Double] {
        stride(from: 0, through: maxValue, by: maxValue / 5).map { $0 }
    }

    func angle(for value: Double) -> Double {
        guard maxValue > 0 else { return GaugeGeometry.angleMin }
        return clampAngle(GaugeGeometry.angleMin + (value / maxValue) * GaugeGeometry.sweep)
    }
}

/// 对数量程：低速区与高速区都有分辨率，适合 20 倍跨度。
struct LogGaugeScale: GaugeScale {
    let id = "log"
    let displayName = "对数 (10k – 1M)"
    let minValue: Double
    let maxValue: Double

    init(minValue: Double = 10_000, maxValue: Double = 1_000_000) {
        self.minValue = minValue
        self.maxValue = maxValue
    }

    var majorTicks: [Double] {
        // 等比排列：10k / 31.6k / 100k / 316k / 1M
        let decades = log10(maxValue / minValue)
        return (0...4).map { minValue * pow(10, decades * Double($0) / 4) }
    }

    /// 对数在 0 处无定义，故 `value <= minValue` 一律指向起点。
    func angle(for value: Double) -> Double {
        guard value > minValue, maxValue > minValue else { return GaugeGeometry.angleMin }
        let fraction = log10(value / minValue) / log10(maxValue / minValue)
        return clampAngle(GaugeGeometry.angleMin + fraction * GaugeGeometry.sweep)
    }
}

/// 自适应量程：跟随近期峰值，永不溢出。
/// 代价是刻度会跳变，用户失去绝对参系。
struct AdaptiveGaugeScale: GaugeScale {
    let id = "adaptive"
    let displayName = "自适应"
    let maxValue: Double

    /// 下界 100k，避免刚启动峰值为 0 时刻度荒谬。
    init(recentPeak: Double) {
        self.maxValue = max(recentPeak * 1.2, 100_000)
    }

    var majorTicks: [Double] {
        stride(from: 0, through: maxValue, by: maxValue / 4).map { $0 }
    }

    func angle(for value: Double) -> Double {
        guard maxValue > 0 else { return GaugeGeometry.angleMin }
        return clampAngle(GaugeGeometry.angleMin + (value / maxValue) * GaugeGeometry.sweep)
    }
}

/// 全部可选量程的标识，顺序即设置界面的展示顺序。
let allGaugeScaleIDs = ["linear", "log", "adaptive"]

/// 按标识构造量程。未知标识回退到线性。
func gaugeScale(id: String, recentPeak: Double) -> GaugeScale {
    switch id {
    case "log": return LogGaugeScale()
    case "adaptive": return AdaptiveGaugeScale(recentPeak: recentPeak)
    default: return LinearGaugeScale()
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GaugeScaleTests
```

Expected: `Executed 18 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Overlay/GaugeScale.swift client/VibeCompanion/Tests/GaugeScaleTests.swift
git commit -m "$(cat <<'EOF'
feat(overlay): 添加可插拔的 GaugeScale 量程协议

内置线性/对数/自适应三种实现。实测速率跨度近 20 倍（41k-760k），
无单一量程能兼顾低速分辨率与高速不溢出，故交由用户选择。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: SpeedometerLogic 改造为配色与状态

**Files:**
- Modify: `client/VibeCompanion/Sources/Core/SpeedometerLogic.swift`（整体重写）
- Modify: `client/VibeCompanion/Tests/SpeedometerLogicTests.swift`（整体重写）

**Interfaces:**
- Consumes: `GaugeScale`（Task 1）
- Produces:
  - `enum GaugeZone: Equatable { case green, yellow, red }`
  - `enum GaugeColorConfig { static let yellowFraction: Double = 0.60; static let redFraction: Double = 0.85 }`
  - `func gaugeSweepFraction(value: Double, scale: GaugeScale) -> Double`
  - `func gaugeZone(value: Double, scale: GaugeScale) -> GaugeZone`
  - `func speedometerFormat(_ rpm: Double) -> String`（保留原行为）
  - `func speedometerDisplay(rpm: Double, hasBurnRate: Bool) -> String`

**背景：** 配色阈值定义为**指针行程比例**（角度走过表盘的百分比），而非绝对速率、也不是 `value / maxValue`。

这个区分是必需的：对数量程下 100k 在 10k–1M 表盘上指针正指中间（行程 50%），但数值比例只有 10%。若按数值比例配色，指针指在正中却显示绿色——"颜色和角度一致"就被破坏了。用行程比例则红线永远落在表盘末段（与真实机械速度表一致），且任何 scale 都不用重新标定。

`speedometerAngle` / `speedometerIsIdle` / `SpeedometerConfig` 三者删除：角度由 `GaugeScale` 负责，idle 由 `TokenAggregator.isIdle` 负责。

- [ ] **Step 1: 写失败的测试**

把 `client/VibeCompanion/Tests/SpeedometerLogicTests.swift` 整体替换为：

```swift
import XCTest
@testable import VibeCompanion

final class SpeedometerLogicTests: XCTestCase {

    private let scale = LinearGaugeScale(maxValue: 1_000_000)

    // MARK: 配色分区（按量程比例，非绝对值）

    func testGreenBelowYellowFraction() {
        XCTAssertEqual(gaugeZone(value: 0, scale: scale), .green)
        XCTAssertEqual(gaugeZone(value: 599_999, scale: scale), .green)
    }

    func testYellowBetweenFractions() {
        XCTAssertEqual(gaugeZone(value: 600_000, scale: scale), .yellow)
        XCTAssertEqual(gaugeZone(value: 849_999, scale: scale), .yellow)
    }

    func testRedAboveRedFraction() {
        XCTAssertEqual(gaugeZone(value: 850_000, scale: scale), .red)
        XCTAssertEqual(gaugeZone(value: 1_000_000, scale: scale), .red)
        XCTAssertEqual(gaugeZone(value: 5_000_000, scale: scale), .red)
    }

    /// 分区随量程走，换 scale 不用重新标定
    func testZoneFollowsScaleNotAbsoluteValue() {
        let small = LinearGaugeScale(maxValue: 100_000)
        // 同一个 70k：在 1M 量程下行程 7% 是绿区，在 100k 量程下行程 70% 是黄区
        XCTAssertEqual(gaugeZone(value: 70_000, scale: scale), .green)
        XCTAssertEqual(gaugeZone(value: 70_000, scale: small), .yellow)
        XCTAssertEqual(gaugeZone(value: 90_000, scale: small), .red)
    }

    func testZoneWorksForLogScale() {
        let log = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        // 100k 是几何中点，行程 50% -> 绿；900k 行程约 97.7% -> 红
        XCTAssertEqual(gaugeZone(value: 100_000, scale: log), .green)
        XCTAssertEqual(gaugeZone(value: 900_000, scale: log), .red)
    }

    /// 用户明确要求"颜色和角度保持一致"——这条锁住该性质。
    /// 对每种 scale，配色边界处的指针角度必须恰好落在约定的行程比例上。
    func testZoneBoundariesAlignWithNeedleAngleForEveryScale() {
        let scales: [GaugeScale] = [LinearGaugeScale(),
                                    LogGaugeScale(),
                                    AdaptiveGaugeScale(recentPeak: 500_000)]
        for s in scales {
            for value in stride(from: 0.0, through: s.maxValue, by: s.maxValue / 200) {
                let fraction = gaugeSweepFraction(value: value, scale: s)
                let expected: GaugeZone = fraction >= GaugeColorConfig.redFraction ? .red
                    : fraction >= GaugeColorConfig.yellowFraction ? .yellow : .green
                XCTAssertEqual(gaugeZone(value: value, scale: s), expected,
                               "\(s.id) 在 \(value) 处配色与指针行程不一致")
            }
        }
    }

    /// 对数量程下按数值比例配色会出错：100k 数值占比仅 10%，
    /// 但指针已走到一半。这条确保我们用的是行程而非数值比例。
    func testLogScaleZoneUsesSweepNotValueFraction() {
        let log = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        XCTAssertEqual(gaugeSweepFraction(value: 100_000, scale: log), 0.5, accuracy: 1e-6)
        // 数值比例只有 0.1，若按它算这里会是绿区的最左侧
        XCTAssertGreaterThan(gaugeSweepFraction(value: 100_000, scale: log), 0.1 + 0.3)
    }

    func testNegativeValueIsGreen() {
        XCTAssertEqual(gaugeZone(value: -100, scale: scale), .green)
    }

    // MARK: 数字格式化（保留既有口径）

    func testFormatSmall() {
        XCTAssertEqual(speedometerFormat(0), "0")
        XCTAssertEqual(speedometerFormat(999), "999")
    }

    func testFormatThousands() {
        XCTAssertEqual(speedometerFormat(9999), "10.0k")
        XCTAssertEqual(speedometerFormat(10_000), "10.0k")
        XCTAssertEqual(speedometerFormat(12_300), "12.3k")
    }

    func testFormatMillions() {
        XCTAssertEqual(speedometerFormat(1_000_000), "1.00M")
        XCTAssertEqual(speedometerFormat(2_340_000), "2.34M")
    }

    // MARK: 显示串

    /// 活跃块只有一条 entry 时无速率，须显示 "--" 而非 "0"
    func testDisplayShowsDashesWhenNoBurnRate() {
        XCTAssertEqual(speedometerDisplay(rpm: 0, hasBurnRate: false), "--")
        XCTAssertEqual(speedometerDisplay(rpm: 12_300, hasBurnRate: false), "--")
    }

    func testDisplayShowsFormattedRateWhenAvailable() {
        XCTAssertEqual(speedometerDisplay(rpm: 12_300, hasBurnRate: true), "12.3k")
        XCTAssertEqual(speedometerDisplay(rpm: 0, hasBurnRate: true), "0")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SpeedometerLogicTests
```

Expected: 编译失败，`cannot find 'gaugeZone' in scope`。

- [ ] **Step 3: 重写 SpeedometerLogic**

把 `client/VibeCompanion/Sources/Core/SpeedometerLogic.swift` 整体替换为：

```swift
import Foundation

/// 表盘配色分区。
enum GaugeZone: Equatable {
    case green, yellow, red
}

/// 配色阈值，定义为**当前量程的比例**而非绝对速率值。
///
/// 这样红线永远落在表盘末段（与真实机械速度表一致），
/// 且用户切换任何 `GaugeScale` 都无需重新标定。
///
/// 注意：配色与指针角度同源，都由 `tokensPerMinute`（Total）驱动。
/// ccusage 用 `tokensPerMinuteForIndicator` 驱动其 Normal/Moderate/High
/// 徽章，那会导致指针指在低位却显红色；本项目把 indicator 降级为
/// 菜单栏文字（偏离 D3）。
enum GaugeColorConfig {
    static let yellowFraction: Double = 0.60
    static let redFraction: Double = 0.85
}

/// 指针在表盘上已走过的行程比例，0 = 最左，1 = 最右。
func gaugeSweepFraction(value: Double, scale: GaugeScale) -> Double {
    (scale.angle(for: value) - GaugeGeometry.angleMin) / GaugeGeometry.sweep
}

/// 按**指针行程比例**判定配色分区。
///
/// 关键：分母是角度行程而非 `value / maxValue`。对数量程下两者不同——
/// 100k 在 10k–1M 的对数表盘上指针正指中间（行程 50%），而数值比例只有
/// 10%。若按数值比例配色，指针指在中间却显示绿色，颜色与角度就脱节了。
/// 用行程比例可保证任何 `GaugeScale` 下颜色与指针位置始终一致。
func gaugeZone(value: Double, scale: GaugeScale) -> GaugeZone {
    let fraction = gaugeSweepFraction(value: value, scale: scale)
    if fraction >= GaugeColorConfig.redFraction { return .red }
    if fraction >= GaugeColorConfig.yellowFraction { return .yellow }
    return .green
}

/// LCD 数字窗格式化：<1000 整数；<1_000_000 "%.1fk"；否则 "%.2fM"。
func speedometerFormat(_ rpm: Double) -> String {
    if rpm < 1000 { return "\(Int(rpm))" }
    if rpm < 1_000_000 { return String(format: "%.1fk", rpm / 1000) }
    return String(format: "%.2fM", rpm / 1_000_000)
}

/// LCD 显示串。
///
/// `hasBurnRate == false` 表示活跃块只有一条 entry（ccusage 的
/// `duration <= 0` 守卫），此时**没有速率**，与"速率为 0"是两回事，
/// 故显示 `--`。
func speedometerDisplay(rpm: Double, hasBurnRate: Bool) -> String {
    hasBurnRate ? speedometerFormat(rpm) : "--"
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SpeedometerLogicTests
```

Expected: `Executed 13 tests, with 0 failures`

> `SpeedometerView.swift` 与 `FloatingPetPanel.swift` 此刻会因 `speedometerAngle` / `speedometerIsIdle` / `SpeedometerConfig` 消失而编译失败。这是预期的——Task 3 修复。

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Core/SpeedometerLogic.swift client/VibeCompanion/Tests/SpeedometerLogicTests.swift
git commit -m "$(cat <<'EOF'
refactor(overlay): SpeedometerLogic 改为量程无关的配色与显示

配色阈值定义为当前量程的比例（60%/85%）而非绝对速率，红线永远
落在表盘末段，换任何 GaugeScale 都不用重新标定。角度职责移交
GaugeScale，idle 职责移交 TokenAggregator。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: SpeedometerView 与 FloatingPetContent 接线

**Files:**
- Modify: `client/VibeCompanion/Sources/Overlay/SpeedometerView.swift:6-14`（属性）、`:16-32`（body）、`:63-69`（redlineArc）、`:71-89`（ticks）、numbers 与 lcdWindow
- Modify: `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift`（`FloatingPetContent`）

**Interfaces:**
- Consumes: `GaugeScale`、`gaugeZone`、`speedometerDisplay`（Task 1、2）、`TokenAggregator` 的发布状态（P3b）
- Produces: `SpeedometerView(tokensPerMinute:hasBurnRate:scale:)`

**改造要点：**
1. `SpeedometerView` 新增 `scale: GaugeScale` 与 `hasBurnRate: Bool` 两个入参；删除写死的 `redlineStart` 与 `majorValues`
2. 刻度由 `scale.majorTicks` 驱动，角度一律走 `scale.angle(for:)`
3. 红线弧起点改为 `scale.maxValue * GaugeColorConfig.redFraction`
4. 指针与 LCD 数字的颜色由 `gaugeZone(value:scale:)` 决定

- [ ] **Step 1: 改 SpeedometerView 的属性与 body**

把 `client/VibeCompanion/Sources/Overlay/SpeedometerView.swift:5-32` 替换为：

```swift
struct SpeedometerView: View {
    let tokensPerMinute: Double
    /// false 表示活跃块不足以算出速率，LCD 显示 "--"，指针归零。
    let hasBurnRate: Bool
    /// 量程由用户在设置中选择，本视图不假设任何具体数值范围。
    let scale: GaugeScale

    // 表盘几何（在 200×200 基准坐标系内，整体放进 140×140 frame）
    private let size: CGFloat = 140
    private let center = CGPoint(x: 100, y: 100)
    private let rimRadius: CGFloat = 96
    private let dialRadius: CGFloat = 82

    /// 红线弧起点角度：直接由行程比例算，与 `gaugeZone` 同源。
    /// 不要写成 `scale.angle(for: maxValue * redFraction)`——对数量程下
    /// 那样得到的角度与配色边界不重合。
    private var redlineStartAngle: Double {
        GaugeGeometry.angleMin + GaugeColorConfig.redFraction * GaugeGeometry.sweep
    }

    private var zone: GaugeZone {
        hasBurnRate ? gaugeZone(value: tokensPerMinute, scale: scale) : .green
    }

    private var zoneColor: Color {
        switch zone {
        case .green: return Color(hex: 0x3D_D6_8C)
        case .yellow: return Color(hex: 0xE8_B3_39)
        case .red: return Color(hex: 0xE5_48_4D)
        }
    }

    var body: some View {
        let angle = hasBurnRate ? scale.angle(for: tokensPerMinute) : GaugeGeometry.angleMin
        let display = speedometerDisplay(rpm: tokensPerMinute, hasBurnRate: hasBurnRate)

        ZStack {
            dialBackground
            redlineArc
            ticks
            numbers
            lcdWindow(display)
            needle(angle)
            centerCap
        }
        .frame(width: 200, height: 200)     // 与几何坐标系一致，内容自然居中
        .scaleEffect(size / 200)            // 缩放到 140
        .frame(width: size, height: size)   // 撑住布局尺寸
    }
```

- [ ] **Step 2: 改 redlineArc 与 ticks**

把 `redlineArc`（原 `:63-69`）替换为：

```swift
    private var redlineArc: some View {
        let start = Angle.degrees(redlineStartAngle - 90)
        let end = Angle.degrees(GaugeGeometry.angleMax - 90)
        return ArcShape(center: center, radius: 74, start: start, end: end)
            .stroke(Color(hex: 0xE5_48_4D), style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }
```

把 `ticks`（原 `:71-89`）替换为：

```swift
    private var ticks: some View {
        // 主刻度来自量程；每两个主刻度之间插 4 根副刻度
        let majors = scale.majorTicks
        return ZStack {
            ForEach(Array(majors.enumerated()), id: \.offset) { _, value in
                TickShape(center: center, innerRadius: 60, outerRadius: 78,
                          angle: Angle.degrees(scale.angle(for: value)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            ForEach(Array(minorTickAngles.enumerated()), id: \.offset) { _, ang in
                TickShape(center: center, innerRadius: 72, outerRadius: 78,
                          angle: Angle.degrees(ang))
                    .stroke(Color.white.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    /// 副刻度按**角度**均分，而非按数值——对数量程下按数值均分会挤在一起。
    private var minorTickAngles: [Double] {
        let majors = scale.majorTicks.map { scale.angle(for: $0) }
        guard majors.count >= 2 else { return [] }
        var out: [Double] = []
        for i in 0..<(majors.count - 1) {
            let a = majors[i], b = majors[i + 1]
            for k in 1..<5 { out.append(a + (b - a) * Double(k) / 5) }
        }
        return out
    }
```

- [ ] **Step 3: 改 numbers 与 LCD 配色**

`numbers` 中原本遍历 `majorValues` 的地方改为遍历 `scale.majorTicks`，标签文字用 `speedometerFormat(value)`，角度用 `scale.angle(for: value)`。

`lcdWindow(_:)` 中数字的 `foregroundColor` 改为 `zoneColor`；`needle(_:)` 的填充色同样改为 `zoneColor`。

- [ ] **Step 4: 改 FloatingPetContent**

把 `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift` 中的 `FloatingPetContent` 替换为：

```swift
/// SwiftUI 内容容器：速度表显示 token 消耗速率
struct FloatingPetContent: View {
    @ObservedObject var aggregator: TokenAggregator
    /// 用户选择的量程标识，随设置变化。
    let gaugeScaleID: String

    var body: some View {
        let rpm = aggregator.tokensPerMinute
        let scale = gaugeScale(id: gaugeScaleID, recentPeak: aggregator.recentPeak)

        VStack(spacing: 2) {
            SpeedometerView(tokensPerMinute: rpm,
                            hasBurnRate: aggregator.hasBurnRate,
                            scale: scale)
                .frame(width: 140, height: 140)

            // 速率小气泡（非 idle 且有速率时显示）
            if !aggregator.isIdle && aggregator.hasBurnRate {
                Text(speedometerFormat(rpm))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(width: 160, height: 160)
    }
}
```

- [ ] **Step 5: 修 AppCoordinator 的调用点**

`client/VibeCompanion/Sources/App/VibeCompanionApp.swift` 的 `showFloatingPanel()` 中，`FloatingPetContent(aggregator: aggregator)` 改为：

```swift
        let hosting = NSHostingView(rootView: FloatingPetContent(
            aggregator: aggregator,
            gaugeScaleID: Settings.shared.gaugeScaleID))
```

（`Settings.gaugeScaleID` 在 Task 4 添加；可先把 Task 4 的 Step 1 提前做完。）

- [ ] **Step 6: 确认可构建并跑全量测试**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

- [ ] **Step 7: 提交**

```bash
git add client/VibeCompanion/Sources/Overlay client/VibeCompanion/Sources/App
git commit -m "$(cat <<'EOF'
feat(overlay): 速度表刻度与配色改由 GaugeScale 驱动

删除写死的 500k 量程与 400k 红线；刻度取自 scale.majorTicks，
副刻度按角度均分（对数量程下按数值均分会挤在一起）；指针与 LCD
配色由 gaugeZone 决定，与指针角度同源。无速率时显示 "--"。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Settings 量程选择

**Files:**
- Modify: `client/VibeCompanion/Sources/Core/Settings.swift:22-29`
- Modify: `client/VibeCompanion/Sources/Settings/SettingsView.swift`
- Modify: `client/VibeCompanion/Sources/App/VibeCompanionApp.swift`（`AppCoordinator` 发布 `gaugeScaleID`）
- Test: `client/VibeCompanion/Tests/SettingsTests.swift`

**Interfaces:**
- Consumes: `allGaugeScaleIDs`、`gaugeScale(id:recentPeak:)`（Task 1）
- Produces: `Settings.gaugeScaleID: String`（默认 `"linear"`）、`AppCoordinator.gaugeScaleID: String`（`@Published`）

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/SettingsTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class SettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "vc.test.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testGaugeScaleIDDefaultsToLinear() {
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "linear")
    }

    func testGaugeScaleIDPersists() {
        let s = Settings(defaults: defaults)
        s.gaugeScaleID = "log"
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "log")
    }

    /// 存进未知值时读回应回退到默认，避免 UI 拿到无效标识
    func testUnknownGaugeScaleIDFallsBackToDefault() {
        defaults.set("bogus", forKey: "vc.gaugeScaleID")
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "linear")
    }

    func testPausedDefaultsToFalseAndPersists() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.isPaused)
        s.isPaused = true
        XCTAssertTrue(Settings(defaults: defaults).isPaused)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SettingsTests
```

Expected: 编译失败——`Settings` 无 `init(defaults:)`，也无 `gaugeScaleID`。

- [ ] **Step 3: 改 Settings**

把 `client/VibeCompanion/Sources/Core/Settings.swift:11-29` 替换为：

```swift
    private let defaults: UserDefaults

    /// 生产用：优先 bundle id suite，失败回退 standard。
    convenience init() {
        self.init(defaults: UserDefaults(suiteName: "dev.vibe.companion") ?? .standard)
    }

    /// 测试用：注入独立 suite，避免污染真实偏好。
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let paused = "vc.paused"
        static let gaugeScaleID = "vc.gaugeScaleID"
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Keys.paused) }
        set { defaults.set(newValue, forKey: Keys.paused) }
    }

    /// 速度表量程标识。未设置或值非法时回退到线性。
    var gaugeScaleID: String {
        get {
            let stored = defaults.string(forKey: Keys.gaugeScaleID) ?? ""
            return allGaugeScaleIDs.contains(stored) ? stored : "linear"
        }
        set { defaults.set(newValue, forKey: Keys.gaugeScaleID) }
    }
```

- [ ] **Step 4: 改 AppCoordinator**

在 `client/VibeCompanion/Sources/App/VibeCompanionApp.swift` 的 `AppCoordinator` 中，`isPaused` 属性下方加：

```swift
    /// 速度表量程，改动后悬浮窗立即重建以套用新刻度。
    @Published var gaugeScaleID: String = Settings.shared.gaugeScaleID {
        didSet {
            Settings.shared.gaugeScaleID = gaugeScaleID
            rebuildFloatingPanel()
        }
    }
```

并把 `showFloatingPanel()` 改名/补充为：

```swift
    private func rebuildFloatingPanel() {
        panel?.close()
        panel = nil
        showFloatingPanel()
    }
```

`showFloatingPanel()` 内的 `FloatingPetContent` 改用 `gaugeScaleID`（而非 `Settings.shared.gaugeScaleID`）。

- [ ] **Step 5: 改 SettingsView**

把 `client/VibeCompanion/Sources/Settings/SettingsView.swift` 替换为：

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("采集") {
                Toggle("暂停采集", isOn: $coordinator.isPaused)
                Text("暂停后仍会监听会话文件，但不再统计新的 token 用量。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("速度表量程") {
                Picker("量程", selection: $coordinator.gaugeScaleID) {
                    ForEach(allGaugeScaleIDs, id: \.self) { id in
                        Text(gaugeScale(id: id, recentPeak: 0).displayName).tag(id)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("实测真实速率跨度可达 20 倍（约 41k – 760k tok/min）。"
                     + "线性最直观；对数在低速区更有分辨率；自适应跟随近期峰值，永不溢出但刻度会变。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SettingsTests
```

Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 7: 提交**

```bash
git add client/VibeCompanion/Sources/Core/Settings.swift client/VibeCompanion/Sources/Settings/SettingsView.swift client/VibeCompanion/Sources/App/VibeCompanionApp.swift client/VibeCompanion/Tests/SettingsTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): 速度表量程改为用户可选

Settings 支持注入 UserDefaults 以便测试；非法量程标识回退到线性；
切换量程后悬浮窗重建以套用新刻度。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 菜单栏补齐 indicator 与 cost

**Files:**
- Modify: `client/VibeCompanion/Sources/App/MenuBarContent.swift:11-28`（状态区）、`:63-71`（`petEmoji`）
- Test: `client/VibeCompanion/Tests/MenuBarFormattingTests.swift`

**Interfaces:**
- Consumes: `BurnRateLevel`（P1）、`TokenAggregator` 状态（P3b）
- Produces: `func burnRateLevelLabel(_ level: BurnRateLevel) -> String`、`func formatCostPerHour(_ cost: Double?) -> String`

**背景：** ccusage 的 `tokensPerMinuteForIndicator` 与其 Normal/Moderate/High 语义在此落地——它不再驱动表盘配色（偏离 D3），而是作为菜单栏的一行文字。这样既保留了 ccusage 的语义，又不与"颜色和角度一致"冲突。

现有 `petEmoji`（`:63-71`）的阈值（2000/10000/30000）是按旧的 `effectiveTokens` 口径定的，改用 Total 后完全失效，须改为按 `BurnRateLevel` 取。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/MenuBarFormattingTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class MenuBarFormattingTests: XCTestCase {

    func testLevelLabelsCoverAllCases() {
        XCTAssertEqual(burnRateLevelLabel(.normal), "Normal")
        XCTAssertEqual(burnRateLevelLabel(.moderate), "Moderate")
        XCTAssertEqual(burnRateLevelLabel(.high), "High")
    }

    func testCostFormattedWithTwoDecimals() {
        XCTAssertEqual(formatCostPerHour(12.3456), "$12.35/h")
        XCTAssertEqual(formatCostPerHour(0), "$0.00/h")
    }

    func testCostShowsDashesWhenUnavailable() {
        XCTAssertEqual(formatCostPerHour(nil), "--")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MenuBarFormattingTests
```

Expected: 编译失败，`cannot find 'burnRateLevelLabel' in scope`。

- [ ] **Step 3: 写实现并改菜单栏**

在 `client/VibeCompanion/Sources/App/MenuBarContent.swift` 的 `import` 之后、`struct MenuBarContent` 之前插入：

```swift
/// ccusage 的档位文字。阈值 2000/5000 作用于 tokensPerMinuteForIndicator。
///
/// 本项目把它降级为菜单栏文字（偏离 D3）：表盘配色改由 Total 速率驱动，
/// 以满足"颜色和角度保持一致"。
func burnRateLevelLabel(_ level: BurnRateLevel) -> String {
    switch level {
    case .normal: return "Normal"
    case .moderate: return "Moderate"
    case .high: return "High"
    }
}

func formatCostPerHour(_ cost: Double?) -> String {
    guard let cost else { return "--" }
    return String(format: "$%.2f/h", cost)
}
```

把 `body` 中的状态区（原 `:11-28`）替换为：

```swift
            // 实时状态
            section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前速率").font(.caption).foregroundColor(.secondary)
                        Text(speedometerDisplay(rpm: coordinator.aggregator.tokensPerMinute,
                                                hasBurnRate: coordinator.aggregator.hasBurnRate))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text(petEmoji(coordinator.aggregator.level))
                        .font(.system(size: 36))
                }
            }

            // ccusage 档位（依据 input+output 速率，与表盘配色口径不同）
            section {
                statRow(label: "档位",
                        value: "\(burnRateLevelLabel(coordinator.aggregator.level))"
                             + "  (\(speedometerFormat(coordinator.aggregator.indicatorTokensPerMinute))/min)")
            }

            // 估算花费
            section {
                statRow(label: "估算花费",
                        value: formatCostPerHour(coordinator.aggregator.costPerHour))
            }
```

把 `petEmoji`（原 `:63-71`）替换为：

```swift
    /// 按 ccusage 档位取表情。
    /// 原实现按 effectiveTokens 口径写死 2000/10000/30000，改用 Total 后已失效。
    private func petEmoji(_ level: BurnRateLevel) -> String {
        guard !coordinator.aggregator.isIdle, coordinator.aggregator.hasBurnRate else { return "😴" }
        switch level {
        case .normal: return "🐢"
        case .moderate: return "🐰"
        case .high: return "🚀"
        }
    }
```

删除已无用的 `formatRate`（原 `:73-76`），其角色由 `speedometerDisplay` / `speedometerFormat` 承担。

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MenuBarFormattingTests
```

Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 全量测试 + 构建 + 实机验证**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

然后按 `docs/client-build.md` 打包运行，人工确认：

- 速度表指针随 Claude Code 回复动起来，且数值量级与 `npx ccusage@20 blocks --active` 一致
- 停止工作 90 秒后指针落回 0
- 设置里切换三种量程，刻度与指针位置随之变化
- 菜单栏显示档位文字与估算花费
- 拔掉网络重启 app：速率照常工作，花费显示 `--` 或走内置快照

- [ ] **Step 6: 提交**

```bash
git add client/VibeCompanion/Sources/App/MenuBarContent.swift client/VibeCompanion/Tests/MenuBarFormattingTests.swift
git commit -m "$(cat <<'EOF'
feat(menubar): 补齐 ccusage 档位文字与估算花费

indicator 速率降级为菜单栏文字（偏离 D3），表盘配色仍由 Total 驱动。
petEmoji 阈值改按 BurnRateLevel 取——原先写死的 2000/10000/30000
是 effectiveTokens 口径，改用 Total 后已失效。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 更新文档

**Files:**
- Modify: `docs/collector.md`（第 4 节整节重写）

- [ ] **Step 1: 重写「速率聚合」一节**

把 `docs/collector.md` 中「### 4. 速率聚合」整节替换为：

```markdown
### 4. 速率聚合

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
```

同时把文末「## 参考实现」一节中"它是「全量重扫」模式，无增量游标"的说法修正——本实现现在也会回扫最近 6 小时的历史，差异在于回扫范围有界且之后转为增量 tail。

- [ ] **Step 2: 提交**

```bash
git add docs/collector.md
git commit -m "$(cat <<'EOF'
docs: collector 速率聚合一节改写为 session block 模型

替换已失效的 60s 滑窗与 effectiveTokens 描述，补充去重语义、
分块规则与对 ccusage 的五项偏离。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 完成标准

- 用户可在设置中切换三种量程，刻度与指针随之变化
- 指针角度、LCD 数字、配色三者同源，均由 Total 速率驱动
- 无速率时显示 `--` 而非 `0`；空闲 90s 后指针落回 0
- 菜单栏显示 ccusage 档位与估算花费
- 断网时速率功能不受影响
- `docs/collector.md` 与实现一致
