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
    ///
    /// "近期"是真的近期：每次 `recompute()` 按 `peakHalfLife` 施加指数衰减，
    /// 峰值会自己降回来。见 `decayPeak(to:)`。
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
    /// 上次对 `recentPeak` 施加衰减的时刻。nil 表示还没跑过 `recompute()`。
    private var lastPeakDecay: Date?

    /// `recentPeak` 的半衰期（秒）。
    ///
    /// 为什么是指数衰减而不是"只取当前活跃块内的峰值"：session block 长达 5 小时，
    /// 块内峰值同样会把一次尖峰钉住整整一个块——换汤不换药。而按固定窗口
    /// 取最大值则要额外维护一条速率历史，收益不抵复杂度。
    ///
    /// 为什么是 5 分钟：一次 760k 的尖峰（本机实测最大值）约 15 分钟衰到 ~95k，
    /// 量程随之收回到 100k 档；同时 5 分钟远长于常见的思考/编译/审阅间隙，
    /// 连续会话里的真实峰值不会被中途抹掉。
    private static let peakHalfLife: TimeInterval = 300

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
        // 先衰减：无论后面走哪条分支（含 reset 早返回），峰值都必须随时间回落
        decayPeak(to: t)
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
        // 喂给峰值的是**显示中的**速率：空闲时显示 0，峰值就该继续衰减，
        // 而不是被块的历史平均速率一直顶住（块能横跨 5 小时，那个值几乎不动）。
        recentPeak = max(recentPeak, tokensPerMinute)
    }

    // MARK: - private

    /// 对 `recentPeak` 施加指数衰减。首次调用只记时刻、不衰减。
    private func decayPeak(to t: Date) {
        defer { lastPeakDecay = t }
        guard let last = lastPeakDecay, recentPeak > 0 else { return }
        let dt = t.timeIntervalSince(last)
        guard dt > 0 else { return }
        let decayed = recentPeak * pow(0.5, dt / Self.peakHalfLife)
        // 收敛到 0，免得留一条永远接近 0 但不为 0 的长尾
        recentPeak = decayed < 1 ? 0 : decayed
    }

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
