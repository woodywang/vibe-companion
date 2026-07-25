import XCTest
@testable import VibeCompanion

/// 用固化的真实数据快照校验整条链路：解析 -> 去重 -> 分块 -> burn rate。
///
/// fixture 是**静态**的，不得改为实时读取 ~/.claude——活跃块会持续累积，
/// 那样测试会随本机数据漂移。
final class GoldenFixtureTests: XCTestCase {

    /// 每个块的期望值，来自计划 Task 7 Step 2 的参考脚本输出。
    /// 格式：(块起点 ISO8601, entry 数, tokensPerMinute, indicator)
    /// tokensPerMinute 为 nil 表示 duration <= 0（无 burn rate）。
    private let expectedBlocks: [(start: String, count: Int, tpm: Double?, indicator: Double?)] = [
        ("2026-07-12T05:00:00Z", 89, 41080.1322, 762.1385),
        ("2026-07-21T11:00:00Z", 2, 743112.7080, 99610.4387),
        ("2026-07-25T02:00:00Z", 716, 299509.2354, 1939.9933),
        ("2026-07-25T07:00:00Z", 1084, 388666.4804, 3913.1340),
    ]

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
}
