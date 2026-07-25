import XCTest
@testable import VibeCompanion

final class ModelPricingTests: XCTestCase {

    private let eps = 1e-15

    func testDecodesAllExplicitFields() {
        let json: [String: Any] = [
            "input_cost_per_token": 5e-6,
            "output_cost_per_token": 25e-6,
            "cache_creation_input_token_cost": 6.25e-6,
            "cache_read_input_token_cost": 0.5e-6,
            "input_cost_per_token_above_200k_tokens": 10e-6,
            "output_cost_per_token_above_200k_tokens": 50e-6,
            "cache_creation_input_token_cost_above_200k_tokens": 12.5e-6,
            "cache_read_input_token_cost_above_200k_tokens": 1e-6,
        ]
        let p = ModelPricing(liteLLM: json)!
        XCTAssertEqual(p.input, 5e-6, accuracy: eps)
        XCTAssertEqual(p.output, 25e-6, accuracy: eps)
        XCTAssertEqual(p.cacheCreate, 6.25e-6, accuracy: eps)
        XCTAssertEqual(p.cacheRead, 0.5e-6, accuracy: eps)
        XCTAssertTrue(p.cacheReadExplicit)
        XCTAssertEqual(p.inputAbove200k!, 10e-6, accuracy: eps)
        XCTAssertEqual(p.outputAbove200k!, 50e-6, accuracy: eps)
        XCTAssertEqual(p.cacheCreateAbove200k!, 12.5e-6, accuracy: eps)
        XCTAssertEqual(p.cacheReadAbove200k!, 1e-6, accuracy: eps)
    }

    /// 缺 input 或 output -> 整条跳过
    func testReturnsNilWhenInputMissing() {
        XCTAssertNil(ModelPricing(liteLLM: ["output_cost_per_token": 25e-6]))
    }

    func testReturnsNilWhenOutputMissing() {
        XCTAssertNil(ModelPricing(liteLLM: ["input_cost_per_token": 5e-6]))
    }

    /// cacheCreate 缺省 = input × 1.25
    func testCacheCreateDefaultsToInputTimes125() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.cacheCreate, 5e-6, accuracy: eps)
    }

    /// cacheRead 缺省 = input × 0.1，且 explicit 标志为 false
    func testCacheReadDefaultsToInputTimes01AndMarksImplicit() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.cacheRead, 0.4e-6, accuracy: eps)
        XCTAssertFalse(p.cacheReadExplicit)
    }

    func testAbove200kFieldsAreNilWhenAbsent() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertNil(p.inputAbove200k)
        XCTAssertNil(p.outputAbove200k)
        XCTAssertNil(p.cacheCreateAbove200k)
        XCTAssertNil(p.cacheReadAbove200k)
    }

    func testFastMultiplierDefaultsToOne() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6])!
        XCTAssertEqual(p.fastMultiplier, 1.0, accuracy: eps)
    }

    func testFastMultiplierReadFromProviderSpecificEntry() {
        let p = ModelPricing(liteLLM: ["input_cost_per_token": 4e-6,
                                       "output_cost_per_token": 20e-6,
                                       "provider_specific_entry": ["fast": 2.5]])!
        XCTAssertEqual(p.fastMultiplier, 2.5, accuracy: eps)
    }

    // MARK: 整表解码

    func testDecodeTableSkipsInvalidEntriesAndKeepsValid() {
        let table: [String: Any] = [
            "claude-opus-5": ["input_cost_per_token": 5e-6, "output_cost_per_token": 25e-6],
            "broken-model": ["input_cost_per_token": 5e-6],           // 缺 output
            "sample_spec": ["note": "LiteLLM 表里的非模型条目"],
        ]
        let decoded = decodeLiteLLMPricing(table)
        XCTAssertEqual(Set(decoded.keys), ["claude-opus-5"])
        XCTAssertEqual(decoded["claude-opus-5"]!.input, 5e-6, accuracy: eps)
    }

    func testDecodeTableHandlesEmptyInput() {
        XCTAssertTrue(decodeLiteLLMPricing([:]).isEmpty)
    }
}
