import XCTest
@testable import VibeCompanion

final class DateParsingTests: XCTestCase {
    func testFractionalSeconds() {
        let d = DateParsing.parseISO8601("2026-07-25T09:30:00.123Z")
        XCTAssertNotNil(d)
        XCTAssertEqual(Int64(d!.timeIntervalSince1970 * 1000), 1_784_971_800_123)
    }
    func testNoFractional() {
        XCTAssertNotNil(DateParsing.parseISO8601("2026-07-25T09:30:00Z"))
    }
    func testInvalid() {
        XCTAssertNil(DateParsing.parseISO8601("not-a-date"))
    }
}
