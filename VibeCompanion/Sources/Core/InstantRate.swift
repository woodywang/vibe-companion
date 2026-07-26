import Foundation

/// 瞬时消耗速率：对 token 记录做**时间衰减 EMA**，单位 tok/min。
///
/// 为什么需要它：ccusage 的区块速率是「块内 token 总量 ÷（末条 − 首条）」的
/// **全程平均**，实测极其平稳（块启动 5 分钟后相邻更新中位跳变 0.04%）。
/// 作为账单口径这是对的，但速度表该显示的是**当前速度**——用户刚发出一个
/// 大 prompt，指针必须动。两者是不同的量，故分家：表盘走本类型，
/// 菜单栏继续走 ccusage 区块模型。
///
/// 算法与 Unix load average 同款，只是单位直接取 tok/min：
/// - 距上次更新经过 Δt 秒时先衰减：`value *= exp(-Δt / τ)`
/// - 摄入一条 token 数为 `v` 的记录：`value += v / τ * 60`
///
/// 稳态性质（正确性判据）：以恒定流量 F tok/min 持续喂入，`value` 收敛到 F。
/// 连续形式下 `dV/dt = (60·r(t) − V) / τ`，r 恒定时不动点即 `V = 60·r`。
///
/// **不取系统时间**：所有需要"现在"的地方由调用方以 `Date` 传入，
/// 与 `Core/` 的既有约定一致（无 I/O、可纯函数测试）。
struct InstantRateEMA {

    /// 时间常数（秒）。越小越跳、反馈越快；越大越稳、响应越慢。
    /// 由外部注入——它是用户可调的设置项，不是算法常量。
    private(set) var tau: TimeInterval

    /// 当前瞬时速率，tok/min。
    private(set) var value: Double = 0

    /// 上次推进到的时刻。nil 表示还没见过任何时间点。
    private var lastUpdate: Date?

    /// 低于此值直接归零（tok/min）。
    ///
    /// 指数衰减永远不到 0，不截断就会留一条无限长的尾巴：指针永远悬在
    /// 起点上方一丝，LCD 也永远不肯显示"熄火"。1 tok/min 在任何量程下都
    /// 不可见，从 200k 衰到这里约 `ln(200000)·τ`（τ=30 秒时约 6 分钟），
    /// 正好承担了原先「90 秒空闲归零」那个补丁想要的熄火反馈——
    /// 区别是这里是平滑衰减，不会出现「满值 → 瞬间归零 → 弹回满值」的暴跳。
    private static let floor: Double = 1

    init(tau: TimeInterval) {
        precondition(tau > 0, "时间常数必须为正")
        self.tau = tau
    }

    /// 把状态推进到 `t`：只衰减，不注入。
    ///
    /// `dt <= 0` 时**不动**（既不衰减也不回退时钟）。回扫历史与乱序到达都会
    /// 产生倒退的时间戳，让时钟倒走会把已衰减掉的时间重新算一遍。
    mutating func advance(to t: Date) {
        guard let last = lastUpdate else {
            lastUpdate = t
            return
        }
        let dt = t.timeIntervalSince(last)
        guard dt > 0 else { return }
        lastUpdate = t
        guard value > 0 else { return }
        let decayed = value * exp(-dt / tau)
        value = decayed < Self.floor ? 0 : decayed
    }

    /// 摄入一条 token 数为 `tokens`、时间戳为 `t` 的记录。
    ///
    /// 先把时钟推进到 `t` 再注入，于是「衰减发生在哪一刻」是确定的，
    /// 与调用方多久 tick 一次无关——不存在时序偏差。
    mutating func ingest(tokens: Double, at t: Date) {
        advance(to: t)
        guard tokens > 0 else { return }
        value += tokens / tau * 60
    }

    /// 更改时间常数，保留当前读数与时钟。
    ///
    /// `value` 是一个速率估计而非内部累加器，换时间常数只应改变今后的
    /// 响应快慢；把它清零会让用户一改设置指针就掉到底。
    mutating func retune(tau newTau: TimeInterval) {
        precondition(newTau > 0, "时间常数必须为正")
        tau = newTau
    }
}

/// 可选的时间常数档位（秒），顺序即设置界面的展示顺序。
let allInstantRateTauSeconds: [TimeInterval] = [15, 30, 60, 120]

/// 默认时间常数（秒）。
///
/// 实测（真实数据）：τ=30 秒相邻更新中位跳变 6.4%、响应到 90% 约 69 秒；
/// τ=60 秒中位跳变 3.3%、响应约 138 秒。30 秒在"看得出在动"与
/// "不至于抽搐"之间。
let defaultInstantRateTauSeconds: TimeInterval = 30

/// 档位的界面文案。
func instantRateTauLabel(_ tau: TimeInterval) -> String {
    switch tau {
    case 15:  return "15 秒 · 最灵敏"
    case 30:  return "30 秒 · 默认"
    case 60:  return "60 秒 · 平稳"
    case 120: return "120 秒 · 最平稳"
    default:  return "\(Int(tau)) 秒"
    }
}
