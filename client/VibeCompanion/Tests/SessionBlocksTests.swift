import XCTest
@testable import VibeCompanion

final class SessionBlocksTests: XCTestCase {

    private let hourMs: Int64 = 3_600_000

    func testFloorOnExactHourIsIdentity() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs), 5 * hourMs)
    }

    func testFloorMidHourRoundsDown() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs + 1), 5 * hourMs)
        XCTAssertEqual(floorToUTCHourMillis(6 * hourMs - 1), 5 * hourMs)
    }

    func testFloorAtZero() {
        XCTAssertEqual(floorToUTCHourMillis(0), 0)
    }

    /// 关键：欧几里得除法而非截断除法。
    /// -1 ms 属于 [-1h, 0) 这个小时，应向下取整到 -1h，而不是 0。
    func testFloorNegativeUsesEuclideanDivision() {
        XCTAssertEqual(floorToUTCHourMillis(-1), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs - 1), -2 * hourMs)
    }

    /// Date 包装版：2026-07-25T17:22:13.456Z -> 2026-07-25T17:00:00Z
    func testFloorDateDropsMinutesSecondsMillis() {
        let d = Date(timeIntervalSince1970: 1_785_000_133.456)
        let floored = floorToUTCHour(d)
        let secs = floored.timeIntervalSince1970
        XCTAssertEqual(secs.truncatingRemainder(dividingBy: 3600), 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(floored, d)
        XCTAssertLessThan(d.timeIntervalSince(floored), 3600)
    }

    func testSessionDurationIsFiveHours() {
        XCTAssertEqual(SessionBlockConfig.durationHours, 5.0)
    }
}
