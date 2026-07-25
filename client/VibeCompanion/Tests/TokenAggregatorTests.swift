import XCTest
@testable import VibeCompanion

@MainActor
final class TokenAggregatorTests: XCTestCase {

    /// 基准时刻锚定在**本机时区**的当日 01:00。
    ///
    /// `TokenAggregator.dayKey` 按 `Calendar.current` 切分"今日"——这对用户是
    /// 正确行为，不该为迁就测试而改。但用例里最长的一条要跨 base+10h，
    /// 若 base 是个裸时间戳（如 1785000000，UTC+8 下 01:20、UTC 下则是前一天
    /// 17:20），在西半球时区就会跨本地日而假失败。锚到本地日首 +1h 后，
    /// base..base+11h 必落在同一本地日（任何时区的一天都不短于 23h），
    /// 于是断言与运行机器的时区无关。
    private let base: Date = {
        let anchor = Date(timeIntervalSince1970: 1_785_000_000)
        return Calendar.current.startOfDay(for: anchor).addingTimeInterval(3600)
    }()

    private struct NoPricing: PricingSource {
        func pricing(for model: String) -> ModelPricing? { nil }
    }

    private struct FlatPricing: PricingSource {
        let rate: Double
        func pricing(for model: String) -> ModelPricing? {
            ModelPricing(input: rate, output: rate, cacheCreate: rate, cacheRead: rate,
                         cacheReadExplicit: true, inputAbove200k: nil, outputAbove200k: nil,
                         cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                         longContextThreshold: nil, fastMultiplier: 1.0)
        }
    }

    private func entry(min: Double, input: Int = 0, output: Int = 0,
                       cacheRead: Int = 0, key: String) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(min * 60),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: input, output: output, cacheRead: cacheRead),
                   isSidechain: false, hasSpeed: false, isFastSpeed: false, dedupKey: key)
    }

    private func aggregator(nowOffsetMin: Double,
                            pricing: PricingSource = NoPricing()) -> TokenAggregator {
        TokenAggregator(pricing: pricing, retentionHours: 6, idleTimeoutSeconds: 90,
                        now: { self.base.addingTimeInterval(nowOffsetMin * 60) })
    }

    // MARK: 主速率

    func testRateUsesTotalTokensIncludingCacheRead() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, output: 100, cacheRead: 800, key: "k1"))
        a.ingest(entry(min: 10, input: 100, output: 100, cacheRead: 800, key: "k2"))
        a.recompute()
        // total = 2000，跨 10 分钟
        XCTAssertEqual(a.tokensPerMinute, 200, accuracy: 0.001)
    }

    func testIndicatorExcludesCacheBuckets() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, output: 100, cacheRead: 800, key: "k1"))
        a.ingest(entry(min: 10, input: 100, output: 100, cacheRead: 800, key: "k2"))
        a.recompute()
        // input+output = 400，跨 10 分钟
        XCTAssertEqual(a.indicatorTokensPerMinute, 40, accuracy: 0.001)
        XCTAssertEqual(a.level, .normal)
    }

    func testLevelFollowsIndicatorNotTotal() {
        let a = aggregator(nowOffsetMin: 2)
        // indicator = 12000/1min = 12000 -> high，尽管 total 更大
        a.ingest(entry(min: 0, input: 6000, output: 0, cacheRead: 900_000, key: "k1"))
        a.ingest(entry(min: 1, input: 6000, output: 0, cacheRead: 900_000, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.level, .high)
    }

    // MARK: 窗口以 entry timestamp 为准

    func testUsesEntryTimestampNotArrivalTime() {
        let a = aggregator(nowOffsetMin: 11)
        // 两条 entry 的时间戳相隔 10 分钟，但都是"此刻"注入的
        a.ingest(entry(min: 0, input: 500, key: "k1"))
        a.ingest(entry(min: 10, input: 500, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.tokensPerMinute, 100, accuracy: 0.001)   // 1000 / 10min
    }

    // MARK: 单条 entry -> 无速率

    func testSingleEntryYieldsNoBurnRate() {
        let a = aggregator(nowOffsetMin: 1)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.recompute()
        XCTAssertFalse(a.hasBurnRate)
        XCTAssertEqual(a.tokensPerMinute, 0, accuracy: 0.001)
    }

    func testTwoEntriesYieldBurnRate() {
        let a = aggregator(nowOffsetMin: 2)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 1, input: 100, key: "k2"))
        a.recompute()
        XCTAssertTrue(a.hasBurnRate)
    }

    // MARK: 空闲归零（偏离 D1）

    func testIdleAfterTimeoutZeroesRate() {
        let a = aggregator(nowOffsetMin: 20)      // 距末条 entry 10 分钟 > 90s
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertTrue(a.isIdle)
        XCTAssertEqual(a.tokensPerMinute, 0, accuracy: 0.001)
    }

    func testNotIdleWithinTimeout() {
        let a = aggregator(nowOffsetMin: 11)      // 距末条 60s < 90s
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertFalse(a.isIdle)
        XCTAssertGreaterThan(a.tokensPerMinute, 0)
    }

    // MARK: 去重

    func testDuplicateKeyIsDeduped() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 0, input: 100, key: "k1"))   // 同键，同量 -> 丢弃
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.tokensPerMinute, 20, accuracy: 0.001)   // 200/10，不是 300/10
    }

    // MARK: 今日累计

    func testTodayTotalUsesTotalTokensAndDedupes() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 10, cacheRead: 90, key: "k1"))
        a.ingest(entry(min: 0, input: 10, cacheRead: 90, key: "k1"))   // 重复
        a.ingest(entry(min: 10, input: 10, cacheRead: 90, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.todayTotal, 200)
    }

    /// 今日累计不受 6h 主窗口驱逐影响
    func testTodayTotalSurvivesMainWindowEviction() {
        let a = aggregator(nowOffsetMin: 60 * 10)     // now = base + 10h
        a.ingest(entry(min: 0, input: 100, key: "k1"))         // 10h 前，已被主窗口驱逐
        a.ingest(entry(min: 60 * 9, input: 100, key: "k2"))    // 1h 前
        a.recompute()
        XCTAssertEqual(a.todayTotal, 200)
    }

    // MARK: cost

    func testCostPerHourComputedFromPerEntryCosts() {
        let a = aggregator(nowOffsetMin: 31, pricing: FlatPricing(rate: 1e-3))
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 30, input: 1000, key: "k2"))
        a.recompute()
        // cost = 2000 * 1e-3 = 2.0 USD，跨 30 分钟 -> 4.0 USD/h
        XCTAssertEqual(a.costPerHour!, 4.0, accuracy: 1e-9)
    }

    func testCostNilWhenPricingUnavailable() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertNil(a.costPerHour)
        // 定价缺失不得影响速率
        XCTAssertGreaterThan(a.tokensPerMinute, 0)
    }

    // MARK: 近期峰值

    func testRecentPeakTracksMaximum() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 10, input: 1000, key: "k2"))
        a.recompute()
        let peak = a.recentPeak
        XCTAssertGreaterThan(peak, 0)
        XCTAssertGreaterThanOrEqual(peak, a.tokensPerMinute)
    }

    /// 时钟可推进的聚合器，用于观察 `recentPeak` 随时间的回落
    private func movableAggregator() -> (TokenAggregator, (Double) -> Void) {
        let clock = MutableClock(base)
        let a = TokenAggregator(pricing: NoPricing(), retentionHours: 6,
                                idleTimeoutSeconds: 90,
                                now: { clock.value })
        return (a, { clock.value = self.base.addingTimeInterval($0 * 60) })
    }

    private final class MutableClock {
        var value: Date
        init(_ v: Date) { value = v }
    }

    /// 核心回归：一次尖峰不得把量程永久钉住
    func testRecentPeakDecaysOverTime() {
        let (a, setNow) = movableAggregator()
        a.ingest(entry(min: 0, input: 100_000, key: "k1"))
        a.ingest(entry(min: 1, input: 100_000, key: "k2"))
        setNow(1)
        a.recompute()
        let spike = a.recentPeak
        XCTAssertGreaterThan(spike, 0)

        // 静置 5 分钟（恰好一个半衰期）后再重算
        setNow(6)
        a.recompute()
        XCTAssertLessThan(a.recentPeak, spike, "峰值必须回落，不能只涨不跌")
        XCTAssertEqual(a.recentPeak, spike * 0.5, accuracy: spike * 1e-6)
    }

    /// 长时间静置后峰值收敛到 0，量程回到 100k 底档
    func testRecentPeakConvergesToZeroWhenIdleLongEnough() {
        let (a, setNow) = movableAggregator()
        a.ingest(entry(min: 0, input: 100_000, key: "k1"))
        a.ingest(entry(min: 1, input: 100_000, key: "k2"))
        setNow(1)
        a.recompute()
        XCTAssertGreaterThan(a.recentPeak, 0)

        setNow(180)          // 静置 3 小时 = 36 个半衰期
        a.recompute()
        XCTAssertEqual(a.recentPeak, 0, accuracy: 1e-9)
    }

    /// 衰减之后仍要能被新的高速率顶上去
    func testRecentPeakStillRisesAfterDecay() {
        let (a, setNow) = movableAggregator()
        a.ingest(entry(min: 0, input: 1_000, key: "k1"))
        a.ingest(entry(min: 1, input: 1_000, key: "k2"))
        setNow(1)
        a.recompute()
        let small = a.recentPeak

        a.ingest(entry(min: 2, input: 500_000, key: "k3"))
        setNow(2)
        a.recompute()
        XCTAssertGreaterThan(a.recentPeak, small)
        XCTAssertEqual(a.recentPeak, a.tokensPerMinute, accuracy: 1e-6)
    }
}
