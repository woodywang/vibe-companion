import Foundation

/// 归一化的 token 分桶。对齐 ccusage `TokenCounts`（types.rs:76-91）。
///
/// cacheCreation 拆成 5m / 1h 两个桶：计数场景两者等价合并
/// （见 `cacheCreationTotal`），但计价场景单价不同，必须分开。
struct TokenCounts: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation5m: Int = 0
    var cacheCreation1h: Int = 0
    var cacheRead: Int = 0
    /// 未归类 token（gemini 等 agent 声明的 total 超出分项之和的部分）。
    /// claude / codex 恒为 0。
    var extraTotal: Int = 0

    /// ccusage `TokenCounts::total()`——burn rate 的分子（Total Tokens 口径）。
    var total: Int {
        input + output + cacheCreation5m + cacheCreation1h + cacheRead + extraTotal
    }

    /// ccusage `cache_creation_token_count()`——计数场景下两档缓存写入合并。
    var cacheCreationTotal: Int { cacheCreation5m + cacheCreation1h }

    /// `tokensPerMinuteForIndicator` 的分子——两个 cache 桶均排除。
    var inputPlusOutput: Int { input + output }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheCreation5m: lhs.cacheCreation5m + rhs.cacheCreation5m,
                    cacheCreation1h: lhs.cacheCreation1h + rhs.cacheCreation1h,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    extraTotal: lhs.extraTotal + rhs.extraTotal)
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}
