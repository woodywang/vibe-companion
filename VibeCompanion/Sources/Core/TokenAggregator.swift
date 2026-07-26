import Foundation

/// 维护有界窗口，按 ccusage 的 session block 模型计算 burn rate。
///
/// 与旧实现（60 秒滑窗内 token 求和）的根本差异：窗口以 **entry 自身的
/// timestamp** 为准而非到达时间，这样回扫进来的历史数据才能被正确分块。
@MainActor
final class TokenAggregator: ObservableObject {

    // MARK: 发布的状态

    /// 区块速率，分子为 Total Tokens（含 cache_read）。**纯 ccusage 口径**。
    @Published private(set) var tokensPerMinute: Double = 0
    /// 档位速率，分子仅 input + output。
    @Published private(set) var indicatorTokensPerMinute: Double = 0
    /// 由 `indicatorTokensPerMinute` 判定的档位。
    @Published private(set) var level: BurnRateLevel = .normal
    /// 估算花费速率；定价未就绪或未命中时为 nil。
    @Published private(set) var costPerHour: Double?
    /// false 表示活跃块不足以算出速率（只有一条 entry），UI 应显示 `--` 而非 `0`。
    ///
    /// 这是 **ccusage 自己的语义**（`duration <= 0` 时没有速率），与"空闲"无关。
    @Published private(set) var hasBurnRate: Bool = false
    /// 今日累计 Total Tokens。
    @Published private(set) var todayTotal: Int = 0

    /// **瞬时**速率（tok/min），由时间衰减 EMA 驱动，供速度表使用。
    ///
    /// 与上面的 `tokensPerMinute` 是两个不同的量，不要混用：
    /// - `tokensPerMinute` 是 ccusage 的 5 小时区块**全程平均**，菜单栏用它，
    ///   与 `ccusage blocks` 的输出一致；
    /// - `instantTokensPerMinute` 是**此刻**的速度，表盘用它，会立刻响应
    ///   新到的记录，也会在停手后自然衰减回零（"熄火"）。
    @Published private(set) var instantTokensPerMinute: Double = 0

    /// 近期观察到的最大**瞬时**速率，供自适应量程使用。
    ///
    /// 跟的必须是表盘所显示的那个量（瞬时速率），否则自适应量程的上限
    /// 与指针不是一回事。
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
    /// 表盘口径：瞬时速率的 EMA 状态。
    private var instantRate: InstantRateEMA
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
         instantRateTauSeconds: TimeInterval = defaultInstantRateTauSeconds,
         now: @escaping () -> Date = { Date() }) {
        self.window = UsageWindow(retentionHours: retentionHours)
        self.dailyWindow = UsageWindow(retentionHours: 25)
        self.pricing = pricing
        self.instantRate = InstantRateEMA(tau: instantRateTauSeconds)
        self.now = now
    }

    /// 用户在设置里改了时间常数：立即生效，当前读数保留。
    func setInstantRateTau(_ tau: TimeInterval) {
        instantRate.retune(tau: tau)
        recompute()
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
        // 去重后才喂给瞬时速率：Claude 把一次响应写成多行，实测约 56% 的行
        // 是重复的，全喂进去会把速率抬高一倍有余。
        //
        // 用 `insert` 的返回值而非再判一次键：窗口是去重语义的唯一权威。
        // （替换语义命中时会返回 true 而旧条目已计入，这点小重复无法从
        //  返回值里恢复；对一个只用于显示的瞬时读数可以接受。）
        let accepted = window.insert(entry)
        dailyWindow.insert(entry)
        guard accepted else { return }
        // 用 entry 自身的 timestamp 而非到达时间：回扫历史时若按到达时间，
        // 6 小时的数据会在一瞬间全部砸进 EMA，指针直接顶死。
        instantRate.ingest(tokens: Double(entry.counts.total), at: entry.timestamp)
    }

    /// 驱逐过期条目、重新分块、更新全部发布状态。
    func recompute() {
        let t = now()
        // 先衰减：无论后面走哪条分支（含 reset 早返回），峰值与瞬时速率
        // 都必须随时间回落
        decayPeak(to: t)
        instantRate.advance(to: t)
        instantTokensPerMinute = instantRate.value
        // 自适应量程跟随表盘所显示的量，即瞬时速率
        recentPeak = max(recentPeak, instantTokensPerMinute)

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

        // 以下四项是**未经任何加工的 ccusage 值**。曾经这里有一条
        // 「距末条 entry 超过 90 秒即归零」的补丁，实测在真实数据里每 13.6
        // 分钟触发一次、占块时长 11%，造成「满值 → 瞬间归零 → 弹回满值」
        // 的暴跳。熄火反馈现由表盘的瞬时速率 EMA 自然衰减提供，这里恢复
        // ccusage 的原生冻结语义。
        hasBurnRate = true
        tokensPerMinute = rate.tokensPerMinute
        indicatorTokensPerMinute = rate.tokensPerMinuteForIndicator
        level = BurnRateLevel.from(indicator: indicatorTokensPerMinute)
        costPerHour = rate.costPerHour
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

    /// 没有活跃块时清空 ccusage 口径的读数。
    /// **不碰 `instantTokensPerMinute`**——它由 EMA 独立驱动，已在
    /// `recompute()` 开头衰减过了。
    private func reset() {
        hasBurnRate = false
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
