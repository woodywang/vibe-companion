import Foundation

/// 聚合器全部对外状态的不可变副本。
///
/// 存在的理由是「冻结显示」：暂停时需要把某一刻的读数原样留住，
/// 而 `TokenAggregator` 会继续变化。快照是纯值，不含任何 I/O。
struct UsageSnapshot: Equatable {
    /// ccusage 区块速率，菜单栏用。
    var tokensPerMinute: Double = 0
    var indicatorTokensPerMinute: Double = 0
    var level: BurnRateLevel = .normal
    var costPerHour: Double?
    var hasBurnRate: Bool = false
    var todayTotal: Int = 0
    /// 瞬时速率，表盘用。冻结显示对它同样生效。
    var instantTokensPerMinute: Double = 0
    var recentPeak: Double = 0
}

extension UsageSnapshot {
    /// 取聚合器此刻的读数。
    @MainActor
    init(_ a: TokenAggregator) {
        self.init(tokensPerMinute: a.tokensPerMinute,
                  indicatorTokensPerMinute: a.indicatorTokensPerMinute,
                  level: a.level,
                  costPerHour: a.costPerHour,
                  hasBurnRate: a.hasBurnRate,
                  todayTotal: a.todayTotal,
                  instantTokensPerMinute: a.instantTokensPerMinute,
                  recentPeak: a.recentPeak)
    }
}

/// 展示层的暂停语义：**照常摄入、只冻结显示**。
///
/// 为什么不能在采集回调里丢弃 entry：`JsonlTailer` 的 offset 照常前进，
/// 被丢的行永远读不回来。活跃的 5 小时区块因此缺条目，而
/// `calculateBurnRate` 的分子是区块 token 总量、分母是「末条 − 首条」——
/// 缺条目只减分子不减分母，恢复后得到的是**偏低的错值**，不是「过时的值」。
/// 与 ccusage 数值一致是本项目的最高原则，故摄入任何时候都不得中断。
///
/// 冻结只发生在这一层：`Core/` 的算法与窗口完全不知道暂停的存在。
@MainActor
final class UsageDisplay {
    private let aggregator: TokenAggregator
    /// 非 nil 即表示显示已冻结在该快照上。
    private(set) var frozen: UsageSnapshot?

    /// `paused` 为启动时的持久化状态：此时本会话没有「暂停那一刻」，
    /// 就冻结在初始读数（`--`）上，直到用户恢复显示。
    init(aggregator: TokenAggregator, paused: Bool = false) {
        self.aggregator = aggregator
        if paused { frozen = UsageSnapshot(aggregator) }
    }

    var isPaused: Bool { frozen != nil }

    /// 暂停时抓一张快照，恢复时丢掉它——于是恢复后立即显示当前真实值。
    func setPaused(_ paused: Bool) {
        frozen = paused ? UsageSnapshot(aggregator) : nil
    }

    /// 采集回调入口。无论是否暂停都摄入，保证区块完整。
    func ingest(_ entry: UsageEntry) {
        aggregator.ingest(entry)
    }

    var snapshot: UsageSnapshot { frozen ?? UsageSnapshot(aggregator) }
}
