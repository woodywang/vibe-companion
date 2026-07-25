import Foundation

/// 表盘配色分区。
enum GaugeZone: Equatable {
    case green, yellow, red
}

/// 配色阈值，定义为**当前量程的比例**而非绝对速率值。
///
/// 这样红线永远落在表盘末段（与真实机械速度表一致），
/// 且用户切换任何 `GaugeScale` 都无需重新标定。
///
/// 注意：配色与指针角度同源，都由 `tokensPerMinute`（Total）驱动。
/// ccusage 用 `tokensPerMinuteForIndicator` 驱动其 Normal/Moderate/High
/// 徽章，那会导致指针指在低位却显红色；本项目把 indicator 降级为
/// 菜单栏文字（偏离 D3）。
enum GaugeColorConfig {
    static let yellowFraction: Double = 0.60
    static let redFraction: Double = 0.85
}

/// 指针在表盘上已走过的行程比例，0 = 最左，1 = 最右。
func gaugeSweepFraction(value: Double, scale: GaugeScale) -> Double {
    (scale.angle(for: value) - GaugeGeometry.angleMin) / GaugeGeometry.sweep
}

/// 按**指针行程比例**判定配色分区。
///
/// 关键：分母是角度行程而非 `value / maxValue`。对数量程下两者不同——
/// 100k 在 10k–1M 的对数表盘上指针正指中间（行程 50%），而数值比例只有
/// 10%。若按数值比例配色，指针指在中间却显示绿色，颜色与角度就脱节了。
/// 用行程比例可保证任何 `GaugeScale` 下颜色与指针位置始终一致。
func gaugeZone(value: Double, scale: GaugeScale) -> GaugeZone {
    let fraction = gaugeSweepFraction(value: value, scale: scale)
    if fraction >= GaugeColorConfig.redFraction { return .red }
    if fraction >= GaugeColorConfig.yellowFraction { return .yellow }
    return .green
}

/// LCD 数字窗格式化：<1000 整数；<1_000_000 "%.1fk"；否则 "%.2fM"。
func speedometerFormat(_ rpm: Double) -> String {
    if rpm < 1000 { return "\(Int(rpm))" }
    if rpm < 1_000_000 { return String(format: "%.1fk", rpm / 1000) }
    return String(format: "%.2fM", rpm / 1_000_000)
}

/// LCD 显示串。
///
/// `hasBurnRate == false` 表示活跃块只有一条 entry（ccusage 的
/// `duration <= 0` 守卫），此时**没有速率**，与"速率为 0"是两回事，
/// 故显示 `--`。
func speedometerDisplay(rpm: Double, hasBurnRate: Bool) -> String {
    hasBurnRate ? speedometerFormat(rpm) : "--"
}
