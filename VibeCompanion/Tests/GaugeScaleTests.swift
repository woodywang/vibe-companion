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

    /// 上限留出余量后再向上取整到整齐值，故只断言不小于 `peak * 1.2`。
    func testAdaptiveMaxTracksPeakWithHeadroom() {
        XCTAssertGreaterThanOrEqual(AdaptiveGaugeScale(recentPeak: 500_000).maxValue, 600_000)
        XCTAssertEqual(AdaptiveGaugeScale(recentPeak: 500_000).maxValue, 800_000, accuracy: eps)
    }

    func testAdaptiveHasFloorWhenPeakIsTiny() {
        XCTAssertEqual(AdaptiveGaugeScale(recentPeak: 0).maxValue, 100_000, accuracy: eps)
    }

    func testAdaptiveNeverClampsTheObservedPeak() {
        for peak in [760_582.0, 1_500_000, 6_020_000, 8_350_000] {
            let s = AdaptiveGaugeScale(recentPeak: peak)
            XCTAssertLessThan(s.angle(for: peak), GaugeGeometry.angleMax, "peak=\(peak)")
        }
    }

    /// 上限取整到 `4 × {1,2,2.5,5} × 10ⁿ`，于是四等分落在圆整数字上。
    /// 回归目标：`recentPeak * 1.2` 会给出 `360.0k / 720.0k / 1.08M` 这种刻度。
    func testAdaptiveMaxIsRoundedToNiceValue() {
        XCTAssertEqual(AdaptiveGaugeScale.niceMax(atLeast: 100_000), 100_000, accuracy: eps)
        XCTAssertEqual(AdaptiveGaugeScale.niceMax(atLeast: 1_800_000), 2_000_000, accuracy: eps)
        XCTAssertEqual(AdaptiveGaugeScale.niceMax(atLeast: 600_000), 800_000, accuracy: eps)
        // 恰好落在整齐值上时不该再往上跳一档
        XCTAssertEqual(AdaptiveGaugeScale.niceMax(atLeast: 2_000_000), 2_000_000, accuracy: eps)
    }

    func testAdaptiveNiceMaxIsAlwaysAtLeastTheTarget() {
        for target in stride(from: 100_000.0, through: 12_000_000, by: 37_137) {
            let m = AdaptiveGaugeScale.niceMax(atLeast: target)
            XCTAssertGreaterThanOrEqual(m, target * (1 - 1e-9), "target=\(target)")
            XCTAssertLessThanOrEqual(m, target * 2, "取整不该把量程放大一倍以上")
        }
    }

    // MARK: 新量程的具体形状

    /// 主刻度是整数量级，不是等比分割。
    func testLogMajorTicksAreWholeDecades() {
        XCTAssertEqual(LogGaugeScale().majorTicks,
                       [10_000, 100_000, 1_000_000, 10_000_000])
    }

    func testDefaultRangesCoverObservedPeak() {
        let observedPeak = 8_350_000.0
        XCTAssertGreaterThanOrEqual(LogGaugeScale().maxValue, observedPeak)
        XCTAssertGreaterThanOrEqual(LinearGaugeScale().maxValue, observedPeak)
    }

    /// 默认量程下中位速率必须落在表盘中段，指针才看得出在动。
    func testLogPutsMedianRateNearMidDial() {
        let fraction = gaugeSweepFraction(value: 613_000, scale: LogGaugeScale())
        XCTAssertGreaterThan(fraction, 0.5)
        XCTAssertLessThan(fraction, 0.7)
        // 对照：线性量程下中位值几乎贴底
        XCTAssertLessThan(gaugeSweepFraction(value: 613_000, scale: LinearGaugeScale()), 0.1)
    }

    // MARK: 刻度标签宽度（叠字回归）

    /// **回归**：刻度用 `.position()` 摆放、以点为中心向两侧展开，标签一长
    /// 就会互相遮盖（实机出现过 `400.0k600.0k`）。字符数是宽度的可靠代理，
    /// 比断言具体字符串更能挡住未来改格式化函数时的回归。
    func testAllTickLabelsStayShortAcrossScalesAndPeaks() {
        let peaks: [Double] = [0, 50_000, 100_000, 613_000, 1_500_000,
                               1_710_000, 6_020_000, 8_350_000, 12_000_000]
        for peak in peaks {
            for id in allGaugeScaleIDs {
                let s = gaugeScale(id: id, recentPeak: peak)
                for tick in s.majorTicks {
                    let label = gaugeTickLabel(tick)
                    XCTAssertLessThanOrEqual(
                        label.count, 5,
                        "量程 \(id) (peak=\(peak)) 的刻度 \(tick) 标签为 `\(label)`，过长会叠字")
                }
            }
        }
    }

    /// 三种默认量程更严格：不超过 4 个字符。
    func testDefaultScaleTickLabelsAreAtMostFourCharacters() {
        for s in allScales {
            for tick in s.majorTicks {
                let label = gaugeTickLabel(tick)
                XCTAssertLessThanOrEqual(label.count, 4,
                                         "\(s.id) 的刻度标签 `\(label)` 过长")
            }
        }
    }
}
