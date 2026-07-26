import XCTest
@testable import VibeCompanion

final class SpeedometerLogicTests: XCTestCase {

    private let scale = LinearGaugeScale(maxValue: 1_000_000)

    // MARK: 配色分区（按量程比例，非绝对值）

    func testGreenBelowYellowFraction() {
        XCTAssertEqual(gaugeZone(value: 0, scale: scale), .green)
        XCTAssertEqual(gaugeZone(value: 699_999, scale: scale), .green)
    }

    func testYellowBetweenFractions() {
        XCTAssertEqual(gaugeZone(value: 700_000, scale: scale), .yellow)
        XCTAssertEqual(gaugeZone(value: 899_999, scale: scale), .yellow)
    }

    func testRedAboveRedFraction() {
        XCTAssertEqual(gaugeZone(value: 900_000, scale: scale), .red)
        XCTAssertEqual(gaugeZone(value: 1_000_000, scale: scale), .red)
        XCTAssertEqual(gaugeZone(value: 5_000_000, scale: scale), .red)
    }

    /// 阈值实测标定：旧的 0.60 / 0.85 在新量程下让表盘 46% 的时间是黄色。
    /// 新阈值在默认对数量程上把黄线放到约 1.26M、红线约 5.01M。
    func testColorThresholdsLandOnCalibratedRates() {
        let log = LogGaugeScale()
        XCTAssertEqual(gaugeZone(value: 1_200_000, scale: log), .green)
        XCTAssertEqual(gaugeZone(value: 1_300_000, scale: log), .yellow)
        XCTAssertEqual(gaugeZone(value: 4_900_000, scale: log), .yellow)
        XCTAssertEqual(gaugeZone(value: 5_100_000, scale: log), .red)
        // 中位速率必须是绿的——黄色成了常态就不再传达信息
        XCTAssertEqual(gaugeZone(value: 613_000, scale: log), .green)
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

    // MARK: 刻度标签的紧凑格式

    /// 整数量级不带小数——这是宽度减半的来源。
    func testTickLabelDropsDecimalsOnWholeMagnitudes() {
        XCTAssertEqual(gaugeTickLabel(10_000), "10k")
        XCTAssertEqual(gaugeTickLabel(100_000), "100k")
        XCTAssertEqual(gaugeTickLabel(1_000_000), "1M")
        XCTAssertEqual(gaugeTickLabel(10_000_000), "10M")
        XCTAssertEqual(gaugeTickLabel(2_000_000), "2M")
        XCTAssertEqual(gaugeTickLabel(750_000), "750k")
    }

    /// 非整数才带一位小数。
    func testTickLabelKeepsOneDecimalWhenNeeded() {
        XCTAssertEqual(gaugeTickLabel(1_500_000), "1.5M")
        XCTAssertEqual(gaugeTickLabel(7_500_000), "7.5M")
        XCTAssertEqual(gaugeTickLabel(1_080_000), "1.1M")
        XCTAssertEqual(gaugeTickLabel(12_300), "12.3k")
    }

    /// k / M 分界，以及"四舍五入后会进位"的边界不得写出 `1000k`。
    func testTickLabelUnitBoundaries() {
        XCTAssertEqual(gaugeTickLabel(0), "0")
        XCTAssertEqual(gaugeTickLabel(999), "999")
        XCTAssertEqual(gaugeTickLabel(1_000), "1k")
        XCTAssertEqual(gaugeTickLabel(999_000), "999k")
        XCTAssertEqual(gaugeTickLabel(999_999), "1M")
        XCTAssertEqual(gaugeTickLabel(1_000_001), "1M")
    }

    /// 与 LCD 口径分离：LCD 保留小数位，改刻度标签不得动到它。
    func testTickLabelIsShorterThanLcdFormat() {
        for value in [10_000.0, 100_000, 1_000_000, 10_000_000] {
            XCTAssertLessThan(gaugeTickLabel(value).count, speedometerFormat(value).count,
                              "\(value)")
        }
        XCTAssertEqual(speedometerFormat(1_000_000), "1.00M")   // LCD 未受影响
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
