import Foundation

/// token 消耗速率。对齐 ccusage `BurnRate`（blocks.rs:535-552）。
struct BurnRate: Equatable {
    /// 主速率：分子为 `TokenCounts.total`（**含** cache_read）。
    /// 驱动速度表指针、数字与配色。
    let tokensPerMinute: Double
    /// 档位速率：分子仅 `input + output`（两个 cache 桶均排除）。
    /// ccusage 用它保持与 prompt cache 出现之前的阈值可比。
    let tokensPerMinuteForIndicator: Double
    /// `costUSD / durationMinutes * 60`；块无 cost 时为 nil。
    let costPerHour: Double?
}

/// 档位阈值。对齐 ccusage statusline（commands/mod.rs:467-473）。
///
/// 注意：v17 时代的 `{HIGH: 1000, MODERATE: 500}` 已随 live monitor
/// 在 v18 移除，**不要使用**。
enum BurnRateLevel: Equatable {
    case normal, moderate, high

    static let moderateThreshold: Double = 2000
    static let highThreshold: Double = 5000

    /// 判定依据是 `tokensPerMinuteForIndicator`，**不是** `tokensPerMinute`。
    static func from(indicator: Double) -> BurnRateLevel {
        if indicator < moderateThreshold { return .normal }
        if indicator < highThreshold { return .moderate }
        return .high
    }
}

/// 计算块的 burn rate。对齐 ccusage `calculate_burn_rate`（blocks.rs:535-552）。
///
/// 分母是**首条 entry → 末条 entry**，不是块起点，也不是 now——
/// 因此空闲时间不会稀释速率，速率会"冻结"。展示层的空闲归零
/// （偏离 D1）在别处处理，本函数保持与 ccusage 一致。
func calculateBurnRate(_ block: SessionBlock) -> BurnRate? {
    guard !block.entries.isEmpty, !block.isGap else { return nil }
    guard let first = block.entries.first?.timestamp,
          let last = block.entries.last?.timestamp else { return nil }

    let durationMinutes = last.timeIntervalSince(first) / 60
    guard durationMinutes > 0 else { return nil }

    return BurnRate(
        tokensPerMinute: Double(block.tokenCounts.total) / durationMinutes,
        tokensPerMinuteForIndicator: Double(block.tokenCounts.inputPlusOutput) / durationMinutes,
        costPerHour: block.costUSD.map { $0 / durationMinutes * 60 }
    )
}
