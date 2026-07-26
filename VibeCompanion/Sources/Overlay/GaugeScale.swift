import Foundation

/// 表盘几何常量。
enum GaugeGeometry {
    static let angleMin: Double = -135   // 最左
    static let angleMax: Double = 135    // 最右
    static var sweep: Double { angleMax - angleMin }
}

/// 速度表量程。
///
/// 实测**瞬时**速率跨三个数量级（中位 613k、p90 1.71M、p99 6.02M、峰值 8.35M；
/// 停留分布：100k–1M 占 58.2%、1M–10M 占 28.2%、10k–100k 占 8.6%、
/// 1 万以下 5.1%）。没有单一量程能兼顾低速分辨率与高速不溢出，
/// 故做成可插拔、由用户在设置中选择。
///
/// 算法层不认识本协议——`tokensPerMinute` 是纯数值，量程纯属展示决策。
protocol GaugeScale {
    /// 持久化标识。
    var id: String { get }
    var displayName: String { get }
    /// 需要绘制数字的刻度值。
    var majorTicks: [Double] { get }
    /// 量程上限，也是配色比例的分母。
    var maxValue: Double { get }
    /// 映射到指针角度，clamp 在 [angleMin, angleMax]。
    func angle(for value: Double) -> Double
}

private func clampAngle(_ a: Double) -> Double {
    min(max(a, GaugeGeometry.angleMin), GaugeGeometry.angleMax)
}

/// 线性量程：指针位置与数值成正比，最符合直觉。
///
/// 上限必须覆盖实测峰值（8.35M），否则用户选它会直接顶死。
/// 代价是中位速率（613k）只占 6.1% 行程，指针几乎贴底——这正是
/// 默认量程改为对数的原因。
struct LinearGaugeScale: GaugeScale {
    let id = "linear"
    let displayName = "线性 (0 – 10M)"
    let maxValue: Double

    init(maxValue: Double = 10_000_000) {
        self.maxValue = maxValue
    }

    var majorTicks: [Double] {
        stride(from: 0, through: maxValue, by: maxValue / 5).map { $0 }
    }

    func angle(for value: Double) -> Double {
        guard maxValue > 0 else { return GaugeGeometry.angleMin }
        return clampAngle(GaugeGeometry.angleMin + (value / maxValue) * GaugeGeometry.sweep)
    }
}

/// 对数量程：整个三数量级跨度上都有分辨率，是默认量程。
///
/// 为什么默认取它：中位瞬时速率 613k 在线性 0–8.4M 上只占 7.3% 行程
/// （指针贴底、看不出变化），在对数 10k–10M 上占 59.6%。
struct LogGaugeScale: GaugeScale {
    let id = "log"
    let displayName = "对数 (10k – 10M)"
    let minValue: Double
    let maxValue: Double

    init(minValue: Double = 10_000, maxValue: Double = 10_000_000) {
        self.minValue = minValue
        self.maxValue = maxValue
    }

    /// 按**整数量级**排列：10k / 100k / 1M / 10M。
    ///
    /// 旧实现把跨度等分成 4 段，得到 10k / 31.6k / 100k / 316k / 1M——
    /// 数学上均匀，但 `31.6k` 这种数字读者没法在脑子里定位。
    var majorTicks: [Double] {
        guard maxValue > minValue, minValue > 0 else { return [minValue] }
        var ticks: [Double] = []
        var v = minValue
        while v <= maxValue * (1 + 1e-9) {
            ticks.append(min(v, maxValue))
            v *= 10
        }
        return ticks
    }

    /// 对数在 0 处无定义，故 `value <= minValue` 一律指向起点。
    func angle(for value: Double) -> Double {
        guard value > minValue, maxValue > minValue else { return GaugeGeometry.angleMin }
        let fraction = log10(value / minValue) / log10(maxValue / minValue)
        return clampAngle(GaugeGeometry.angleMin + fraction * GaugeGeometry.sweep)
    }
}

/// 自适应量程：跟随近期峰值，永不溢出。
/// 代价是刻度会跳变，用户失去绝对参系。
struct AdaptiveGaugeScale: GaugeScale {
    let id = "adaptive"
    let displayName = "自适应"
    let maxValue: Double

    /// 下界 100k，避免刚启动峰值为 0 时刻度荒谬。
    ///
    /// 上限再向上取整到"整齐"的值：直接用 `recentPeak * 1.2` 会让四等分
    /// 落在 `360.0k` / `720.0k` / `1.08M` 这种位置——既长又没法读。
    init(recentPeak: Double) {
        self.maxValue = Self.niceMax(atLeast: max(recentPeak * 1.2, 100_000))
    }

    /// 取最小的 `4q`，使 `q ∈ {1, 2, 2.5, 5} × 10ⁿ` 且 `4q >= target`。
    ///
    /// 于是四等分的每个刻度都是 q 的整数倍，标签落在圆整数字上
    /// （如 q=500k → 500k / 1M / 1.5M / 2M）。
    /// 2.5 留在集合里是为了 100k 下界能精确落回 100k（q=25k）。
    static func niceMax(atLeast target: Double) -> Double {
        guard target > 0 else { return 0 }
        let quarter = target / 4
        let decade = pow(10, floor(log10(quarter)))
        for mantissa in [1.0, 2.0, 2.5, 5.0, 10.0] where mantissa * decade >= quarter * (1 - 1e-9) {
            return mantissa * decade * 4
        }
        return decade * 40
    }

    var majorTicks: [Double] {
        stride(from: 0, through: maxValue, by: maxValue / 4).map { $0 }
    }

    func angle(for value: Double) -> Double {
        guard maxValue > 0 else { return GaugeGeometry.angleMin }
        return clampAngle(GaugeGeometry.angleMin + (value / maxValue) * GaugeGeometry.sweep)
    }
}

/// 全部可选量程的标识，顺序即设置界面的展示顺序。
let allGaugeScaleIDs = ["linear", "log", "adaptive"]

/// 按标识构造量程。未知标识回退到线性。
func gaugeScale(id: String, recentPeak: Double) -> GaugeScale {
    switch id {
    case "log": return LogGaugeScale()
    case "adaptive": return AdaptiveGaugeScale(recentPeak: recentPeak)
    default: return LinearGaugeScale()
    }
}
