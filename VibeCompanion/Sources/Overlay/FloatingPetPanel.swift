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

/// SwiftUI 内容容器：速度表显示 token 消耗速率
struct FloatingPetContent: View {
    @ObservedObject var aggregator: TokenAggregator
    /// 用户选择的量程标识，随设置变化。
    let gaugeScaleID: String

    var body: some View {
        let rpm = aggregator.tokensPerMinute
        let scale = gaugeScale(id: gaugeScaleID, recentPeak: aggregator.recentPeak)

        VStack(spacing: 2) {
            SpeedometerView(tokensPerMinute: rpm,
                            hasBurnRate: aggregator.hasBurnRate,
                            scale: scale)
                .frame(width: 140, height: 140)

            // 速率小气泡（非 idle 且有速率时显示）
            if !aggregator.isIdle && aggregator.hasBurnRate {
                Text(speedometerFormat(rpm))
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
}
