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
    /// 读数来源（暂停时为冻结快照）。
    @ObservedObject var coordinator: AppCoordinator
    /// 只用于触发重绘：聚合器每次 recompute 都会发布变更。
    @ObservedObject var aggregator: TokenAggregator
    /// 用户选择的量程标识，随设置变化。
    let gaugeScaleID: String

    var body: some View {
        let snap = coordinator.snapshot
        let rpm = snap.tokensPerMinute
        let scale = gaugeScale(id: gaugeScaleID, recentPeak: snap.recentPeak)

        VStack(spacing: 2) {
            SpeedometerView(tokensPerMinute: rpm,
                            hasBurnRate: snap.hasBurnRate,
                            scale: scale)
                .frame(width: 140, height: 140)

            // 速率小气泡（非 idle 且有速率时显示）
            if !snap.isIdle && snap.hasBurnRate {
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
