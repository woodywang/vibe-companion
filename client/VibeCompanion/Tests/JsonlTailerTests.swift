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

/// 回扫路径：`watch(_:startAtBeginning:)` 的首次读取是同步完成的
/// （`queue.sync` → `startWatching` → `readNew`），因此断言无需等待异步事件。
final class JsonlTailerBackfillTests: XCTestCase {

    private var dir: URL!
    private var tailer: JsonlTailer!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonltailer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tailer = JsonlTailer()
    }

    override func tearDownWithError() throws {
        tailer.stopAll()
        tailer = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func collect(_ url: URL, startAtBeginning: Bool) -> [String] {
        var received: [String] = []
        tailer.onLine = { _, line in received.append(line) }
        tailer.watch(url, startAtBeginning: startAtBeginning)
        return received
    }

    /// 回扫一个远大于单块（256 KB）的文件：每一行都必须完整送达且保持原序。
    /// 这是分块循环的核心保证——offset 必须按实际读取量推进，否则跨块会丢数据。
    func testBackfillReadsEveryLineOfMultiChunkFile() throws {
        let lineCount = 20_000
        let payload = String(repeating: "z", count: 80)   // ≈1.9 MB，跨 7 个块
        let expected = (0..<lineCount).map { "line-\($0)-\(payload)" }
        let url = dir.appendingPathComponent("big.jsonl")
        try (expected.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let received = collect(url, startAtBeginning: true)

        XCTAssertEqual(received.count, lineCount)
        XCTAssertEqual(received, expected)
    }

    /// 跨块边界的多字节字符不得被撕裂成乱码。
    func testBackfillPreservesMultibyteAcrossChunkBoundary() throws {
        // 每行 3 字节 × 100 个汉字，累计远超 256 KB，边界必然落在字符中间。
        let line = String(repeating: "界", count: 100)
        let lineCount = 4_000
        let url = dir.appendingPathComponent("cjk.jsonl")
        try Array(repeating: line, count: lineCount).joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let received = collect(url, startAtBeginning: true)

        XCTAssertEqual(received.count, lineCount)
        XCTAssertEqual(Set(received), [line])
    }

    /// startAtBeginning: false 时定位到 EOF——已有内容一律不回放。
    func testTailModeSkipsExistingContent() throws {
        let url = dir.appendingPathComponent("tail.jsonl")
        try "old-1\nold-2\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(collect(url, startAtBeginning: false), [])
    }

    /// 末尾的半行要留在缓冲里，不能当作完整行发出。
    func testBackfillHoldsBackTrailingPartialLine() throws {
        let url = dir.appendingPathComponent("partial.jsonl")
        try "done\nhalf".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(collect(url, startAtBeginning: true), ["done"])
    }
}
