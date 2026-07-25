import XCTest
@testable import VibeCompanion

/// 用固化的真实数据快照校验整条链路：解析 -> 去重 -> 分块 -> burn rate。
///
/// fixture 是**静态**的，不得改为实时读取 ~/.claude——活跃块会持续累积，
/// 那样测试会随本机数据漂移。
final class GoldenFixtureTests: XCTestCase {

    /// 每个块的期望值，来自独立参考脚本对**仓库内固化文件**的计算：
    /// `Tests/Fixtures/claude-golden.jsonl` + `Sources/Resources/litellm-pricing-snapshot.json`。
    /// 绝不读 `~/.claude` 实时数据——那样测试明天就红。
    ///
    /// 格式：(块起点 ISO8601, entry 数, tokensPerMinute, indicator, costUSD)
    /// tokensPerMinute 为 nil 表示 duration <= 0（无 burn rate）。
    ///
    /// costUSD 混合了逐请求 200K 分档、逐条 fast 倍率、以及块内多个模型
    /// （claude-sonnet-5 / claude-opus-5 / claude-opus-4-8 / claude-haiku-4-5-20251001），
    /// 是"与 ccusage 数值一致"这条原则下最需要参考值的那个量。
    private let expectedBlocks: [(start: String, count: Int,
                                  tpm: Double?, indicator: Double?, costUSD: Double)] = [
        ("2026-07-12T05:00:00Z", 89, 41080.1322, 762.1385, 13.1569530000),
        ("2026-07-21T11:00:00Z", 2, 743112.7080, 99610.4387, 0.1559316000),
        ("2026-07-25T02:00:00Z", 716, 299509.2354, 1939.9933, 55.3356652000),
        // 末块的 1084 条里有 1 条 model 为 `<synthetic>`，查不到定价，
        // 按 blockCostUSD 的约定不计入 cost 但照常计入 token
        ("2026-07-25T07:00:00Z", 1084, 388666.4804, 3913.1340, 73.3092982500),
    ]

    /// 与生产同构的定价源：内置快照 + builtin 覆盖表，去掉磁盘缓存与联网。
    /// 两个输入都是仓库内固化文件，故结果确定。
    private struct NoCache: PricingCache {
        func read() -> (json: [String: Any], age: TimeInterval)? { nil }
        func write(_ json: [String: Any]) {}
    }
    private struct NoFetch: PricingFetcher {
        func fetch() async throws -> [String: Any] { [:] }
    }
    private func pricingSource() -> PricingSource {
        PricingStore(builtinSnapshot: loadBuiltinPricingSnapshot(),
                     cache: NoCache(), fetcher: NoFetch())
    }

    private func loadEntries() throws -> [UsageEntry] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-golden",
                                                  withExtension: "jsonl"),
                                "fixture 未打包，检查 Package.swift 的 testTarget resources")
        let text = try String(contentsOf: url, encoding: .utf8)
        let adapter = ClaudeAdapter(roots: [])
        var ctx = ParseContext()
        return text.split(separator: "\n").compactMap {
            adapter.parse(line: String($0), context: &ctx)
        }
    }

    private func dedupedEntries() throws -> [UsageEntry] {
        let window = UsageWindow(retentionHours: 24 * 365 * 10)   // 不驱逐
        for e in try loadEntries() { window.insert(e) }
        return window.snapshot()
    }

    func testFixtureParses() throws {
        XCTAssertFalse(try loadEntries().isEmpty, "fixture 一条也没解析出来")
    }

    func testDeduplicationReducesEntryCount() throws {
        let raw = try loadEntries().count
        let deduped = try dedupedEntries().count
        XCTAssertLessThan(deduped, raw, "去重后条目数应显著减少（实测约掉 56%）")
    }

    func testBlockCountMatchesReference() throws {
        // now 取远未来，使所有块都非活跃——分块结果与 now 无关
        let blocks = identifySessionBlocks(try dedupedEntries(),
                                           now: Date(timeIntervalSince1970: 4_000_000_000))
            .filter { !$0.isGap }
        XCTAssertEqual(blocks.count, expectedBlocks.count)
    }

    func testEachBlockMatchesReferenceValues() throws {
        let blocks = identifySessionBlocks(try dedupedEntries(),
                                           now: Date(timeIntervalSince1970: 4_000_000_000))
            .filter { !$0.isGap }
        XCTAssertEqual(blocks.count, expectedBlocks.count, "块数不符，后续断言无意义")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)

        for (block, expected) in zip(blocks, expectedBlocks) {
            XCTAssertEqual(iso.string(from: block.startTime), expected.start)
            XCTAssertEqual(block.entries.count, expected.count, "块 \(expected.start) 条目数不符")

            let rate = calculateBurnRate(block)
            if let expectedTpm = expected.tpm {
                let r = try XCTUnwrap(rate, "块 \(expected.start) 应有 burn rate")
                XCTAssertEqual(r.tokensPerMinute, expectedTpm, accuracy: expectedTpm * 1e-6)
                XCTAssertEqual(r.tokensPerMinuteForIndicator, expected.indicator!,
                               accuracy: expected.indicator! * 1e-6)
            } else {
                XCTAssertNil(rate, "块 \(expected.start) 的 duration <= 0，应无 burn rate")
            }
        }
    }

    /// 成本 golden：钉住每个块的 costUSD。
    ///
    /// 这条断言同时守着定价链路的三层：内置快照的解码、builtin 覆盖表
    /// （`claude-opus-4-8` 的 fast 倍率 2.0 只在这里生效）、以及模糊查表
    /// （`claude-sonnet-5` / `claude-opus-5` 都不是快照里的精确 key）。
    func testEachBlockMatchesReferenceCost() throws {
        let blocks = identifySessionBlocks(try dedupedEntries(),
                                           now: Date(timeIntervalSince1970: 4_000_000_000))
            .filter { !$0.isGap }
        XCTAssertEqual(blocks.count, expectedBlocks.count, "块数不符，后续断言无意义")

        let source = pricingSource()
        for (block, expected) in zip(blocks, expectedBlocks) {
            let cost = try XCTUnwrap(blockCostUSD(block, source: source),
                                     "块 \(expected.start) 应能算出 cost")
            XCTAssertEqual(cost, expected.costUSD, accuracy: expected.costUSD * 1e-9,
                           "块 \(expected.start) 的 costUSD 不符")
        }
    }

    /// 前置条件：内置定价快照必须真的被打包进来，否则上面那条会因"全都查不到定价"
    /// 而以一种误导的方式失败。
    func testBuiltinPricingSnapshotIsAvailableToTests() {
        XCTAssertFalse(loadBuiltinPricingSnapshot().isEmpty,
                       "内置定价快照没打包，成本 golden 无从谈起")
        XCTAssertNotNil(pricingSource().pricing(for: "claude-opus-5"))
    }
}
