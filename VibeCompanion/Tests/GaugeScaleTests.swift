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
