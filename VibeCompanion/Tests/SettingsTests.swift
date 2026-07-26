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

    /// 默认对数：瞬时速率跨三个数量级，线性量程下中位值只占 7.3% 行程。
    func testGaugeScaleIDDefaultsToLog() {
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "log")
    }

    func testGaugeScaleIDPersists() {
        let s = Settings(defaults: defaults)
        s.gaugeScaleID = "adaptive"
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "adaptive")
    }

    /// 存进未知值时读回应回退到默认，避免 UI 拿到无效标识
    func testUnknownGaugeScaleIDFallsBackToDefault() {
        defaults.set("bogus", forKey: "vc.gaugeScaleID")
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "log")
    }

    // MARK: 瞬时速率时间常数

    func testInstantRateTauDefaultsTo30() {
        XCTAssertEqual(Settings(defaults: defaults).instantRateTauSeconds,
                       defaultInstantRateTauSeconds)
        XCTAssertEqual(defaultInstantRateTauSeconds, 30)
    }

    func testInstantRateTauPersists() {
        let s = Settings(defaults: defaults)
        s.instantRateTauSeconds = 120
        XCTAssertEqual(Settings(defaults: defaults).instantRateTauSeconds, 120)
    }

    /// 非法档位（旧版本写入 / 手工 defaults write）读回应落到默认。
    func testUnknownInstantRateTauFallsBackToDefault() {
        defaults.set(7.5, forKey: "vc.instantRateTau")
        XCTAssertEqual(Settings(defaults: defaults).instantRateTauSeconds,
                       defaultInstantRateTauSeconds)
    }

    /// 新增的 key 不得动到既有设置。
    func testInstantRateTauUsesItsOwnKey() {
        let s = Settings(defaults: defaults)
        s.isPaused = true
        s.gaugeScaleID = "adaptive"
        s.instantRateTauSeconds = 60
        XCTAssertTrue(Settings(defaults: defaults).isPaused)
        XCTAssertEqual(Settings(defaults: defaults).gaugeScaleID, "adaptive")
    }

    func testPausedDefaultsToFalseAndPersists() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.isPaused)
        s.isPaused = true
        XCTAssertTrue(Settings(defaults: defaults).isPaused)
    }
}
