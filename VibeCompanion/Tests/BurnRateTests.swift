import XCTest
@testable import VibeCompanion

final class BurnRateTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_784_937_600)

    private func entry(minuteOffset: Double, counts: TokenCounts) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(minuteOffset * 60),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: counts, isSidechain: false, hasSpeed: false,
                   isFastSpeed: false, dedupKey: "m\(minuteOffset):r")
    }

    private func block(_ entries: [UsageEntry],
                       isGap: Bool = false,
                       costUSD: Double? = nil) -> SessionBlock {
        var counts = TokenCounts()
        for e in entries { counts += e.counts }
        return SessionBlock(id: "b", startTime: base,
                            endTime: base.addingTimeInterval(5 * 3600),
                            actualEndTime: entries.last?.timestamp,
                            isActive: true, isGap: isGap,
                            entries: entries, tokenCounts: counts, costUSD: costUSD)
    }

    // MARK: 三个 nil 守卫

    func testNilForEmptyBlock() {
        XCTAssertNil(calculateBurnRate(block([])))
    }

    func testNilForGapBlock() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 10)),
                 entry(minuteOffset: 10, counts: TokenCounts(input: 10))]
        XCTAssertNil(calculateBurnRate(block(e, isGap: true)))
    }

    /// 单条 entry -> duration == 0 -> nil（不是 0 速率）
    func testNilForSingleEntryBlock() {
        XCTAssertNil(calculateBurnRate(block([entry(minuteOffset: 0, counts: TokenCounts(input: 10))])))
    }

    func testNilWhenAllEntriesShareTimestamp() {
        let e = [entry(minuteOffset: 3, counts: TokenCounts(input: 10)),
                 entry(minuteOffset: 3, counts: TokenCounts(input: 20))]
        XCTAssertNil(calculateBurnRate(block(e)))
    }

    // MARK: 两个分子

    /// tokensPerMinute 用 Total（含 cache_read）；indicator 只用 input+output
    func testTwoNumeratorsDifferOnCacheBuckets() {
        let counts = TokenCounts(input: 100, output: 200, cacheCreation5m: 400,
                                 cacheCreation1h: 800, cacheRead: 1600)
        let e = [entry(minuteOffset: 0, counts: counts),
                 entry(minuteOffset: 10, counts: counts)]
        let r = calculateBurnRate(block(e))!
        // total = 3100 * 2 = 6200，跨 10 分钟
        XCTAssertEqual(r.tokensPerMinute, 620, accuracy: 0.0001)
        // indicator = 300 * 2 = 600，跨 10 分钟
        XCTAssertEqual(r.tokensPerMinuteForIndicator, 60, accuracy: 0.0001)
    }

    /// 分母是首条->末条，与块起点和 now 均无关
    func testDenominatorIsFirstToLastEntry() {
        let e = [entry(minuteOffset: 60, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 62, counts: TokenCounts(input: 100))]
        let r = calculateBurnRate(block(e))!
        XCTAssertEqual(r.tokensPerMinute, 100, accuracy: 0.0001)   // 200 / 2min
    }

    func testCostPerHourUsesSameDenominator() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 30, counts: TokenCounts(input: 100))]
        let r = calculateBurnRate(block(e, costUSD: 1.5))!
        // 1.5 USD / 30min * 60 = 3.0 USD/h
        XCTAssertEqual(r.costPerHour!, 3.0, accuracy: 0.0001)
    }

    func testCostPerHourNilWhenBlockCostNil() {
        let e = [entry(minuteOffset: 0, counts: TokenCounts(input: 100)),
                 entry(minuteOffset: 30, counts: TokenCounts(input: 100))]
        XCTAssertNil(calculateBurnRate(block(e))!.costPerHour)
    }

    // MARK: 档位阈值（对 indicator 生效）

    func testLevelBoundaries() {
        XCTAssertEqual(BurnRateLevel.from(indicator: 0), .normal)
        XCTAssertEqual(BurnRateLevel.from(indicator: 1999.9), .normal)
        XCTAssertEqual(BurnRateLevel.from(indicator: 2000), .moderate)
        XCTAssertEqual(BurnRateLevel.from(indicator: 4999.9), .moderate)
        XCTAssertEqual(BurnRateLevel.from(indicator: 5000), .high)
        XCTAssertEqual(BurnRateLevel.from(indicator: 100_000), .high)
    }
}
