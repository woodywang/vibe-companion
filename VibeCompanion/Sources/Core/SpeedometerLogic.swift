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
/// 阈值实测标定于瞬时速率在 10k–10M 对数量程下的分布：
/// 旧的 0.60 / 0.85 会让表盘 **46% 的时间是黄色**——黄色成了常态就不再
/// 传达任何信息。0.70 / 0.90 给出 绿 80% / 黄 18% / 红 1%，
/// 黄线约 1.26M、红线约 5.01M。
enum GaugeColorConfig {
    static let yellowFraction: Double = 0.70
    static let redFraction: Double = 0.90
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
///
/// 这里的小数位是**必要**的：LCD 是唯一能读出精确速率的地方，
/// 去掉小数就看不出读数在变。刻度标签另有 `gaugeTickLabel`。
func speedometerFormat(_ rpm: Double) -> String {
    if rpm < 1000 { return "\(Int(rpm))" }
    if rpm < 1_000_000 { return String(format: "%.1fk", rpm / 1000) }
    return String(format: "%.2fM", rpm / 1_000_000)
}

/// 刻度标签的**紧凑**格式：整数量级不带小数（`10k` / `1M`），
/// 非整数才带一位（`1.5M`）。
///
/// 为什么不复用 `speedometerFormat`：它固定 `%.1fk` / `%.2fM`，于是整数量级
/// 也被写成 `10.0k` / `1.00M`，白白多出 2–3 个字符。刻度是用 `.position()`
/// 摆在表盘上的——文本以点为中心向两侧展开，没有任何宽度约束——多出的字符
/// 直接造成叠字（实机截图出现过 `400.0k600.0k`）。本函数把宽度砍掉约一半，
/// 上限 4 个字符。
func gaugeTickLabel(_ value: Double) -> String {
    let v = max(value, 0)
    // 阈值取"四舍五入后会进位到下一个单位"的那个点，避免出现 `1000k`
    if v >= 999_950 { return compactMagnitude(v / 1_000_000, unit: "M") }
    if v >= 999.95 { return compactMagnitude(v / 1000, unit: "k") }
    return "\(Int(v.rounded()))"
}

/// 保留一位小数，整数则连小数点一起省掉。
private func compactMagnitude(_ v: Double, unit: String) -> String {
    let rounded = (v * 10).rounded() / 10
    if abs(rounded - rounded.rounded()) < 1e-9 {
        return "\(Int(rounded.rounded()))\(unit)"
    }
    return String(format: "%.1f%@", rounded, unit)
}

/// LCD 显示串。
///
/// `hasBurnRate == false` 表示活跃块只有一条 entry（ccusage 的
/// `duration <= 0` 守卫），此时**没有速率**，与"速率为 0"是两回事，
/// 故显示 `--`。
func speedometerDisplay(rpm: Double, hasBurnRate: Bool) -> String {
    hasBurnRate ? speedometerFormat(rpm) : "--"
}
