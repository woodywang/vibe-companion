import Foundation

/// 全局应用配置
enum AppConfig {
    /// 有界窗口保留时长（小时）。推导见 spec 6.2：
    /// 活跃块的首条 entry 不会早于 now-5h，加 1h 余量覆盖整点 floor 偏移。
    static let windowRetentionHours: Double = 6
    /// 空闲归零阈值（秒）。偏离 D1。
    static let idleTimeoutSeconds: TimeInterval = 90
    /// 重算周期（秒）。
    static let recomputeIntervalSeconds: TimeInterval = 2
    /// 回扫窗口（小时），与 windowRetentionHours 保持一致。
    static let backfillWindowHours: Double = 6
}
