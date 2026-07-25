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

    // MARK: - 线程安全

    /// TSan 回归哨兵：复刻生产时序——`AppCoordinator.start()` 里
    /// `Task { await pricingStore.refresh() }` 在后台执行器上突变定价表，
    /// 而 `@MainActor` 的 `TokenAggregator.recompute()` 每 2 秒读同一张表。
    ///
    /// 修复前 `rebuild()` 直接在后台线程给 `table` 赋值（两个 Dictionary 字段的
    /// 结构体），主线程同时读 → TSan 报 data race。
    /// 修复后突变被搬回主线程，本测试在 TSan 下必须干净通过。
    ///
    /// 注意：本测试**不能**加 `@MainActor` 之外的隔离——它靠主线程上的同步
    /// 循环与后台 refresh 真正重叠来制造竞争。
    @MainActor
    func testConcurrentRefreshAndLookupDoNotRace() async {
        // 表大一些，让 rebuild 的窗口足够宽，竞争更容易被撞上
        var snapshot: [String: Any] = [:]
        for i in 0..<200 { snapshot["model-\(i)"] = entry(Double(i + 1) * 1e-7) }
        var fetched: [String: Any] = [:]
        for i in 0..<200 { fetched["model-\(i)"] = entry(Double(i + 1) * 2e-7) }

        let store = PricingStore(builtinSnapshot: snapshot,
                                 cache: FakeCache(),
                                 fetcher: FakeFetcher(result: .success(fetched)))

        // 只保护"写者是否已收工"这一个 bool。写者仅在末尾碰它一次，
        // 因此循环期间两侧对 `table` 的访问之间不存在 happens-before 边。
        let flagLock = NSLock()
        var writerDone = false
        func isWriterDone() -> Bool { flagLock.lock(); defer { flagLock.unlock() }; return writerDone }

        let writer = Task.detached {
            for _ in 0..<300 { await store.refresh() }
            flagLock.lock(); writerDone = true; flagLock.unlock()
        }

        // 主线程侧的读者：同步自旋，覆盖写者的整个生命周期
        var seen = 0
        var spins = 0
        while !isWriterDone() && spins < 5_000_000 {
            spins += 1
            if store.pricing(for: "model-7") != nil { seen += 1 }
        }
        await writer.value

        XCTAssertGreaterThan(seen, 0)
        XCTAssertNotNil(store.pricing(for: "model-7"))
    }
}
