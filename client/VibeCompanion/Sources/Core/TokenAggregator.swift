import Foundation

/// 维护 60s 滑动窗口，计算 tokens/min 与今日累计。
/// 速率用于驱动悬浮宠物窗动画速度。
@MainActor
final class TokenAggregator: ObservableObject {
    /// 当前 token/min（过去 60 秒总量，等价于 per-minute 速率）
    @Published private(set) var tokensPerMinute: Double = 0
    /// 今日累计 token
    @Published private(set) var todayTotal: Int = 0

    private struct Sample {
        let timestamp: Date
        let tokens: Int
    }
    private var window: [Sample] = []
    private let windowSeconds: TimeInterval

    init(windowSeconds: TimeInterval = AppConfig.rateWindowSeconds) {
        self.windowSeconds = windowSeconds
        // 每 2s 清理过期样本并重算
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evict() }
        }
    }

    /// 注入一条采集到的事件
    func ingest(_ event: UsageEvent) {
        let now = Date()
        window.append(Sample(timestamp: now, tokens: event.totalTokens))

        // 今日累计（按本地日期判断）
        if Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(event.recordedAt) / 1000)) {
            todayTotal += event.totalTokens
        }

        recompute(now: now)
    }

    private func evict() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        window.removeAll { $0.timestamp < cutoff }
        recompute(now: now)
    }

    private func recompute(now: Date) {
        // 窗口内的 token 总量即 tokens/min（窗口=60s）
        let sum = window.reduce(0) { $0 + $1.tokens }
        tokensPerMinute = Double(sum)
    }
}
