import Foundation

/// Claude 的去重键：`messageId:requestId`。
///
/// 对齐 ccusage `createUniqueHash`（v19.0.3 data-loader.ts）：
/// messageId 缺失则返回 nil（永不去重）；requestId 缺失则退化为仅用 messageId。
///
/// 注意**不是** JSONL 行内的 `uuid`——Claude 把一次响应写成多行，
/// 各行 uuid 不同但 messageId/requestId 相同。
func claudeDedupKey(messageId: String?, requestId: String?) -> String? {
    guard let messageId, !messageId.isEmpty else { return nil }
    guard let requestId, !requestId.isEmpty else { return messageId }
    return "\(messageId):\(requestId)"
}

/// 同键条目冲突时，新条目是否应取代已存条目。
///
/// 对齐 ccusage `should_replace_deduped_entry`（adapter/claude/mod.rs:224-238）。
/// 这是**替换**语义而非跳过——顺序无关，最终留下的总是"最优"那条。
func shouldReplace(candidate: UsageEntry, existing: UsageEntry) -> Bool {
    // 1. 非 sidechain 胜过 sidechain（与 token 多少无关）
    if candidate.isSidechain != existing.isSidechain {
        return existing.isSidechain
    }
    // 2. sidechain 状态相同：token 总量大的胜
    let candidateTotal = candidate.counts.total
    let existingTotal = existing.counts.total
    if candidateTotal != existingTotal {
        return candidateTotal > existingTotal
    }
    // 3. 总量也相同：带 speed 字段的胜
    return candidate.hasSpeed && !existing.hasSpeed
}
