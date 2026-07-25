import Foundation

/// 表盘几何常量。
enum GaugeGeometry {
    static let angleMin: Double = -135   // 最左
    static let angleMax: Double = 135    // 最右
    static var sweep: Double { angleMax - angleMin }
}

/// 速度表量程。
///
/// 实测真实速率跨度近 20 倍（41k – 760k tok/min），没有单一量程能兼顾
/// 低速分辨率与高速不溢出，故做成可插拔、由用户在设置中选择。
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
struct LinearGaugeScale: GaugeScale {
    let id = "linear"
    let displayName = "线性 (0 – 1M)"
    let maxValue: Double

    init(maxValue: Double = 1_000_000) {
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

/// 对数量程：低速区与高速区都有分辨率，适合 20 倍跨度。
struct LogGaugeScale: GaugeScale {
    let id = "log"
    let displayName = "对数 (10k – 1M)"
    let minValue: Double
    let maxValue: Double

    init(minValue: Double = 10_000, maxValue: Double = 1_000_000) {
        self.minValue = minValue
        self.maxValue = maxValue
    }

    var majorTicks: [Double] {
        // 等比排列：10k / 31.6k / 100k / 316k / 1M
        let decades = log10(maxValue / minValue)
        return (0...4).map { minValue * pow(10, decades * Double($0) / 4) }
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
    init(recentPeak: Double) {
        self.maxValue = max(recentPeak * 1.2, 100_000)
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
