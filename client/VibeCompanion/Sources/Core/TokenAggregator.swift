import Foundation

/// 维护有界窗口，按 ccusage 的 session block 模型计算 burn rate。
///
/// 与旧实现（60 秒滑窗内 token 求和）的根本差异：窗口以 **entry 自身的
/// timestamp** 为准而非到达时间，这样回扫进来的历史数据才能被正确分块。
@MainActor
final class TokenAggregator: ObservableObject {

    // MARK: 发布的状态

    /// 主速率，分子为 Total Tokens（含 cache_read）。空闲时为 0。
    @Published private(set) var tokensPerMinute: Double = 0
    /// 档位速率，分子仅 input + output。
    @Published private(set) var indicatorTokensPerMinute: Double = 0
    /// 由 `indicatorTokensPerMinute` 判定的档位。
    @Published private(set) var level: BurnRateLevel = .normal
    /// 估算花费速率；定价未就绪或未命中时为 nil。
    @Published private(set) var costPerHour: Double?
    /// false 表示活跃块不足以算出速率（只有一条 entry），UI 应显示 `--` 而非 `0`。
    @Published private(set) var hasBurnRate: Bool = false
    /// 距末条 entry 超过 idle 超时。
    @Published private(set) var isIdle: Bool = true
    /// 今日累计 Total Tokens。
    @Published private(set) var todayTotal: Int = 0
    /// 近期观察到的最大速率，供自适应量程使用。
    @Published private(set) var recentPeak: Double = 0

    // MARK: 内部状态

    /// 主窗口：只保留够算活跃块的时长。
    private let window: UsageWindow
    /// 今日累计窗口：主窗口装不下一整天，故单独维护。
    /// 复用 `UsageWindow` 使去重语义自动生效。
    private let dailyWindow: UsageWindow
    private let pricing: PricingSource?
    private let idleTimeout: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    init(pricing: PricingSource?,
         retentionHours: Double = 6,
         idleTimeoutSeconds: TimeInterval = 90,
         now: @escaping () -> Date = { Date() }) {
        self.window = UsageWindow(retentionHours: retentionHours)
        self.dailyWindow = UsageWindow(retentionHours: 25)
        self.pricing = pricing
        self.idleTimeout = idleTimeoutSeconds
        self.now = now
    }

    /// 启动周期性重算。测试中不调用，改为手动 `recompute()`。
    func startTicking(interval: TimeInterval = 2) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    /// 注入一条采集到的记录。不立即重算——一次 FSEvents 常带来几十行。
    func ingest(_ entry: UsageEntry) {
        window.insert(entry)
        dailyWindow.insert(entry)
    }

    /// 驱逐过期条目、重新分块、更新全部发布状态。
    func recompute() {
        let t = now()
        window.evict(now: t)
        dailyWindow.evict(now: t)

        updateTodayTotal(now: t)

        let blocks = identifySessionBlocks(window.snapshot(), now: t)
        guard let active = blocks.first(where: { $0.isActive && !$0.isGap }) else {
            reset()
            return
        }

        let withCost = pricing.map { active.withCostUSD(blockCostUSD(active, source: $0)) } ?? active
        guard let rate = calculateBurnRate(withCost) else {
            reset()
            return
        }

        // 空闲判定：距末条 entry 超时则归零（偏离 D1）。
        // ccusage 原生行为是冻结，但它是跑完即退的 CLI，本项目是常驻仪表。
        let idle = active.actualEndTime.map { t.timeIntervalSince($0) > idleTimeout } ?? true

        hasBurnRate = true
        isIdle = idle
        tokensPerMinute = idle ? 0 : rate.tokensPerMinute
        indicatorTokensPerMinute = idle ? 0 : rate.tokensPerMinuteForIndicator
        level = BurnRateLevel.from(indicator: indicatorTokensPerMinute)
        costPerHour = idle ? nil : rate.costPerHour
        recentPeak = max(recentPeak, rate.tokensPerMinute)
    }

    // MARK: - private

    private func reset() {
        hasBurnRate = false
        isIdle = true
        tokensPerMinute = 0
        indicatorTokensPerMinute = 0
        level = .normal
        costPerHour = nil
    }

    private func updateTodayTotal(now t: Date) {
        let today = Self.dayKey(t)
        todayTotal = dailyWindow.snapshot()
            .filter { Self.dayKey($0.timestamp) == today }
            .reduce(0) { $0 + $1.counts.total }
    }

    private static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
