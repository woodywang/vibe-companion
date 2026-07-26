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
