import SwiftUI

enum CyclingPet {
    /// 轮子每秒圈数：由速率映射后的 speed (AppConfig.animationSpeed 输出, [0.25,4.0]) 决定。
    /// speed 1.0 -> 1 圈/秒，线性缩放并夹在 [0.25, 4.0]。
    static func revolutionsPerSecond(speed: Double) -> Double {
        min(max(speed, 0.25), 4.0)
    }
}

/// 纯 SwiftUI 绘制的蹬车宠物：轮子随 speed 越快转越快。
struct CyclingPetView: View {
    let speed: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rps = CyclingPet.revolutionsPerSecond(speed: speed)
            let angle = t * rps * 2 * .pi
            Canvas { ctx, size in
                CyclingPetView.draw(&ctx, size: size, wheelAngle: angle)
            }
        }
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, wheelAngle: Double) {
        let w = size.width, h = size.height
        let wheelR = w * 0.16
        let axleY = h * 0.66
        let leftC = CGPoint(x: w * 0.30, y: axleY)
        let rightC = CGPoint(x: w * 0.70, y: axleY)
        let frameShade = GraphicsContext.Shading.color(.orange)
        let wheelShade = GraphicsContext.Shading.color(Color(white: 0.25))

        // wheels + spinning spokes
        for c in [leftC, rightC] {
            let rim = Path(ellipseIn: CGRect(x: c.x - wheelR, y: c.y - wheelR,
                                             width: wheelR * 2, height: wheelR * 2))
            ctx.stroke(rim, with: wheelShade, lineWidth: 3)
            var spokes = Path()
            for k in 0..<4 {
                let a = wheelAngle + Double(k) * (.pi / 4)
                spokes.move(to: c)
                spokes.addLine(to: CGPoint(x: c.x + cos(a) * wheelR, y: c.y + sin(a) * wheelR))
            }
            ctx.stroke(spokes, with: wheelShade, lineWidth: 1)
        }

        // frame
        let saddle = CGPoint(x: w * 0.5, y: h * 0.42)
        var frame = Path()
        frame.move(to: leftC); frame.addLine(to: saddle); frame.addLine(to: rightC)
        frame.move(to: saddle); frame.addLine(to: CGPoint(x: w * 0.5, y: axleY)); frame.addLine(to: leftC)
        ctx.stroke(frame, with: frameShade, lineWidth: 3)

        // rider (head bobs with pedaling)
        let bob = sin(wheelAngle) * 2
        let head = CGPoint(x: w * 0.5, y: h * 0.30 + bob)
        let headR = w * 0.07
        ctx.fill(Path(ellipseIn: CGRect(x: head.x - headR, y: head.y - headR,
                                        width: headR * 2, height: headR * 2)), with: frameShade)
        var torso = Path()
        torso.move(to: CGPoint(x: head.x, y: head.y + headR)); torso.addLine(to: saddle)
        ctx.stroke(torso, with: frameShade, lineWidth: 3)
    }
}
