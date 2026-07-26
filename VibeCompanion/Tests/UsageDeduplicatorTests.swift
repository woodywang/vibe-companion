import XCTest
@testable import VibeCompanion

final class UsageDeduplicatorTests: XCTestCase {

    private func entry(total: Int = 100,
                       isSidechain: Bool = false,
                       hasSpeed: Bool = false,
                       key: String? = "m1:r1") -> UsageEntry {
        UsageEntry(timestamp: Date(timeIntervalSince1970: 1000),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: total),
                   isSidechain: isSidechain, hasSpeed: hasSpeed,
                   isFastSpeed: false, dedupKey: key)
    }

    // MARK: dedupKey 构造

    func testDedupKeyJoinsMessageIdAndRequestId() {
        XCTAssertEqual(claudeDedupKey(messageId: "msg_1", requestId: "req_1"), "msg_1:req_1")
    }

    /// v19.0.3 语义：requestId 缺失时退化为仅用 messageId
    func testDedupKeyFallsBackToMessageIdAlone() {
        XCTAssertEqual(claudeDedupKey(messageId: "msg_1", requestId: nil), "msg_1")
    }

    /// messageId 缺失 -> nil，该条目永不参与去重
    func testDedupKeyNilWithoutMessageId() {
        XCTAssertNil(claudeDedupKey(messageId: nil, requestId: "req_1"))
        XCTAssertNil(claudeDedupKey(messageId: nil, requestId: nil))
    }

    // MARK: 优先级 1 —— 非 sidechain 胜过 sidechain

    func testNonSidechainReplacesSidechain() {
        let existing = entry(total: 10, isSidechain: true)
        let candidate = entry(total: 5, isSidechain: false)   // token 更少也要赢
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    func testSidechainDoesNotReplaceNonSidechain() {
        let existing = entry(total: 5, isSidechain: false)
        let candidate = entry(total: 10, isSidechain: true)   // token 更多也要输
        XCTAssertFalse(shouldReplace(candidate: candidate, existing: existing))
    }

    // MARK: 优先级 2 —— sidechain 状态相同时，token 总量大的胜

    func testLargerTotalReplacesSmaller() {
        XCTAssertTrue(shouldReplace(candidate: entry(total: 200), existing: entry(total: 100)))
    }

    func testSmallerTotalDoesNotReplace() {
        XCTAssertFalse(shouldReplace(candidate: entry(total: 50), existing: entry(total: 100)))
    }

    func testPriorityTwoAppliesWithinSidechainPairs() {
        let existing = entry(total: 100, isSidechain: true)
        let candidate = entry(total: 200, isSidechain: true)
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    // MARK: 优先级 3 —— 总量相同时，带 speed 字段的胜

    func testHasSpeedReplacesWhenTotalsEqual() {
        let existing = entry(total: 100, hasSpeed: false)
        let candidate = entry(total: 100, hasSpeed: true)
        XCTAssertTrue(shouldReplace(candidate: candidate, existing: existing))
    }

    func testNoSpeedDoesNotReplaceWhenTotalsEqual() {
        let existing = entry(total: 100, hasSpeed: true)
        let candidate = entry(total: 100, hasSpeed: false)
        XCTAssertFalse(shouldReplace(candidate: candidate, existing: existing))
    }

    func testIdenticalEntriesDoNotReplace() {
        XCTAssertFalse(shouldReplace(candidate: entry(), existing: entry()))
    }
}
