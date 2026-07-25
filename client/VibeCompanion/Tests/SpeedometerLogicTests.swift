import XCTest
@testable import VibeCompanion

@MainActor
final class SpeedometerLogicTests: XCTestCase {

    // 角度映射
    func testAngleAtZeroIsMin() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 0), -135.0, accuracy: 0.001)
    }

    func testAngleAt8000IsZero() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 8000), 0.0, accuracy: 0.001)
    }

    func testAngleAt16000IsMax() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 16000), 135.0, accuracy: 0.001)
    }

    // 越界 clamp
    func testAngleClampsAboveMax() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 1_000_000), 135.0, accuracy: 0.001)
    }

    func testAngleClampsBelowZero() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: -50), -135.0, accuracy: 0.001)
    }

    // idle
    func testIdleBelowThreshold() {
        XCTAssertTrue(speedometerIsIdle(tokensPerMinute: 0.5))
        XCTAssertTrue(speedometerIsIdle(tokensPerMinute: 0))
    }

    func testNotIdleAtOrAboveThreshold() {
        XCTAssertFalse(speedometerIsIdle(tokensPerMinute: 1.0))
        XCTAssertFalse(speedometerIsIdle(tokensPerMinute: 500))
    }

    // 格式化（对齐现有 FloatingPetContent.formatRate 行为：<1000 整数）
    func testFormatSmall() {
        XCTAssertEqual(speedometerFormat(0), "0")
        XCTAssertEqual(speedometerFormat(999), "999")
    }

    // 格式化（<1_000_000 "%.1fk"，含 9999 -> "10.0k" 的进位口径）
    func testFormatThousands() {
        XCTAssertEqual(speedometerFormat(9999), "10.0k")
        XCTAssertEqual(speedometerFormat(10_000), "10.0k")
        XCTAssertEqual(speedometerFormat(12_300), "12.3k")
    }

    func testFormatMillions() {
        XCTAssertEqual(speedometerFormat(1_000_000), "1.00M")
        XCTAssertEqual(speedometerFormat(2_340_000), "2.34M")
    }
}
