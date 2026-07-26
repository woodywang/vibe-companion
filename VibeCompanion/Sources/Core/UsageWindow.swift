import Foundation

/// 有界、有序、自去重的 entry 窗口。
///
/// 架构方案 C 的载体：只保留最近 `retentionHours` 小时的原始 entry，
/// 每次变化后对这个有界集合重跑 ccusage 的分块与 burn rate。
/// 这样既拿到"全量重算"的正确性（乱序免疫、可实现去重替换语义），
/// 又有确定的内存上界。
///
/// **非线程安全**——调用方需保证串行访问（P3 中由 `@MainActor` 保证）。
final class UsageWindow {
    /// 按 timestamp 升序。
    private var sorted: [UsageEntry] = []
    /// dedupKey -> 当前留存的条目。
    private var byKey: [String: UsageEntry] = [:]
    private let retention: TimeInterval

    init(retentionHours: Double = 6) {
        self.retention = retentionHours * 3600
    }

    var count: Int { sorted.count }

    /// 插入一条 entry。返回 false 表示因去重被拒绝。
    @discardableResult
    func insert(_ entry: UsageEntry) -> Bool {
        if let key = entry.dedupKey {
            if let existing = byKey[key] {
                guard shouldReplace(candidate: entry, existing: existing) else { return false }
                remove(existing)
            }
            byKey[key] = entry
        }
        insertSorted(entry)
        return true
    }

    /// 丢弃 timestamp 早于 `now - retention` 的条目。边界值保留。
    func evict(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        let keepFrom = sorted.firstIndex { $0.timestamp >= cutoff } ?? sorted.count
        guard keepFrom > 0 else { return }
        for e in sorted[..<keepFrom] {
            if let k = e.dedupKey, byKey[k] == e { byKey.removeValue(forKey: k) }
        }
        sorted.removeFirst(keepFrom)
    }

    /// 有序、已去重的快照，可直接喂给 `identifySessionBlocks`。
    func snapshot() -> [UsageEntry] { sorted }

    // MARK: - private

    /// 二分查找插入位置，保持稳定（同 timestamp 时后插入者靠后）。
    private func insertSorted(_ entry: UsageEntry) {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].timestamp <= entry.timestamp { lo = mid + 1 } else { hi = mid }
        }
        sorted.insert(entry, at: lo)
    }

    /// 线性查找移除。数组规模上界约 1000（实测最大块 716 条），无需优化。
    private func remove(_ entry: UsageEntry) {
        if let i = sorted.firstIndex(where: { $0 == entry }) {
            sorted.remove(at: i)
        }
    }
}
