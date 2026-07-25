import XCTest
@testable import VibeCompanion

final class CyclingPetTests: XCTestCase {
    func testRevolutionsScaleWithSpeed() {
        XCTAssertEqual(CyclingPet.revolutionsPerSecond(speed: 1.0), 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(CyclingPet.revolutionsPerSecond(speed: 3.0),
                             CyclingPet.revolutionsPerSecond(speed: 1.0))
    }
    func testRevolutionsClamped() {
        XCTAssertEqual(CyclingPet.revolutionsPerSecond(speed: 0.0), 0.25, accuracy: 0.0001)
        XCTAssertEqual(CyclingPet.revolutionsPerSecond(speed: 99.0), 4.0, accuracy: 0.0001)
    }
}
