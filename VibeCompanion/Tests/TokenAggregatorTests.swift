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
        TokenAggregator(pricing: pricing, retentionHours: 6, instantRateTauSeconds: 30,
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

    // MARK: 菜单栏口径 = 纯 ccusage，不再有空闲归零

    /// 回归：曾经这里有一条「距末条 entry > 90 秒即归零」的补丁，实测每 13.6
    /// 分钟触发一次，造成「满值 → 瞬间归零 → 弹回满值」的暴跳。删掉之后
    /// ccusage 的原生冻结语义恢复：分母是「末条 − 首条」，空闲不稀释速率。
    func testBlockRateFreezesWhenIdleInsteadOfZeroing() {
        let a = aggregator(nowOffsetMin: 20)      // 距末条 entry 已 10 分钟
        a.ingest(entry(min: 0, input: 100, key: "k1"))
        a.ingest(entry(min: 10, input: 100, key: "k2"))
        a.recompute()
        XCTAssertTrue(a.hasBurnRate)
        XCTAssertEqual(a.tokensPerMinute, 20, accuracy: 0.001)   // 200 / 10min，不是 0
        XCTAssertEqual(a.indicatorTokensPerMinute, 20, accuracy: 0.001)
    }

    /// 花费同样不再被空闲抹成 nil。
    func testCostSurvivesIdle() {
        let a = aggregator(nowOffsetMin: 60, pricing: FlatPricing(rate: 1e-3))
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 30, input: 1000, key: "k2"))
        a.recompute()
        XCTAssertEqual(a.costPerHour!, 4.0, accuracy: 1e-9)
    }

    // MARK: 瞬时速率（表盘口径）

    /// 表盘的即时反馈：一条记录刚落地，瞬时速率立刻抬起来，
    /// 而此时 ccusage 的区块速率还是全程平均。
    func testInstantRateRespondsImmediatelyWhileBlockRateAverages() {
        let a = aggregator(nowOffsetMin: 10)
        a.ingest(entry(min: 0, input: 1_000, key: "k1"))
        a.ingest(entry(min: 10, input: 300_000, key: "k2"))
        a.recompute()
        // 区块速率 = 301000 / 10min ≈ 30.1k
        XCTAssertEqual(a.tokensPerMinute, 30_100, accuracy: 1)
        // 瞬时速率 = 300000 / 30 * 60 = 600k（旧记录早已衰减殆尽）
        XCTAssertEqual(a.instantTokensPerMinute, 600_000, accuracy: 1_000)
        XCTAssertGreaterThan(a.instantTokensPerMinute, a.tokensPerMinute * 10)
    }

    /// 熄火：停手之后瞬时速率自然衰减回零，而区块速率照旧冻结。
    /// 这就是删掉 90 秒归零补丁后仍有"熄火"反馈的原因。
    func testInstantRateDecaysToZeroWhileBlockRateHolds() {
        let (a, setNow) = movableAggregator()
        a.ingest(entry(min: 0, input: 100_000, key: "k1"))
        a.ingest(entry(min: 10, input: 100_000, key: "k2"))
        setNow(10)
        a.recompute()
        XCTAssertGreaterThan(a.instantTokensPerMinute, 0)

        setNow(40)                 // 静置 30 分钟 = 60 个时间常数
        a.recompute()
        XCTAssertEqual(a.instantTokensPerMinute, 0, accuracy: 1e-9)
        XCTAssertEqual(a.tokensPerMinute, 20_000, accuracy: 0.001, "区块速率必须冻结不动")
        XCTAssertTrue(a.hasBurnRate)
    }

    /// 去重后的记录不得重复计入瞬时速率——否则 Claude 一次响应写的多行
    /// 会把读数抬高一倍有余。
    func testInstantRateSkipsDedupedEntries() {
        let a = aggregator(nowOffsetMin: 0)
        a.ingest(entry(min: 0, input: 15_000, key: "k1"))
        a.recompute()
        let once = a.instantTokensPerMinute
        XCTAssertEqual(once, 30_000, accuracy: 1e-9)       // 15000 / 30 * 60

        a.ingest(entry(min: 0, input: 15_000, key: "k1"))   // 同键同量 -> 丢弃
        a.recompute()
        XCTAssertEqual(a.instantTokensPerMinute, once, accuracy: 1e-9)
    }

    /// 瞬时速率用 entry 自身的 timestamp：回扫 6 小时的历史不该在一瞬间
    /// 全部砸进 EMA 把指针顶死。
    func testInstantRateUsesEntryTimestampNotArrivalTime() {
        let a = aggregator(nowOffsetMin: 0)
        // 两条都是"此刻"注入的，但时间戳相隔 5 小时
        a.ingest(entry(min: -300, input: 1_000_000, key: "old"))
        a.ingest(entry(min: 0, input: 15_000, key: "new"))
        a.recompute()
        // 老记录早已衰减殆尽，只剩新记录的 30k
        XCTAssertEqual(a.instantTokensPerMinute, 30_000, accuracy: 1e-6)
    }

    /// 时间常数改档立即生效，且保留当前读数（不清零）。
    func testSetInstantRateTauTakesEffectImmediately() {
        let (a, setNow) = movableAggregator()
        a.ingest(entry(min: 0, input: 15_000, key: "k1"))
        setNow(0)
        a.recompute()
        let before = a.instantTokensPerMinute
        XCTAssertEqual(before, 30_000, accuracy: 1e-9)

        a.setInstantRateTau(120)
        XCTAssertEqual(a.instantTokensPerMinute, before, accuracy: 1e-9, "改档不该把指针清零")

        setNow(2)                  // 120 秒 = 新的一个时间常数
        a.recompute()
        XCTAssertEqual(a.instantTokensPerMinute, before / M_E, accuracy: before * 1e-6)
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

    /// 峰值跟的是**瞬时**速率——那才是表盘显示的量，自适应量程的上限
    /// 必须与指针同源。
    func testRecentPeakTracksInstantRateMaximum() {
        let a = aggregator(nowOffsetMin: 11)
        a.ingest(entry(min: 0, input: 1000, key: "k1"))
        a.ingest(entry(min: 10, input: 1000, key: "k2"))
        a.recompute()
        let peak = a.recentPeak
        XCTAssertGreaterThan(peak, 0)
        XCTAssertGreaterThanOrEqual(peak, a.instantTokensPerMinute)
        // 只重算过一次，故峰值就是此刻的瞬时速率——而不是区块速率
        XCTAssertEqual(peak, a.instantTokensPerMinute, accuracy: 1e-9)
        XCTAssertNotEqual(peak, a.tokensPerMinute, accuracy: 1)
    }

    /// 时钟可推进的聚合器，用于观察 `recentPeak` 随时间的回落
    private func movableAggregator() -> (TokenAggregator, (Double) -> Void) {
        let clock = MutableClock(base)
        let a = TokenAggregator(pricing: NoPricing(), retentionHours: 6,
                                instantRateTauSeconds: 30,
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
        XCTAssertEqual(a.recentPeak, a.instantTokensPerMinute, accuracy: 1e-6)
    }
}
