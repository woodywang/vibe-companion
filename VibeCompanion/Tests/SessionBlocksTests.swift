import XCTest
@testable import VibeCompanion

final class SessionBlocksTests: XCTestCase {

    private let hourMs: Int64 = 3_600_000

    func testFloorOnExactHourIsIdentity() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs), 5 * hourMs)
    }

    func testFloorMidHourRoundsDown() {
        XCTAssertEqual(floorToUTCHourMillis(5 * hourMs + 1), 5 * hourMs)
        XCTAssertEqual(floorToUTCHourMillis(6 * hourMs - 1), 5 * hourMs)
    }

    func testFloorAtZero() {
        XCTAssertEqual(floorToUTCHourMillis(0), 0)
    }

    /// 关键：欧几里得除法而非截断除法。
    /// -1 ms 属于 [-1h, 0) 这个小时，应向下取整到 -1h，而不是 0。
    func testFloorNegativeUsesEuclideanDivision() {
        XCTAssertEqual(floorToUTCHourMillis(-1), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs), -hourMs)
        XCTAssertEqual(floorToUTCHourMillis(-hourMs - 1), -2 * hourMs)
    }

    /// Date 包装版：2026-07-25T17:22:13.456Z -> 2026-07-25T17:00:00Z
    func testFloorDateDropsMinutesSecondsMillis() {
        let d = Date(timeIntervalSince1970: 1_785_000_133.456)
        let floored = floorToUTCHour(d)
        let secs = floored.timeIntervalSince1970
        XCTAssertEqual(secs.truncatingRemainder(dividingBy: 3600), 0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(floored, d)
        XCTAssertLessThan(d.timeIntervalSince(floored), 3600)
    }

    func testSessionDurationIsFiveHours() {
        XCTAssertEqual(SessionBlockConfig.durationHours, 5.0)
    }

    // MARK: - identifySessionBlocks

    /// 基准时刻 2026-07-25T00:00:00Z，正好是整点，便于推算
    private var base: Date { Date(timeIntervalSince1970: 1_784_937_600) }

    private func mkEntry(offsetHours: Double, tokens: Int = 10) -> UsageEntry {
        UsageEntry(timestamp: base.addingTimeInterval(offsetHours * 3600),
                   agent: "claude", sessionId: nil, model: "claude-opus-5",
                   counts: TokenCounts(input: tokens),
                   isSidechain: false, hasSpeed: false, isFastSpeed: false,
                   dedupKey: "m\(offsetHours):r")
    }

    private func blocks(_ entries: [UsageEntry], nowOffsetHours: Double) -> [SessionBlock] {
        identifySessionBlocks(entries,
                              sessionDurationHours: 5,
                              now: base.addingTimeInterval(nowOffsetHours * 3600))
    }

    func testEmptyInputYieldsNoBlocks() {
        XCTAssertTrue(blocks([], nowOffsetHours: 1).isEmpty)
    }

    func testEntriesWithinFiveHoursFormOneBlock() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 2), mkEntry(offsetHours: 4)],
                       nowOffsetHours: 4.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.count, 3)
        XCTAssertEqual(b[0].tokenCounts.total, 30)
    }

    /// 恰好 5h 不开新块（严格大于才开）
    func testExactlyFiveHoursDoesNotSplit() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 5)], nowOffsetHours: 5.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.count, 2)
    }

    /// 触发条件一：距块起点超过 5h。两条 entry 间隔仅 4h，不触发 gap。
    func testSplitsWhenExceedingBlockStart() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 2),
                        mkEntry(offsetHours: 4), mkEntry(offsetHours: 5.5)],
                       nowOffsetHours: 6)
        XCTAssertEqual(b.count, 2)
        XCTAssertFalse(b.contains { $0.isGap })
        XCTAssertEqual(b[0].entries.count, 3)
        XCTAssertEqual(b[1].entries.count, 1)
    }

    /// 触发条件二：距上一条超过 5h，额外插入 gap 块
    func testGapBlockInsertedOnLongSilence() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 7)], nowOffsetHours: 7.5)
        XCTAssertEqual(b.count, 3)
        XCTAssertFalse(b[0].isGap)
        XCTAssertTrue(b[1].isGap)
        XCTAssertFalse(b[2].isGap)
        // gap 跨度 = 上一条 + 5h  ->  下一条
        XCTAssertEqual(b[1].startTime, base.addingTimeInterval(5 * 3600))
        XCTAssertEqual(b[1].endTime, base.addingTimeInterval(7 * 3600))
        XCTAssertTrue(b[1].entries.isEmpty)
    }

    /// 块起点 floor 到整点：07:42 起的块，startTime 应为 07:00
    func testBlockStartFlooredToHour() {
        let e = UsageEntry(timestamp: base.addingTimeInterval(7 * 3600 + 42 * 60),
                           agent: "claude", sessionId: nil, model: nil,
                           counts: TokenCounts(input: 1), isSidechain: false,
                           hasSpeed: false, isFastSpeed: false, dedupKey: "x:y")
        let b = blocks([e], nowOffsetHours: 8)
        XCTAssertEqual(b[0].startTime, base.addingTimeInterval(7 * 3600))
        XCTAssertEqual(b[0].endTime, base.addingTimeInterval(12 * 3600))
    }

    /// isActive 需两条件同时成立
    func testIsActiveRequiresBothConditions() {
        // now 距末条 1h（<5h），且 now < blockEnd  -> active
        XCTAssertTrue(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 1)[0].isActive)
        // now 距末条 6h（>=5h）-> 不 active
        XCTAssertFalse(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 6)[0].isActive)
    }

    func testGapBlockIsNeverActive() {
        let b = blocks([mkEntry(offsetHours: 0), mkEntry(offsetHours: 7)], nowOffsetHours: 7.1)
        XCTAssertFalse(b[1].isActive)
    }

    /// 乱序输入必须先排序再分块
    func testUnorderedInputIsSortedFirst() {
        let b = blocks([mkEntry(offsetHours: 4), mkEntry(offsetHours: 0), mkEntry(offsetHours: 2)],
                       nowOffsetHours: 4.5)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].entries.map(\.timestamp),
                       [0.0, 2.0, 4.0].map { base.addingTimeInterval($0 * 3600) })
    }

    func testCostIsNilBeforePricingIsWired() {
        XCTAssertNil(blocks([mkEntry(offsetHours: 0)], nowOffsetHours: 1)[0].costUSD)
    }
}
