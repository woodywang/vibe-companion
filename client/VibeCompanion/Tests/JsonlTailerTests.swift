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
    func testNonZeroStartIndexSlice() {
        // A Data from suffix(from:) has a non-zero startIndex; split must use
        // the Data's own indices, not 0-based integer indexing.
        let full = Data("skip\nhead\ntail".utf8)
        let slice = full.suffix(from: 5)          // startIndex == 5: "head\ntail"
        XCTAssertNotEqual(slice.startIndex, 0)
        let (lines, rest) = LineSplitter.split(slice)
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["head"])
        XCTAssertEqual(String(data: rest, encoding: .utf8), "tail")
    }
}
