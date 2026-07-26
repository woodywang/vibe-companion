import XCTest
@testable import VibeCompanion

final class ClaudeAdapterTests: XCTestCase {

    private let adapter = ClaudeAdapter(roots: [])

    private func parse(_ json: String) -> UsageEntry? {
        var ctx = ParseContext()
        return adapter.parse(line: json, context: &ctx)
    }

    private let full = """
    {"type":"assistant","uuid":"u1","requestId":"req_1","sessionId":"s1",
     "isSidechain":false,"timestamp":"2026-07-25T07:42:13.456Z",
     "message":{"id":"msg_1","model":"claude-opus-5",
       "usage":{"input_tokens":2,"output_tokens":557,
         "cache_creation_input_tokens":22240,"cache_read_input_tokens":20749,
         "cache_creation":{"ephemeral_1h_input_tokens":22240,"ephemeral_5m_input_tokens":0},
         "speed":"standard"}}}
    """

    func testParsesAllTokenBuckets() {
        let e = parse(full)!
        XCTAssertEqual(e.counts.input, 2)
        XCTAssertEqual(e.counts.output, 557)
        XCTAssertEqual(e.counts.cacheRead, 20749)
        XCTAssertEqual(e.counts.cacheCreation1h, 22240)
        XCTAssertEqual(e.counts.cacheCreation5m, 0)
        XCTAssertEqual(e.counts.extraTotal, 0)
    }

    func testAgentIdAndModelAndSession() {
        let e = parse(full)!
        XCTAssertEqual(e.agent, "claude")
        XCTAssertEqual(e.model, "claude-opus-5")
        XCTAssertEqual(e.sessionId, "s1")
    }

    func testDedupKeyUsesMessageIdAndRequestIdNotUuid() {
        XCTAssertEqual(parse(full)!.dedupKey, "msg_1:req_1")
    }

    func testTimestampParsedAsUTC() {
        let e = parse(full)!
        // 2026-07-25T07:42:13.456Z == 1784965333.456
        XCTAssertEqual(e.timestamp.timeIntervalSince1970, 1_784_965_333.456, accuracy: 0.002)
    }

    func testSpeedStandardIsNotFastButIsPresent() {
        let e = parse(full)!
        XCTAssertTrue(e.hasSpeed)
        XCTAssertFalse(e.isFastSpeed)
    }

    func testSpeedFastDetected() {
        let json = full.replacingOccurrences(of: "\"speed\":\"standard\"", with: "\"speed\":\"fast\"")
        let e = parse(json)!
        XCTAssertTrue(e.hasSpeed)
        XCTAssertTrue(e.isFastSpeed)
    }

    func testMissingSpeedFieldMarksHasSpeedFalse() {
        // 注意：`full` 是多行原始字符串，逗号与 "speed" 之间隔着换行与缩进，
        // 纯字面量替换无法命中，故用正则容忍中间的空白。
        let json = full.replacingOccurrences(of: #",\s*"speed":"standard""#,
                                             with: "", options: .regularExpression)
        let e = parse(json)!
        XCTAssertFalse(e.hasSpeed)
        XCTAssertFalse(e.isFastSpeed)
    }

    func testSidechainFlagParsed() {
        let json = full.replacingOccurrences(of: "\"isSidechain\":false",
                                             with: "\"isSidechain\":true")
        XCTAssertTrue(parse(json)!.isSidechain)
    }

    /// cache_creation 对象存在时，扁平字段被完全忽略
    func testNestedCacheCreationOverridesFlatField() {
        let json = """
        {"timestamp":"2026-07-25T07:00:00.000Z","requestId":"r","message":{"id":"m",
          "usage":{"input_tokens":1,"output_tokens":1,
            "cache_creation_input_tokens":99999,
            "cache_creation":{"ephemeral_1h_input_tokens":10,"ephemeral_5m_input_tokens":20}}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.cacheCreation1h, 10)
        XCTAssertEqual(e.counts.cacheCreation5m, 20)
        XCTAssertEqual(e.counts.cacheCreationTotal, 30)
    }

    /// 无 cache_creation 对象时，扁平字段整体计入 5m 档
    func testFlatCacheCreationGoesTo5mBucketWhenObjectAbsent() {
        let json = """
        {"timestamp":"2026-07-25T07:00:00.000Z","requestId":"r","message":{"id":"m",
          "usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":777}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.cacheCreation5m, 777)
        XCTAssertEqual(e.counts.cacheCreation1h, 0)
    }

    // MARK: 拒绝的行

    func testRejectsLineWithoutUsage() {
        XCTAssertNil(parse("""
        {"type":"user","timestamp":"2026-07-25T07:00:00.000Z","message":{"id":"m"}}
        """))
    }

    func testRejectsLineWithoutTimestamp() {
        XCTAssertNil(parse("""
        {"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """))
    }

    func testRejectsMalformedJson() {
        XCTAssertNil(parse("{not json"))
    }

    /// 不检查 type == "assistant"（对齐 ccusage）
    func testAcceptsUsageLineWithUnexpectedType() {
        let json = """
        {"type":"whatever","timestamp":"2026-07-25T07:00:00.000Z","requestId":"r",
         "message":{"id":"m","usage":{"input_tokens":5,"output_tokens":6}}}
        """
        XCTAssertEqual(parse(json)!.counts.input, 5)
    }

    // MARK: timestamp(fromLine:)

    func testTimestampFromNonUsageLine() {
        let ts = adapter.timestamp(fromLine: """
        {"type":"user","timestamp":"2026-07-25T07:42:13.456Z"}
        """)
        XCTAssertEqual(ts!.timeIntervalSince1970, 1_784_965_333.456, accuracy: 0.002)
    }

    func testTimestampNilForMalformedLine() {
        XCTAssertNil(adapter.timestamp(fromLine: "garbage"))
    }
}
