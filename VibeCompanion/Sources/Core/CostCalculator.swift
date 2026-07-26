import Foundation

/// cost 计算常量。对齐 ccusage cost.rs:7 与 pricing.rs。
enum CostConfig {
    /// 1 小时缓存写入 = `input 单价 × 2.0`。
    /// 这是 ccusage 的**硬编码倍率**，不是 LiteLLM 的 key，
    /// 也**不是**从 cache_creation 单价推导。
    static let cacheCreate1hInputMultiplier: Double = 2.0
    static let defaultLongContextThreshold: Int = 200_000
}

/// 边际分段计价：阈值内按 base，超出部分按 above。
/// 对齐 ccusage `tiered_cost`（cost.rs）。`above` 为 nil 时不分段。
func tieredCost(_ tokens: Int, base: Double, above: Double?,
                threshold: Int = CostConfig.defaultLongContextThreshold) -> Double {
    guard tokens > 0 else { return 0 }
    if let above, tokens > threshold {
        return Double(threshold) * base + Double(tokens - threshold) * above
    }
    return Double(tokens) * base
}

/// 计算一条 entry 的 cost。对齐 ccusage `calculate_cost_from_pricing`（cost.rs:103-183）。
///
/// 两条分支：
/// - `longContextThreshold` 非 nil（OpenAI）：由 `input` 单独决定档位，
///   所有桶**整体**按该档单价计费
/// - 否则（Anthropic）：每个桶**独立**做 200K 边际分段
///
/// `extraTotal` 不计费——它是 total 与分项之差，无对应单价。
func calculateCost(counts: TokenCounts, pricing: ModelPricing, isFast: Bool) -> Double {
    let cc1hRate = pricing.input * CostConfig.cacheCreate1hInputMultiplier
    let cc1hAbove = pricing.inputAbove200k.map { $0 * CostConfig.cacheCreate1hInputMultiplier }

    // cache_read 单价**未显式给出**时，cached token 按**完整 input 单价**计费，
    // 而不是解码期填入的 `input × 0.1` 缺省（设计规格 §5 Codex 路径）。
    // 语义是"这些 token 当普通 input 算"，故分段单价一并取 input 桶的。
    // 实测内置快照 416 条里 98 条无显式 cache_read，且它们**无一**带
    // `input_cost_per_token_above_200k_tokens`，故 above 的取法在真实数据上不产生分歧。
    let crRate = pricing.cacheReadExplicit ? pricing.cacheRead : pricing.input
    let crAbove = pricing.cacheReadExplicit ? pricing.cacheReadAbove200k : pricing.inputAbove200k

    let base: Double
    if let threshold = pricing.longContextThreshold {
        let isLong = counts.input > threshold
        func rate(_ b: Double, _ a: Double?) -> Double { isLong ? (a ?? b) : b }
        base = Double(counts.input) * rate(pricing.input, pricing.inputAbove200k)
             + Double(counts.output) * rate(pricing.output, pricing.outputAbove200k)
             + Double(counts.cacheCreation5m) * rate(pricing.cacheCreate, pricing.cacheCreateAbove200k)
             + Double(counts.cacheCreation1h) * rate(cc1hRate, cc1hAbove)
             + Double(counts.cacheRead) * rate(crRate, crAbove)
    } else {
        let t = CostConfig.defaultLongContextThreshold
        base = tieredCost(counts.input, base: pricing.input,
                          above: pricing.inputAbove200k, threshold: t)
             + tieredCost(counts.output, base: pricing.output,
                          above: pricing.outputAbove200k, threshold: t)
             + tieredCost(counts.cacheCreation5m, base: pricing.cacheCreate,
                          above: pricing.cacheCreateAbove200k, threshold: t)
             + tieredCost(counts.cacheCreation1h, base: cc1hRate,
                          above: cc1hAbove, threshold: t)
             + tieredCost(counts.cacheRead, base: crRate,
                          above: crAbove, threshold: t)
    }

    return base * (isFast ? pricing.fastMultiplier : 1.0)
}

/// 经由 `PricingSource` 解析模型名后计算。
/// 模型名为 nil 或未命中定价表时返回 nil——调用方应记为"无 cost"，
/// 但**仍需照常统计该 entry 的 token**。
func calculateCost(counts: TokenCounts, model: String?,
                   isFast: Bool, source: PricingSource) -> Double? {
    guard let model, let pricing = source.pricing(for: model) else { return nil }
    return calculateCost(counts: counts, pricing: pricing, isFast: isFast)
}
