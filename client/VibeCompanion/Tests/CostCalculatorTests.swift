import XCTest
@testable import VibeCompanion

final class CostCalculatorTests: XCTestCase {

    private let eps = 1e-12

    private func pricing(input: Double = 5e-6,
                         output: Double = 25e-6,
                         cacheCreate: Double = 6.25e-6,
                         cacheRead: Double = 0.5e-6,
                         cacheReadExplicit: Bool = true,
                         inputAbove: Double? = nil,
                         outputAbove: Double? = nil,
                         cacheCreateAbove: Double? = nil,
                         cacheReadAbove: Double? = nil,
                         longContextThreshold: Int? = nil,
                         fastMultiplier: Double = 1.0) -> ModelPricing {
        ModelPricing(input: input, output: output, cacheCreate: cacheCreate,
                     cacheRead: cacheRead, cacheReadExplicit: cacheReadExplicit,
                     inputAbove200k: inputAbove, outputAbove200k: outputAbove,
                     cacheCreateAbove200k: cacheCreateAbove, cacheReadAbove200k: cacheReadAbove,
                     longContextThreshold: longContextThreshold, fastMultiplier: fastMultiplier)
    }

    // MARK: tieredCost

    func testTieredCostZeroTokensIsZero() {
        XCTAssertEqual(tieredCost(0, base: 5e-6, above: 10e-6, threshold: 200_000), 0, accuracy: eps)
    }

    func testTieredCostBelowThresholdUsesBaseRate() {
        XCTAssertEqual(tieredCost(1000, base: 5e-6, above: 10e-6, threshold: 200_000),
                       1000 * 5e-6, accuracy: eps)
    }

    func testTieredCostExactlyAtThresholdUsesBaseRate() {
        XCTAssertEqual(tieredCost(200_000, base: 5e-6, above: 10e-6, threshold: 200_000),
                       200_000 * 5e-6, accuracy: eps)
    }

    /// 超出部分按 above 单价，是**边际**分段而非整体换档
    func testTieredCostAboveThresholdIsMarginal() {
        let got = tieredCost(300_000, base: 5e-6, above: 10e-6, threshold: 200_000)
        XCTAssertEqual(got, 200_000 * 5e-6 + 100_000 * 10e-6, accuracy: eps)
    }

    /// above 为 nil 时不分段，全部按 base
    func testTieredCostWithoutAboveRateDoesNotSplit() {
        XCTAssertEqual(tieredCost(300_000, base: 5e-6, above: nil, threshold: 200_000),
                       300_000 * 5e-6, accuracy: eps)
    }

    // MARK: calculateCost —— 五个桶

    func testEachBucketBilledAtItsOwnRate() {
        let c = TokenCounts(input: 1000, output: 2000, cacheCreation5m: 3000,
                            cacheCreation1h: 4000, cacheRead: 5000)
        let p = pricing()
        let expected = 1000 * 5e-6            // input
                     + 2000 * 25e-6           // output
                     + 3000 * 6.25e-6         // cacheCreate 5m
                     + 4000 * (5e-6 * 2.0)    // cacheCreate 1h = input × 2.0
                     + 5000 * 0.5e-6          // cacheRead
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    /// 1h 单价是 input×2.0，**不是** cacheCreate×2.0
    func testOneHourCacheRateDerivesFromInputNotCacheCreate() {
        let c = TokenCounts(cacheCreation1h: 1000)
        let p = pricing(input: 5e-6, cacheCreate: 999e-6)   // cacheCreate 故意设得很离谱
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false),
                       1000 * 10e-6, accuracy: eps)
    }

    func testExtraTotalIsNotBilled() {
        let c = TokenCounts(input: 1000, extraTotal: 999_999)
        XCTAssertEqual(calculateCost(counts: c, pricing: pricing(), isFast: false),
                       1000 * 5e-6, accuracy: eps)
    }

    // MARK: 分段（Anthropic 路径：按桶边际）

    func testPerBucketMarginalTiering() {
        let c = TokenCounts(cacheRead: 460_590)
        let p = pricing(cacheRead: 0.5e-6, cacheReadAbove: 1e-6)
        let expected = 200_000 * 0.5e-6 + 260_590 * 1e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    func testOneHourAboveRateIsInputAboveTimesTwo() {
        let c = TokenCounts(cacheCreation1h: 300_000)
        let p = pricing(input: 5e-6, inputAbove: 10e-6)
        let expected = 200_000 * (5e-6 * 2.0) + 100_000 * (10e-6 * 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    // MARK: OpenAI 路径（整请求选档，由 input 决定）

    func testOpenAIPathSelectsTierByInputTokensForAllBuckets() {
        let c = TokenCounts(input: 300_000, output: 1000, cacheRead: 1000)
        let p = pricing(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6,
                        inputAbove: 10e-6, outputAbove: 50e-6, cacheReadAbove: 1e-6,
                        longContextThreshold: 272_000)
        // input 超阈值 -> 所有桶整体按 above 单价
        let expected = 300_000 * 10e-6 + 1000 * 50e-6 + 1000 * 1e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    func testOpenAIPathBelowThresholdUsesBaseRatesEverywhere() {
        let c = TokenCounts(input: 1000, output: 1000, cacheRead: 300_000)
        let p = pricing(input: 5e-6, output: 25e-6, cacheRead: 0.5e-6,
                        inputAbove: 10e-6, outputAbove: 50e-6, cacheReadAbove: 1e-6,
                        longContextThreshold: 272_000)
        // input 未超阈值 -> 即使 cacheRead 很大也全用 base
        let expected = 1000 * 5e-6 + 1000 * 25e-6 + 300_000 * 0.5e-6
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false), expected, accuracy: eps)
    }

    // MARK: fast 倍率

    func testFastMultiplierScalesWholeCost() {
        let c = TokenCounts(input: 1000)
        let p = pricing(fastMultiplier: 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: true),
                       1000 * 5e-6 * 2.0, accuracy: eps)
    }

    func testStandardSpeedIgnoresMultiplier() {
        let c = TokenCounts(input: 1000)
        let p = pricing(fastMultiplier: 2.0)
        XCTAssertEqual(calculateCost(counts: c, pricing: p, isFast: false),
                       1000 * 5e-6, accuracy: eps)
    }

    // MARK: 经由 PricingSource 的重载

    func testSourceOverloadResolvesModel() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        let c = TokenCounts(input: 1000)
        let got = calculateCost(counts: c, model: "claude-opus-5", isFast: false, source: table)
        XCTAssertEqual(got!, 1000 * 5e-6, accuracy: eps)
    }

    func testSourceOverloadReturnsNilOnMiss() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        let c = TokenCounts(input: 1000)
        XCTAssertNil(calculateCost(counts: c, model: "<synthetic>", isFast: false, source: table))
    }

    func testSourceOverloadReturnsNilForNilModel() {
        let table = PricingTable(entries: ["claude-opus-5": pricing()])
        XCTAssertNil(calculateCost(counts: TokenCounts(input: 1),
                                   model: nil, isFast: false, source: table))
    }
}
