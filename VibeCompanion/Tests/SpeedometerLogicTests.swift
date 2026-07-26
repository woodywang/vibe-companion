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
