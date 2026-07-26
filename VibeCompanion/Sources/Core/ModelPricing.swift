import Foundation

/// 定价缺省规则。对齐 ccusage pricing.rs:315-318。
enum PricingDefaults {
    static let cacheCreateMultiplier: Double = 1.25
    static let cacheReadMultiplier: Double = 0.1
}

/// 单个模型的定价。对齐 ccusage `Pricing`（pricing.rs:28-45）。
struct ModelPricing: Equatable {
    let input: Double
    let output: Double
    let cacheCreate: Double
    let cacheRead: Double
    /// `cache_read_input_token_cost` 是否显式给出。
    /// Codex 的计价分支依赖它：未显式给出时 cached 按**完整 input 单价**计费，
    /// 而不是 Claude 路径的 `input × 0.1` 缺省。
    let cacheReadExplicit: Bool

    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheCreateAbove200k: Double?
    let cacheReadAbove200k: Double?

    /// 非 nil 时走 OpenAI 的"整请求选档"分支（由 input_tokens 单独决定档位）。
    /// Anthropic 模型为 nil，走按桶边际分段。
    ///
    /// **生产环境恒为 nil。** 该字段是为协议预留的：LiteLLM 数据源不提供
    /// long-context 阈值（内置快照 416 条、79 个不同 key，无一个 `long_context*`），
    /// `builtinPricingOverrides()` 也只覆盖三个 Anthropic 模型且都填 nil。
    /// 因此 `calculateCost` 的整请求选档分支仅由单测覆盖。
    ///
    /// 不要凭空硬编码 OpenAI 的档位阈值——ccusage 用的是同一份 LiteLLM 数据源，
    /// 那里既然没有这些 key，ccusage 也走不到那条分支；补数字反而会偏离 parity。
    let longContextThreshold: Int?
    let fastMultiplier: Double
}

extension ModelPricing {
    /// 从一条 LiteLLM 模型条目解码。缺 input 或 output 时返回 nil（整条跳过）。
    init?(liteLLM json: [String: Any]) {
        guard let input = json["input_cost_per_token"] as? Double,
              let output = json["output_cost_per_token"] as? Double else { return nil }

        let explicitCacheRead = json["cache_read_input_token_cost"] as? Double

        self.input = input
        self.output = output
        self.cacheCreate = (json["cache_creation_input_token_cost"] as? Double)
            ?? input * PricingDefaults.cacheCreateMultiplier
        self.cacheRead = explicitCacheRead ?? input * PricingDefaults.cacheReadMultiplier
        self.cacheReadExplicit = explicitCacheRead != nil

        self.inputAbove200k = json["input_cost_per_token_above_200k_tokens"] as? Double
        self.outputAbove200k = json["output_cost_per_token_above_200k_tokens"] as? Double
        self.cacheCreateAbove200k = json["cache_creation_input_token_cost_above_200k_tokens"] as? Double
        self.cacheReadAbove200k = json["cache_read_input_token_cost_above_200k_tokens"] as? Double

        // LiteLLM 条目里没有对应的 key，恒为 nil。见字段声明处的说明。
        self.longContextThreshold = nil

        let providerEntry = json["provider_specific_entry"] as? [String: Any]
        self.fastMultiplier = (providerEntry?["fast"] as? Double) ?? 1.0
    }
}

/// 解码整张 LiteLLM 表，跳过所有非法/非模型条目。
func decodeLiteLLMPricing(_ json: [String: Any]) -> [String: ModelPricing] {
    var out: [String: ModelPricing] = [:]
    for (name, value) in json {
        guard let entry = value as? [String: Any],
              let pricing = ModelPricing(liteLLM: entry) else { continue }
        out[name] = pricing
    }
    return out
}
