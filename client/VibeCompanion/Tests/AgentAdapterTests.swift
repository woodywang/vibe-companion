import XCTest
@testable import VibeCompanion

final class AgentAdapterTests: XCTestCase {

    func testParseContextStartsWithNoStickyModel() {
        XCTAssertNil(ParseContext().stickyModel)
    }

    func testExpandTildePathsSplitsOnComma() {
        let urls = expandTildePaths("/a,/b,/c", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["/a", "/b", "/c"])
    }

    func testExpandTildePathsTrimsWhitespaceAndDropsEmpty() {
        let urls = expandTildePaths(" /a , , /b ", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["/a", "/b"])
    }

    func testExpandTildePathsExpandsTildeWhenEnabled() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let urls = expandTildePaths("~/foo", expandTilde: true)
        XCTAssertEqual(urls.map(\.path), ["\(home)/foo"])
    }

    /// Codex 的 CODEX_HOME 不展开 ~（对齐 ccusage）
    func testExpandTildePathsLeavesTildeWhenDisabled() {
        let urls = expandTildePaths("~/foo", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["~/foo"])
    }

    func testExpandTildePathsReturnsEmptyForNil() {
        XCTAssertTrue(expandTildePaths(nil, expandTilde: true).isEmpty)
    }
}
