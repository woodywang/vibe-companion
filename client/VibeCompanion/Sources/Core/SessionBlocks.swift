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
