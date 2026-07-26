import XCTest
@testable import VibeCompanion

/// 暂停语义：照常摄入、只冻结显示。
///
/// 旧实现在采集回调里丢弃暂停期间的 entry，而 `JsonlTailer` 的 offset 照常前进，
/// 那些行再也读不回来——活跃的 5 小时区块会永久缺条目，`calculateBurnRate`
/// 用「区块总量 ÷（末条 − 首条）」算出的是偏低的**错值**，与 ccusage 不再一致。
@MainActor
final class UsageDisplayTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_785_000_000)

    private func entry(min: Double, input: Int, key: String) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(min * 60),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: input, output: 0, cacheRead: 0),
                   isSidechain: false, hasSpeed: false, isFastSpeed: false, dedupKey: key)
    }

    private func make(nowOffsetMin: Double,
                      paused: Bool = false) -> (TokenAggregator, UsageDisplay) {
        let a = TokenAggregator(pricing: nil, retentionHours: 6, idleTimeoutSeconds: 90,
                                now: { self.base.addingTimeInterval(nowOffsetMin * 60) })
        return (a, UsageDisplay(aggregator: a, paused: paused))
    }

    // MARK: 摄入不中断

    /// 暂停期间到达的 entry 必须照常进入窗口，否则区块残缺、速率算错。
    func testIngestContinuesWhilePaused() {
        let (a, d) = make(nowOffsetMin: 11)
        d.setPaused(true)
        d.ingest(entry(min: 0, input: 500, key: "k1"))
        d.ingest(entry(min: 10, input: 500, key: "k2"))
        a.recompute()

        XCTAssertTrue(a.hasBurnRate, "暂停期间的 entry 被丢弃，区块只剩不足两条")
        XCTAssertEqual(a.tokensPerMinute, 100, accuracy: 1e-6)
    }

    /// 恢复后立刻显示真实值：分子必须包含暂停期间到达的每一条。
    func testResumedRateIncludesEntriesIngestedWhilePaused() {
        let (a, d) = make(nowOffsetMin: 11)
        d.ingest(entry(min: 0, input: 500, key: "k1"))     // 暂停前
        d.setPaused(true)
        d.ingest(entry(min: 5, input: 500, key: "k2"))     // 暂停期间
        d.ingest(entry(min: 10, input: 500, key: "k3"))    // 暂停期间
        d.setPaused(false)
        a.recompute()

        // 1500 tokens ÷ 10 min = 150；丢弃 k2/k3 则退化成单条、无速率
        XCTAssertEqual(d.snapshot.tokensPerMinute, 150, accuracy: 1e-6)
        XCTAssertTrue(d.snapshot.hasBurnRate)
    }

    // MARK: 冻结显示

    /// 暂停只冻结读数：聚合器继续变，界面停在暂停那一刻。
    func testSnapshotFrozenWhilePausedThenTracksLiveAgain() {
        let (a, d) = make(nowOffsetMin: 11)
        d.ingest(entry(min: 0, input: 500, key: "k1"))
        d.ingest(entry(min: 10, input: 500, key: "k2"))
        a.recompute()
        let atPause = d.snapshot

        d.setPaused(true)
        d.ingest(entry(min: 11, input: 1_000_000, key: "k3"))
        a.recompute()

        XCTAssertEqual(d.snapshot, atPause, "暂停期间显示必须冻结")
        XCTAssertNotEqual(UsageSnapshot(a), atPause, "而聚合器本身必须继续走")

        d.setPaused(false)
        XCTAssertEqual(d.snapshot, UsageSnapshot(a), "恢复后立即显示当前真实值")
    }

    /// 启动时若持久化状态为暂停，显示同样从冻结开始。
    func testPausedAtLaunchFreezesImmediately() {
        let (a, d) = make(nowOffsetMin: 11, paused: true)
        let atLaunch = d.snapshot
        d.ingest(entry(min: 0, input: 500, key: "k1"))
        d.ingest(entry(min: 10, input: 500, key: "k2"))
        a.recompute()

        XCTAssertEqual(d.snapshot, atLaunch)
        XCTAssertTrue(a.hasBurnRate, "冻结的是显示，不是统计")
    }
}
