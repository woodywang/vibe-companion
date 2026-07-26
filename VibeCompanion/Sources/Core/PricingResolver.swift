import Foundation

/// 定价来源。计算层只依赖这个协议，不关心定价从哪来——
/// 这使 cost 单测无需联网或读文件。
protocol PricingSource {
    func pricing(for model: String) -> ModelPricing?
}

/// Anthropic 的日期后缀位数（`YYYYMMDD`）。
/// 对齐 ccusage `MODEL_DATE_SUFFIX_DIGITS`。
private let modelDateSuffixDigits = 8

/// `.` 与 `@` 归一化为 `-`。对齐 ccusage `normalized_pricing_key`。
func normalizedPricingKey(_ s: String) -> String {
    s.replacingOccurrences(of: ".", with: "-")
     .replacingOccurrences(of: "@", with: "-")
}

/// 边界感知的子串包含判定。对齐 ccusage `contains_pricing_key`
/// 与 `suffix_starts_with_numeric_model_version`（pricing.rs:1243-1298）。
///
/// - 匹配起点前一字符须非字母数字（或为串首）
/// - 匹配终点后一字符须非字母数字（或为串尾）
/// - key 以数字结尾且后接 `-<数字串>` 时拒绝，除非数字串恰好 8 位
func containsPricingKey(_ haystack: String, _ needle: String) -> Bool {
    guard !needle.isEmpty else { return false }
    let h = Array(haystack), n = Array(needle)
    guard h.count >= n.count else { return false }

    for start in 0...(h.count - n.count) {
        guard Array(h[start..<(start + n.count)]) == n else { continue }

        // 前边界
        if start > 0 {
            let prev = h[start - 1]
            if prev.isLetter || prev.isNumber { continue }
        }

        let end = start + n.count
        if end < h.count {
            let next = h[end]
            // 后边界
            if next.isLetter || next.isNumber { continue }
            // 版本号后缀规则
            if let lastChar = n.last, lastChar.isNumber, next == "-" {
                let digits = h[(end + 1)...].prefix { $0.isNumber }
                if !digits.isEmpty && digits.count != modelDateSuffixDigits { continue }
            }
        }
        return true
    }
    return false
}

/// 一张可查询的定价表。
struct PricingTable: PricingSource {
    private let entries: [String: ModelPricing]
    private let aliases: [String: String]

    init(entries: [String: ModelPricing], aliases: [String: String] = [:]) {
        self.entries = entries
        self.aliases = aliases
    }

    /// 四步解析：精确 → 归一化+模糊（最长胜） → 别名 → nil。
    func pricing(for model: String) -> ModelPricing? {
        if let exact = entries[model] { return exact }
        if let fuzzy = fuzzyLookup(model) { return fuzzy }
        if let aliased = aliases[model] {
            if let exact = entries[aliased] { return exact }
            return fuzzyLookup(aliased)
        }
        return nil
    }

    private func fuzzyLookup(_ model: String) -> ModelPricing? {
        let normalizedModel = normalizedPricingKey(model)
        let matched = entries.filter { key, _ in
            matches(candidate: key, model: model, normalizedModel: normalizedModel)
        }
        // 最长 key 胜；同长时字典序小者胜
        return matched.max { a, b in
            if a.key.count != b.key.count { return a.key.count < b.key.count }
            return a.key > b.key
        }?.value
    }

    private func matches(candidate: String, model: String, normalizedModel: String) -> Bool {
        if containsPricingKey(candidate, model) || containsPricingKey(model, candidate) {
            return true
        }
        let normalizedCandidate = normalizedPricingKey(candidate)
        return containsPricingKey(normalizedCandidate, normalizedModel)
            || containsPricingKey(normalizedModel, normalizedCandidate)
    }
}
