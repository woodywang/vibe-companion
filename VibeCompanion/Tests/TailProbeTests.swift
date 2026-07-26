import XCTest
@testable import VibeCompanion

final class TailProbeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String, name: String = "a.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReturnsLastCompleteLine() throws {
        let url = try write("first\nsecond\nthird\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url), "third")
    }

    /// 末尾没有换行符时，最后一行仍算完整（文件可能正在被追加，但这是我们能拿到的最新一行）
    func testReturnsTrailingLineWithoutNewline() throws {
        let url = try write("first\nsecond")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url), "second")
    }

    func testSingleLineFile() throws {
        XCTAssertEqual(TailProbe.lastCompleteLine(of: try write("only")), "only")
    }

    func testEmptyFileReturnsNil() throws {
        XCTAssertNil(TailProbe.lastCompleteLine(of: try write("")))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TailProbe.lastCompleteLine(of: dir.appendingPathComponent("nope.jsonl")))
    }

    /// 探测窗口只覆盖文件尾部：前面的内容不影响结果
    func testOnlyReadsTailWindow() throws {
        let filler = String(repeating: "x", count: 40_000)
        let url = try write("\(filler)\nlast-line\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url, probeBytes: 1024), "last-line")
    }

    /// 探测窗口切在多字节字符中间时不得崩溃，也不得返回乱码行。
    /// 文件共 26 字节：你好世界(0-11) \n(12) 最后一行(13-24) \n(25)。
    /// probeBytes=15 使窗口从字节 11 起——正好切在“界”的第三个字节中间，
    /// 同时又包住 12 处的换行，故末条完整行可判定。
    func testHandlesMultibyteSplitAtWindowBoundary() throws {
        let url = try write("你好世界\n最后一行\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url, probeBytes: 15), "最后一行")
    }

    /// 窗口内一个换行都没有（末行超长）时返回 nil，调用方应保守回扫
    func testReturnsNilWhenNoNewlineInWindow() throws {
        let url = try write(String(repeating: "y", count: 5000))
        XCTAssertNil(TailProbe.lastCompleteLine(of: url, probeBytes: 100))
    }
}
