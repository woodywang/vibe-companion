import XCTest
@testable import VibeCompanion

final class CollectorTests: XCTestCase {

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 一个可控的假 adapter：文件列表与时间戳解析都由测试指定
    private struct FakeAdapter: AgentAdapter {
        let id = "fake"
        var files: [URL] = []
        var timestampByLine: [String: Date] = [:]
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? { nil }
        func timestamp(fromLine line: String) -> Date? { timestampByLine[line] }
    }

    private func write(_ contents: String, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collector(_ adapter: AgentAdapter) -> Collector {
        Collector(adapters: [adapter], backfillWindowHours: 6, now: { self.now })
    }

    func testBackfillsWhenLastEntryInsideWindow() throws {
        let url = try write("old\nrecent\n", name: "a.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["recent": now.addingTimeInterval(-3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testSkipsBackfillWhenLastEntryOutsideWindow() throws {
        let url = try write("old\nancient\n", name: "b.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["ancient": now.addingTimeInterval(-10 * 3600)])
        XCTAssertFalse(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsAtExactWindowBoundary() throws {
        let url = try write("x\nedge\n", name: "c.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["edge": now.addingTimeInterval(-6 * 3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 时间戳解析失败 -> 保守回扫
    func testBackfillsWhenTimestampUnparseable() throws {
        let url = try write("x\nunknown\n", name: "d.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 探测不到完整行（空文件）-> 保守回扫
    func testBackfillsWhenProbeFindsNothing() throws {
        let url = try write("", name: "e.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsWhenFileMissing() {
        let url = dir.appendingPathComponent("nope.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 端到端：回扫真实 Claude 行并产出 entry
    func testStartEmitsEntriesFromBackfilledFile() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5}}}
        """
        let url = try write(line + "\n", name: "claude.jsonl")
        let adapter = ClaudeAdapter(roots: [])

        // 直接驱动 tailer 路径：用真实 ClaudeAdapter 但把文件列表固定住
        // now 取 entry 之后 1 小时（entry 是 2026-07-25T07:00:00Z == 1784962800）
        let c = Collector(adapters: [FixedFileAdapter(inner: adapter, files: [url])],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })
        var got: [UsageEntry] = []
        let done = expectation(description: "entry")
        done.assertForOverFulfill = false
        c.onEntry = { got.append($0); done.fulfill() }
        c.start()
        wait(for: [done], timeout: 3)
        c.stop()

        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].counts.input, 10)
        XCTAssertEqual(got[0].dedupKey, "m1:r1")
    }

    /// 包装器：复用真实 adapter 的解析，但固定文件列表
    private struct FixedFileAdapter: AgentAdapter {
        let inner: AgentAdapter
        let files: [URL]
        var id: String { inner.id }
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? {
            inner.parse(line: line, context: &context)
        }
        func timestamp(fromLine line: String) -> Date? { inner.timestamp(fromLine: line) }
    }
}
