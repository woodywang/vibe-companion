import SwiftUI

/// 表盘配色的唯一来源：速度表指针 / LCD、菜单栏「当前速率」、悬浮速率气泡共用。
///
/// 三处必须同源，否则会出现指针已进黄区而菜单栏数字仍是另一种颜色的脱节。
func gaugeZoneColor(_ zone: GaugeZone) -> Color {
    switch zone {
    case .green: return Color(hex: 0x3D_D6_8C)
    case .yellow: return Color(hex: 0xE8_B3_39)
    case .red: return Color(hex: 0xE5_48_4D)
    }
}

/// 由速率与量程取色。
///
/// 分区一律走 `gaugeZone(value:scale:)`——它按**指针行程比例**（角度换算）
/// 判定，而非 `value / maxValue`；对数量程下两者差别极大。没有表盘几何的
/// 调用方（如菜单栏）同样用它，颜色才与指针位置一致。
///
/// `hasBurnRate == false`（显示 `--`，指针归零）时与 `SpeedometerView`
/// 一致地按绿区处理。
func gaugeColor(tokensPerMinute: Double, hasBurnRate: Bool, scale: GaugeScale) -> Color {
    gaugeZoneColor(hasBurnRate ? gaugeZone(value: tokensPerMinute, scale: scale) : .green)
}
