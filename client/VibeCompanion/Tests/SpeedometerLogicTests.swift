import XCTest
@testable import VibeCompanion

@MainActor
final class SpeedometerLogicTests: XCTestCase {

    // 角度映射（量程 0..500_000 tok/min）
    func testAngleAtZeroIsMin() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 0), -135.0, accuracy: 0.001)
    }

    func testAngleAtMidpointIsZero() {
        // 250_000 = 量程中点 -> 0°（正上）
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 250_000), 0.0, accuracy: 0.001)
    }

    func testAngleAtMax() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 500_000), 135.0, accuracy: 0.001)
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
