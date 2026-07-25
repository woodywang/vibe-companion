import Foundation

/// session block 常量。对齐 ccusage `DEFAULT_SESSION_DURATION_HOURS`（main.rs:65）。
enum SessionBlockConfig {
    static let durationHours: Double = 5
    static let durationSeconds: TimeInterval = 5 * 3600
    static let millisPerHour: Int64 = 3_600_000
}

/// 向下取整到 UTC 整点（毫秒时间戳）。
///
/// 对齐 ccusage `TimestampMs::floor_to_hour()`（date_utils.rs:58-60），
/// 它用 Rust 的 `div_euclid`——**向下取整**除法。Swift 的 `/` 是向零截断，
/// 对负数结果不同，故此处显式修正。
func floorToUTCHourMillis(_ ms: Int64) -> Int64 {
    let h = SessionBlockConfig.millisPerHour
    let q = ms / h
    let r = ms % h
    return (r < 0 ? q - 1 : q) * h
}

/// `floorToUTCHourMillis` 的 Date 包装。
func floorToUTCHour(_ date: Date) -> Date {
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    return Date(timeIntervalSince1970: Double(floorToUTCHourMillis(ms)) / 1000)
}

/// 一个 5 小时计费块。对齐 ccusage `SessionBlock`（blocks.rs）。
struct SessionBlock: Equatable {
    let id: String
    /// 已 floor 到 UTC 整点的块起点。
    let startTime: Date
    /// `startTime + 5h`。
    let endTime: Date
    /// 块内末条 entry 的时间戳；gap 块为 nil。
    let actualEndTime: Date?
    let isActive: Bool
    let isGap: Bool
    let entries: [UsageEntry]
    let tokenCounts: TokenCounts
    /// 块内各 entry 单独计价后求和。P1 恒为 nil，由 P2 填充。
    let costUSD: Double?
}

/// 把 entry 切成 5 小时计费块。对齐 ccusage `identify_session_blocks`（blocks.rs:17-71）。
///
/// 两个**独立**的开新块条件，均为**严格大于**：
///   1. `entry.ts - blockStart > duration`
///   2. `entry.ts - lastEntry.ts > duration`
/// 仅条件 2 触发时额外插入一个 gap 伪块。
func identifySessionBlocks(_ entries: [UsageEntry],
                           sessionDurationHours: Double = SessionBlockConfig.durationHours,
                           now: Date) -> [SessionBlock] {
    guard !entries.isEmpty else { return [] }
    let duration = sessionDurationHours * 3600
    let sorted = entries.sorted { $0.timestamp < $1.timestamp }

    var blocks: [SessionBlock] = []
    var currentStart: Date?
    var current: [UsageEntry] = []

    for entry in sorted {
        if let start = currentStart {
            let lastTime = current.last?.timestamp ?? start
            let sinceStart = entry.timestamp.timeIntervalSince(start)
            let sinceLast = entry.timestamp.timeIntervalSince(lastTime)
            if sinceStart > duration || sinceLast > duration {
                blocks.append(makeSessionBlock(start: start, entries: current,
                                               now: now, duration: duration))
                if sinceLast > duration {
                    blocks.append(makeGapBlock(last: lastTime, next: entry.timestamp,
                                               duration: duration))
                }
                current = []
                currentStart = floorToUTCHour(entry.timestamp)
            }
        } else {
            currentStart = floorToUTCHour(entry.timestamp)
        }
        current.append(entry)
    }

    if let start = currentStart, !current.isEmpty {
        blocks.append(makeSessionBlock(start: start, entries: current,
                                       now: now, duration: duration))
    }
    return blocks
}

private func makeSessionBlock(start: Date, entries: [UsageEntry],
                              now: Date, duration: TimeInterval) -> SessionBlock {
    let end = start.addingTimeInterval(duration)
    let actualEnd = entries.last?.timestamp
    // 两个条件必须同时成立（blocks.rs:75）
    let isActive = actualEnd.map { now.timeIntervalSince($0) < duration && now < end } ?? false
    var counts = TokenCounts()
    for e in entries { counts += e.counts }
    return SessionBlock(id: iso8601Millis(start), startTime: start, endTime: end,
                        actualEndTime: actualEnd, isActive: isActive, isGap: false,
                        entries: entries, tokenCounts: counts, costUSD: nil)
}

private func makeGapBlock(last: Date, next: Date, duration: TimeInterval) -> SessionBlock {
    let start = last.addingTimeInterval(duration)
    return SessionBlock(id: "gap-\(iso8601Millis(start))", startTime: start, endTime: next,
                        actualEndTime: nil, isActive: false, isGap: true,
                        entries: [], tokenCounts: TokenCounts(), costUSD: nil)
}

private let blockIdFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f
}()

private func iso8601Millis(_ date: Date) -> String {
    blockIdFormatter.string(from: date)
}
