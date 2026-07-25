import Foundation

extension SessionBlock {
    /// 返回一个填入了 cost 的副本。
    func withCostUSD(_ cost: Double?) -> SessionBlock {
        SessionBlock(id: id, startTime: startTime, endTime: endTime,
                     actualEndTime: actualEndTime, isActive: isActive, isGap: isGap,
                     entries: entries, tokenCounts: tokenCounts, costUSD: cost)
    }
}

/// 计算一个 block 的总 cost。
///
/// **必须逐条 entry 计价后求和**，不可用聚合后的 `tokenCounts` 一次性算：
/// - 200K 边际分段是按**单次请求**判定的，聚合后会把多条小请求错误地推过阈值
/// - `fastMultiplier` 是 per-entry 的（取决于该条的 `usage.speed`）
/// - 一个 block 内可能混用多个模型，单价不同
///
/// 全部 entry 都未命中定价时返回 nil。部分命中时只累加命中的部分——
/// 未命中的 entry 其 token 仍照常计入 `tokenCounts`。
func blockCostUSD(_ block: SessionBlock, source: PricingSource) -> Double? {
    var total: Double = 0
    var matched = false
    for entry in block.entries {
        if let cost = calculateCost(counts: entry.counts, model: entry.model,
                                    isFast: entry.isFastSpeed, source: source) {
            total += cost
            matched = true
        }
    }
    return matched ? total : nil
}
