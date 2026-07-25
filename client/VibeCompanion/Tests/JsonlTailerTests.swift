import XCTest
@testable import VibeCompanion

final class JsonlTailerTests: XCTestCase {
    func testCompleteLines() {
        let (lines, rest) = LineSplitter.split(Data("a\nb\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["a", "b"])
        XCTAssertEqual(rest.count, 0)
    }
    func testTrailingPartialKept() {
        let (lines, rest) = LineSplitter.split(Data("a\nb".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["a"])
        XCTAssertEqual(String(data: rest, encoding: .utf8), "b")
    }
    func testMultibyteAcrossSplit() {
        // "你好" split mid-byte: first chunk ends inside the character.
        let full = Data("x\n你好".utf8)
        let cut = full.count - 1
        let (l1, r1) = LineSplitter.split(full.prefix(cut))
        let (l2, r2) = LineSplitter.split(r1 + full.suffix(from: cut))
        let all = (l1 + l2).compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(all, ["x"])
        XCTAssertEqual(String(data: r2, encoding: .utf8), "你好")
    }
}
