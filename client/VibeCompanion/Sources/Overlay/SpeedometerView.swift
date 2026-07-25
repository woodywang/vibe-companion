import SwiftUI

/// 老式汽车速度表：圆形表盘 + 白刻度/数字 + 红指针 + 红线区 + LCD 数字窗。
/// 指针角度 = speedometerAngle(tokensPerMinute:)，弹簧动画带过冲回摆。
struct SpeedometerView: View {
    let tokensPerMinute: Double

    // 表盘几何（在 1.0 基准坐标系内，整体放进 140×140 frame）
    private let size: CGFloat = 140
    private let center = CGPoint(x: 100, y: 100)
    private let rimRadius: CGFloat = 96
    private let dialRadius: CGFloat = 82
    private let redlineStart: Double = 400_000  // 红线区起点 tok/min
    private let majorValues: [Double] = [0, 100_000, 200_000, 300_000, 400_000, 500_000]

    var body: some View {
        let angle = speedometerAngle(tokensPerMinute: tokensPerMinute)
        let display = speedometerFormat(tokensPerMinute)

        ZStack {
            dialBackground
            redlineArc
            ticks
            numbers
            lcdWindow(display)
            needle(angle)
            centerCap
        }
        .frame(width: 200, height: 200)     // 与几何坐标系一致，内容自然居中
        .scaleEffect(size / 200)            // 缩放到 140
        .frame(width: size, height: size)   // 撑住布局尺寸
    }

    // MARK: - 部件

    private var dialBackground: some View {
        ZStack {
            // 金属外环
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xE8_EA_EE), Color(hex: 0x9A_A0_A8), Color(hex: 0x5B_60_68)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: rimRadius * 2, height: rimRadius * 2)
            // 表盘黑底
            Circle()
                .fill(Color(hex: 0x0C_0D_10))
                .frame(width: (rimRadius - 8) * 2, height: (rimRadius - 8) * 2)
            // 表盘径向渐变
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x33_36_3C), Color(hex: 0x17_19_1D)],
                        center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: dialRadius
                    )
                )
                .frame(width: dialRadius * 2, height: dialRadius * 2)
        }
    }

    private var redlineArc: some View {
        // 400k -> 500k（量程上限）红色弧段
        let start = Angle.degrees(speedometerAngle(tokensPerMinute: redlineStart) - 90)
        let end = Angle.degrees(speedometerAngle(tokensPerMinute: SpeedometerConfig.valueMax) - 90)
        return ArcShape(center: center, radius: 74, start: start, end: end)
            .stroke(Color(hex: 0xE5_48_4D), style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }

    private var ticks: some View {
        // 每 50k 一根刻度，0..500k 共 11 根
        let stepCount = Int(SpeedometerConfig.valueMax / 50_000)   // 10
        return ZStack {
            ForEach(0...stepCount, id: \.self) { i in
                let value = Double(i) * 50_000
                let isMajor = majorValues.contains(value)
                let ang = speedometerAngle(tokensPerMinute: value)
                TickShape(
                    center: center,
                    innerRadius: isMajor ? 60 : 72,
                    outerRadius: 78,
                    angle: Angle.degrees(ang)
                )
                .stroke(Color.white.opacity(isMajor ? 1.0 : 0.55),
                        style: StrokeStyle(lineWidth: isMajor ? 4 : 1.5, lineCap: .round))
            }
        }
    }

    private var numbers: some View {
        ZStack {
            ForEach(majorValues, id: \.self) { value in
                let ang = speedometerAngle(tokensPerMinute: value)
                let pos = polarPoint(center: center, radius: 50, angleDeg: ang)
                Text(formatScale(value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .position(x: pos.x, y: pos.y)
            }
        }
    }

    private func lcdWindow(_ display: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: 0x0A_0C_0E))
                .frame(width: 54, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(hex: 0x3A_3D_42), lineWidth: 1)
                )
            Text(display)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: 0x7E_F0_C1))
        }
        .position(x: center.x, y: center.y + 49)
    }

    private func needle(_ angle: Double) -> some View {
        NeedleShape()
            .fill(Color(hex: 0xE5_48_4D))
            .frame(width: 6, height: 72)
            .offset(y: -24)   // 针尖向上，中心在表盘中心
            .rotationEffect(.degrees(angle), anchor: .center)
            .position(x: center.x, y: center.y)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: angle)
    }

    private var centerCap: some View {
        ZStack {
            Circle().fill(Color(hex: 0xC7_CC_D4))
                .frame(width: 16, height: 16)
            Circle().fill(Color(hex: 0x3A_3D_42))
                .frame(width: 6, height: 6)
        }
        .position(x: center.x, y: center.y)
    }

    // MARK: - helpers

    /// 极坐标转直角（角度：0° = 正上，顺时针为正，与 speedometerAngle 约定一致）。
    private func polarPoint(center: CGPoint, radius: CGFloat, angleDeg: Double) -> CGPoint {
        let a = (angleDeg - 90) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(a)),
                       y: center.y + radius * CGFloat(sin(a)))
    }

    private func formatScale(_ v: Double) -> String {
        if v >= 1000 { return "\(Int(v / 1000))k" }
        return "\(Int(v))"
    }
}

// MARK: - Shapes

/// 弧形（指定起止角度）。
struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat
    let start: Angle
    let end: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: center, radius: radius,
                 startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

/// 单根刻度线（从 innerRadius 到 outerRadius，绕 angle 旋转）。
struct TickShape: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let angle: Angle
    func path(in rect: CGRect) -> Path {
        let a = (angle.degrees - 90) * .pi / 180
        let inner = CGPoint(x: center.x + innerRadius * CGFloat(cos(a)),
                            y: center.y + innerRadius * CGFloat(sin(a)))
        let outer = CGPoint(x: center.x + outerRadius * CGFloat(cos(a)),
                            y: center.y + outerRadius * CGFloat(sin(a)))
        var p = Path()
        p.move(to: inner); p.addLine(to: outer)
        return p
    }
}

/// 指针（三角形：针尖向上，尾部向下短）。
struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        // rect 为 6×72：针尖在顶部中点，底部两侧为尾
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))              // 尖
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))          // 右下
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))           // 左下
        p.closeSubpath()
        return p
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
