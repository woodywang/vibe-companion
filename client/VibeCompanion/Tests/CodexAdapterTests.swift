import XCTest
@testable import VibeCompanion

final class CodexAdapterTests: XCTestCase {

    private let adapter = CodexAdapter(roots: [])

    private func parse(_ json: String, context: inout ParseContext) -> UsageEntry? {
        adapter.parse(line: json, context: &context)
    }

    private func parse(_ json: String) -> UsageEntry? {
        var ctx = ParseContext()
        return adapter.parse(line: json, context: &ctx)
    }

    private func tokenCount(input: Int, cached: Int, output: Int,
                            reasoning: Int, total: Int) -> String {
        """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"token_count","info":{
           "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),
             "output_tokens":\(output),"reasoning_output_tokens":\(reasoning),
             "total_tokens":\(total)}}}}
        """
    }

    /// 核心修复：cached 嵌套在 input 内，必须相减
    func testCachedInputIsSubtractedFromInput() {
        let e = parse(tokenCount(input: 100, cached: 90, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.input, 10)          // 100 - 90
        XCTAssertEqual(e.counts.cacheRead, 90)
        XCTAssertEqual(e.counts.output, 5)
    }

    /// cached 超过 input 时先 clamp，避免负数
    func testCachedIsClampedToInput() {
        let e = parse(tokenCount(input: 50, cached: 80, output: 5,
                                 reasoning: 0, total: 55))!
        XCTAssertEqual(e.counts.input, 0)
        XCTAssertEqual(e.counts.cacheRead, 50)
    }

    func testNoCacheCreationBuckets() {
        let e = parse(tokenCount(input: 100, cached: 0, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.cacheCreation5m, 0)
        XCTAssertEqual(e.counts.cacheCreation1h, 0)
    }

    /// total 直取文件值，差额进 extraTotal
    func testTotalMatchesFileValue() {
        let e = parse(tokenCount(input: 100, cached: 90, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.total, 105)
    }

    /// reasoning 已含在 output 内，不得重复相加
    func testReasoningIsNotAddedSeparately() {
        // input 100 (cached 0) + output 20，其中 reasoning 15 已在 output 内
        let e = parse(tokenCount(input: 100, cached: 0, output: 20,
                                 reasoning: 15, total: 120))!
        XCTAssertEqual(e.counts.output, 20)
        XCTAssertEqual(e.counts.total, 120)         // 不是 135
    }

    func testTotalFallsBackWhenFileTotalMissing() {
        let json = """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"token_count","info":{
           "last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.total, 107)         // 60 + 40 + 7
        XCTAssertEqual(e.counts.extraTotal, 0)
    }

    func testAgentId() {
        XCTAssertEqual(parse(tokenCount(input: 1, cached: 0, output: 1,
                                        reasoning: 0, total: 2))!.agent, "codex")
    }

    // MARK: sticky model

    func testTurnContextSetsStickyModelForLaterLines() {
        var ctx = ParseContext()
        let turn = """
        {"timestamp":"2026-07-16T13:16:00.000Z","type":"turn_context",
         "payload":{"model":"gpt-5.3-codex"}}
        """
        XCTAssertNil(parse(turn, context: &ctx))
        XCTAssertEqual(ctx.stickyModel, "gpt-5.3-codex")

        let e = parse(tokenCount(input: 10, cached: 0, output: 1,
                                 reasoning: 0, total: 11), context: &ctx)!
        XCTAssertEqual(e.model, "gpt-5.3-codex")
    }

    func testModelIsNilWithoutTurnContext() {
        XCTAssertNil(parse(tokenCount(input: 1, cached: 0, output: 1,
                                      reasoning: 0, total: 2))!.model)
    }

    // MARK: 去重键

    /// 去重键由 (timestamp, model, 各 token 值) 组成，不含 sessionId
    func testDedupKeyIsStableForIdenticalRecords() {
        let a = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        let b = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        XCTAssertEqual(a.dedupKey, b.dedupKey)
        XCTAssertNotNil(a.dedupKey)
    }

    func testDedupKeyDiffersWhenTokensDiffer() {
        let a = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        let b = parse(tokenCount(input: 11, cached: 2, output: 3, reasoning: 0, total: 14))!
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
    }

    // MARK: 拒绝的行

    func testRejectsNonTokenCountPayload() {
        XCTAssertNil(parse("""
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"agent_message","message":"hi"}}
        """))
    }

    func testRejectsMalformedJson() {
        XCTAssertNil(parse("{nope"))
    }

    // MARK: timestamp(fromLine:)

    func testTimestampFromArbitraryLine() {
        let ts = adapter.timestamp(fromLine: """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg","payload":{}}
        """)
        XCTAssertEqual(ts!.timeIntervalSince1970, 1_784_207_800.694, accuracy: 0.002)
    }
}
