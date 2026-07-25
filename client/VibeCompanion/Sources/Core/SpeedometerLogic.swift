import Foundation

/// 速度表常量与映射逻辑（纯函数，无 UI 依赖，便于单测）。
/// 角度约定：-135°（最左，0 tok/min）-> +135°（最右，500k tok/min），线性映射。
enum SpeedometerConfig {
    static let angleMin: Double = -135.0
    static let angleMax: Double = 135.0
    static let valueMax: Double = 500_000.0   // 量程上限 tok/min
    static let idleThreshold: Double = 1.0     // tok/min 低于此值视为 idle
}

/// token/min -> 指针角度（度），clamp 在 [-135, 135]。
func speedometerAngle(tokensPerMinute: Double) -> Double {
    let raw = SpeedometerConfig.angleMin
        + (tokensPerMinute / SpeedometerConfig.valueMax)
            * (SpeedometerConfig.angleMax - SpeedometerConfig.angleMin)
    return min(max(raw, SpeedometerConfig.angleMin), SpeedometerConfig.angleMax)
}

/// 是否处于 idle 状态（无 token 消耗）。
func speedometerIsIdle(tokensPerMinute: Double) -> Bool {
    tokensPerMinute < SpeedometerConfig.idleThreshold
}

/// LCD 数字窗格式化。口径与 FloatingPetContent.formatRate 一致：
/// <1000 整数；<1_000_000 "%.1fk"；否则 "%.2fM"。
func speedometerFormat(_ rpm: Double) -> String {
    if rpm < 1000 { return "\(Int(rpm))" }
    if rpm < 1_000_000 { return String(format: "%.1fk", rpm / 1000) }
    return String(format: "%.2fM", rpm / 1_000_000)
}
