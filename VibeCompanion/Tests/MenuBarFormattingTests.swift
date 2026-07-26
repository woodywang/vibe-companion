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
