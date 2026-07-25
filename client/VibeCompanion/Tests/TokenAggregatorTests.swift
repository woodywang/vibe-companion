import XCTest
@testable import VibeCompanion

@MainActor
final class TokenAggregatorTests: XCTestCase {
    private func ev(total: Int, weightedInput: Int, at ms: Int64) -> UsageEvent {
        UsageEvent(sourceUuid: "u\(ms)", agent: "claude", sessionId: nil, model: nil,
                   inputTokens: weightedInput, outputTokens: 0, cacheCreationTokens: 0,
                   cacheReadTokens: total - weightedInput, reasoningTokens: 0,
                   totalTokens: total, recordedAt: ms)
    }

    func testEffectiveExcludesCacheRead() {
        XCTAssertEqual(ev(total: 100, weightedInput: 10, at: 0).effectiveTokens, 10)
    }

    func testTodayResetsAcrossDay() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let agg = TokenAggregator(windowSeconds: 60, now: { now })
        agg.ingest(ev(total: 50, weightedInput: 50, at: Int64(now.timeIntervalSince1970 * 1000)))
        XCTAssertEqual(agg.todayTotal, 50)
        now = now.addingTimeInterval(86_400)   // next day
        agg.ingest(ev(total: 20, weightedInput: 20, at: Int64(now.timeIntervalSince1970 * 1000)))
        XCTAssertEqual(agg.todayTotal, 20)
    }
}
