import XCTest
@testable import VibeCompanion

final class PricingResolverTests: XCTestCase {

    private func p(_ input: Double) -> ModelPricing {
        ModelPricing(input: input, output: input * 5, cacheCreate: input * 1.25,
                     cacheRead: input * 0.1, cacheReadExplicit: false,
                     inputAbove200k: nil, outputAbove200k: nil,
                     cacheCreateAbove200k: nil, cacheReadAbove200k: nil,
                     longContextThreshold: nil, fastMultiplier: 1.0)
    }

    // MARK: 归一化

    func testNormalizeReplacesDotsAndAts() {
        XCTAssertEqual(normalizedPricingKey("claude-3.5-sonnet"), "claude-3-5-sonnet")
        XCTAssertEqual(normalizedPricingKey("claude-opus-4-8@default"), "claude-opus-4-8-default")
    }

    // MARK: 边界规则

    func testContainsRequiresNonAlphanumericBoundaryBefore() {
        // "opus" 出现在 "xopus-5" 中，但前一字符是字母 -> 不算匹配
        XCTAssertFalse(containsPricingKey("xopus-5", "opus"))
        XCTAssertTrue(containsPricingKey("x-opus-5", "opus"))
    }

    func testContainsAllowsMatchAtStart() {
        XCTAssertTrue(containsPricingKey("claude-opus-5", "claude"))
    }

    func testContainsAllowsExactEquality() {
        XCTAssertTrue(containsPricingKey("claude-opus-5", "claude-opus-5"))
    }

    func testContainsRejectsAlphanumericSuffix() {
        XCTAssertFalse(containsPricingKey("claude-opusX", "claude-opus"))
    }

    /// 8 位日期后缀允许剥离
    func testEightDigitDateSuffixIsAllowed() {
        XCTAssertTrue(containsPricingKey("claude-haiku-4-5-20251001", "claude-haiku-4-5"))
    }

    /// 非 8 位的数字后缀视为不同版本，拒绝
    func testNonEightDigitVersionSuffixIsRejected() {
        XCTAssertFalse(containsPricingKey("claude-opus-4-5", "claude-opus-4"))
        XCTAssertFalse(containsPricingKey("claude-opus-4-812", "claude-opus-4"))
    }

    // MARK: PricingTable.pricing(for:)

    func testExactLookupWins() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6), "claude": p(1e-6)])
        XCTAssertEqual(t.pricing(for: "claude-opus-5")!.input, 5e-6, accuracy: 1e-15)
    }

    func testProviderPrefixedModelMatchesBareKey() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertEqual(t.pricing(for: "anthropic/claude-opus-5")!.input, 5e-6, accuracy: 1e-15)
    }

    func testDatedModelMatchesUndatedKey() {
        let t = PricingTable(entries: ["claude-haiku-4-5": p(1e-6)])
        XCTAssertEqual(t.pricing(for: "claude-haiku-4-5-20251001")!.input, 1e-6, accuracy: 1e-15)
    }

    func testLongestMatchingKeyWins() {
        let t = PricingTable(entries: ["claude": p(1e-6),
                                       "claude-opus": p(2e-6),
                                       "claude-opus-5": p(3e-6)])
        XCTAssertEqual(t.pricing(for: "anthropic/claude-opus-5")!.input, 3e-6, accuracy: 1e-15)
    }

    func testDotNormalizationEnablesMatch() {
        let t = PricingTable(entries: ["claude-3-5-sonnet": p(3e-6)])
        XCTAssertEqual(t.pricing(for: "claude-3.5-sonnet")!.input, 3e-6, accuracy: 1e-15)
    }

    func testAliasTableIsConsulted() {
        let t = PricingTable(entries: ["gpt-5.3-codex-spark": p(7e-6)],
                             aliases: ["gpt-5.3-spark": "gpt-5.3-codex-spark"])
        XCTAssertEqual(t.pricing(for: "gpt-5.3-spark")!.input, 7e-6, accuracy: 1e-15)
    }

    func testMissReturnsNil() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertNil(t.pricing(for: "totally-unknown-model"))
    }

    /// `<synthetic>` 永远命中不了
    func testSyntheticModelNeverMatches() {
        let t = PricingTable(entries: ["claude-opus-5": p(5e-6)])
        XCTAssertNil(t.pricing(for: "<synthetic>"))
    }

    func testOpusFourDoesNotMatchOpusFourFive() {
        let t = PricingTable(entries: ["claude-opus-4": p(1e-6)])
        XCTAssertNil(t.pricing(for: "claude-opus-4-5"))
    }
}
