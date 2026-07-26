import Foundation

/// 一条归一化的 token 用量记录。
///
/// 与 `Models.swift` 中的旧 `UsageEvent` 并存——旧类型服务于尚未切换的
/// `TokenAggregator`，P3 完成切换后删除。
struct UsageEntry: Equatable {
    /// 记录自身的时间戳（**不是**采集到的时间）。分块与窗口全部以此为准。
    let timestamp: Date
    let agent: String              // "claude" | "codex"
    let sessionId: String?
    let model: String?
    let counts: TokenCounts

    /// 去重优先级 1：ccusage 认为非 sidechain 条目更可信。
    let isSidechain: Bool
    /// 去重优先级 3：`usage.speed` 字段是否存在。
    let hasSpeed: Bool
    /// 计价用：`usage.speed == "fast"` 时套用 fast 倍率。
    let isFastSpeed: Bool

    /// `nil` 表示该条目永不参与去重（缺少 message.id）。
    let dedupKey: String?
}
