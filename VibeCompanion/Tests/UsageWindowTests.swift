import XCTest
@testable import VibeCompanion

final class UsageWindowTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_784_937_600)

    private func entry(min: Double, total: Int = 10, key: String?,
                       isSidechain: Bool = false, hasSpeed: Bool = false) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(min * 60),
                   agent: "claude", sessionId: nil, model: nil,
                   counts: TokenCounts(input: total),
                   isSidechain: isSidechain, hasSpeed: hasSpeed,
                   isFastSpeed: false, dedupKey: key)
    }

    func testInsertKeepsSortedOrderDespiteUnorderedArrival() {
        let w = UsageWindow()
        w.insert(entry(min: 30, key: "c"))
        w.insert(entry(min: 10, key: "a"))
        w.insert(entry(min: 20, key: "b"))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["a", "b", "c"])
    }

    func testDuplicateKeyWithLowerTotalIsRejected() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 100, key: "k"))
        XCTAssertFalse(w.insert(entry(min: 1, total: 50, key: "k")).accepted)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.snapshot()[0].counts.total, 100)
    }

    /// 替换时旧条目必须从有序数组移除，不能残留
    func testReplacementRemovesOldEntryFromArray() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 100, key: "k"))
        XCTAssertTrue(w.insert(entry(min: 5, total: 200, key: "k")).accepted)
        XCTAssertEqual(w.count, 1)
        let only = w.snapshot()[0]
        XCTAssertEqual(only.counts.total, 200)
        XCTAssertEqual(only.timestamp, base.addingTimeInterval(5 * 60))
    }

    func testReplacementKeepsArraySorted() {
        let w = UsageWindow()
        w.insert(entry(min: 10, total: 100, key: "a"))
        w.insert(entry(min: 20, total: 100, key: "b"))
        // b 的替代条目时间戳提前到 5min，应重新排到最前
        w.insert(entry(min: 5, total: 999, key: "b"))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["b", "a"])
    }

    func testSidechainPriorityAppliesOnInsert() {
        let w = UsageWindow()
        w.insert(entry(min: 0, total: 500, key: "k", isSidechain: true))
        // 非 sidechain 即使 token 更少也应取代
        XCTAssertTrue(w.insert(entry(min: 0, total: 1, key: "k", isSidechain: false)).accepted)
        XCTAssertEqual(w.snapshot()[0].counts.total, 1)
    }

    /// dedupKey == nil 的条目永不去重，可重复插入
    func testNilKeyEntriesAreNeverDeduped() {
        let w = UsageWindow()
        w.insert(entry(min: 0, key: nil))
        w.insert(entry(min: 0, key: nil))
        w.insert(entry(min: 0, key: nil))
        XCTAssertEqual(w.count, 3)
    }

    // MARK: 驱逐

    func testEvictDropsEntriesOlderThanRetention() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, key: "old"))          // base
        w.insert(entry(min: 60 * 5, key: "keep"))    // base + 5h
        w.evict(now: base.addingTimeInterval(6.5 * 3600))
        XCTAssertEqual(w.snapshot().map(\.dedupKey), ["keep"])
    }

    func testEvictBoundaryIsInclusiveOfCutoff() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, key: "atCutoff"))
        // now - 6h == entry.timestamp，恰好在边界上，应保留
        w.evict(now: base.addingTimeInterval(6 * 3600))
        XCTAssertEqual(w.count, 1)
    }

    func testEvictAlsoClearsDedupIndex() {
        let w = UsageWindow(retentionHours: 6)
        w.insert(entry(min: 0, total: 100, key: "k"))
        w.evict(now: base.addingTimeInterval(7 * 3600))
        XCTAssertEqual(w.count, 0)
        // 索引已清，同键条目应能重新插入（即使 token 更少）
        XCTAssertTrue(w.insert(entry(min: 60 * 7, total: 1, key: "k")).accepted)
        XCTAssertEqual(w.count, 1)
    }

    func testEvictOnEmptyWindowIsNoop() {
        let w = UsageWindow()
        w.evict(now: base)
        XCTAssertEqual(w.count, 0)
    }
}
