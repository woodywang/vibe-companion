import SwiftUI
import AppKit

/// 悬浮宠物窗：透明、无标题栏、可拖动、置顶。
final class FloatingPetPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI 内容容器：根据速率选择状态并驱动动画
struct FloatingPetContent: View {
    @ObservedObject var aggregator: TokenAggregator

    var body: some View {
        let speed = AppConfig.animationSpeed(tokensPerMinute: aggregator.tokensPerMinute)
        let isIdle = aggregator.tokensPerMinute < 1

        VStack(spacing: 2) {
            if isIdle {
                // 打盹状态：静态 emoji 占位
                Text("😴")
                    .font(.system(size: 64))
            } else {
                CyclingPetView(speed: speed)
                    .frame(width: 140, height: 140)
            }

            // 速率小气泡
            if !isIdle {
                Text(formatRate(aggregator.tokensPerMinute))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(width: 160, height: 160)
    }

    private func formatRate(_ rpm: Double) -> String {
        if rpm < 1000 { return "\(Int(rpm))/min" }
        if rpm < 1_000_000 { return String(format: "%.1fk/min", rpm / 1000) }
        return String(format: "%.2fM/min", rpm / 1_000_000)
    }
}
