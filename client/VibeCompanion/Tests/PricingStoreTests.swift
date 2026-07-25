import XCTest
@testable import VibeCompanion

final class PricingStoreTests: XCTestCase {

    private let eps = 1e-15

    private final class FakeCache: PricingCache {
        var stored: [String: Any]?
        var age: TimeInterval = 0
        var writeCount = 0
        func read() -> (json: [String: Any], age: TimeInterval)? {
            stored.map { ($0, age) }
        }
        func write(_ json: [String: Any]) { stored = json; writeCount += 1 }
    }

    private struct FakeFetcher: PricingFetcher {
        let result: Result<[String: Any], Error>
        func fetch() async throws -> [String: Any] { try result.get() }
    }

    private struct BoomError: Error {}

    private func entry(_ input: Double) -> [String: Any] {
        ["input_cost_per_token": input, "output_cost_per_token": input * 5]
    }

    func testFallsBackToBuiltinSnapshotWhenNothingElseAvailable() {
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
    }

    /// builtin 硬编码表覆盖内置快照
    func testBuiltinOverridesBeatSnapshot() {
        let store = PricingStore(builtinSnapshot: ["claude-opus-4-8": entry(999e-6)],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        // builtin 表里 claude-opus-4-8 的 input 是 5e-6
        XCTAssertEqual(store.pricing(for: "claude-opus-4-8")!.input, 5e-6, accuracy: eps)
    }

    func testBuiltinOverridesIncludeOpus48() {
        let overrides = builtinPricingOverrides()
        XCTAssertNotNil(overrides["claude-opus-4-8"])
        XCTAssertEqual(overrides["claude-opus-4-8"]!.fastMultiplier, 2.0, accuracy: eps)
    }

    /// 未过期的磁盘缓存覆盖 builtin
    func testFreshCacheOverridesBuiltin() {
        let cache = FakeCache()
        cache.stored = ["model-a": entry(7e-6)]
        cache.age = 3600                     // 1h < TTL 24h
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 7e-6, accuracy: eps)
    }

    /// 过期缓存被忽略
    func testStaleCacheIsIgnored() {
        let cache = FakeCache()
        cache.stored = ["model-a": entry(7e-6)]
        cache.age = 48 * 3600                // 48h > TTL 24h
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
    }

    func testRefreshAppliesFetchedPricingAndWritesCache() async {
        let cache = FakeCache()
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .success(["model-a": entry(9e-6)])))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 9e-6, accuracy: eps)
        XCTAssertEqual(cache.writeCount, 1)
    }

    /// 抓取失败不得破坏已有定价
    func testFailedRefreshKeepsPreviousPricing() async {
        let cache = FakeCache()
        let store = PricingStore(builtinSnapshot: ["model-a": entry(1e-6)],
                                 cache: cache,
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "model-a")!.input, 1e-6, accuracy: eps)
        XCTAssertEqual(cache.writeCount, 0)
    }

    /// 线上抓取覆盖 builtin 硬编码表
    func testFetchedPricingOverridesBuiltin() async {
        let store = PricingStore(builtinSnapshot: [:],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .success(["claude-opus-4-8": entry(3e-6)])))
        await store.refresh()
        XCTAssertEqual(store.pricing(for: "claude-opus-4-8")!.input, 3e-6, accuracy: eps)
    }

    func testUnknownModelReturnsNil() {
        let store = PricingStore(builtinSnapshot: [:],
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .failure(BoomError())))
        XCTAssertNil(store.pricing(for: "nope"))
    }
}
