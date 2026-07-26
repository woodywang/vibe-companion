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
        // 表盘走**瞬时**速率：速度表本该显示当前速度，而不是 ccusage 的
        // 5 小时区块全程平均（那个值极其平稳，发出大 prompt 后指针纹丝不动）。
        // 菜单栏仍用 `snap.tokensPerMinute`，那才是与 ccusage 一致的口径。
        let snap = coordinator.snapshot
        let rpm = snap.instantTokensPerMinute
        let scale = gaugeScale(id: gaugeScaleID, recentPeak: snap.recentPeak)
        // 瞬时速率永远有定义，但衰减到 0 意味着"熄火"：与冷启动尚无数据
        // 一样显示 `--` 而非 `0`。这里**不能**用 `snap.hasBurnRate`——那是
        // ccusage 的 `duration <= 0` 守卫，会把"会话第一条记录"这种最该
        // 给出即时反馈的时刻压掉。
        let hasReading = rpm > 0

        VStack(spacing: 2) {
            SpeedometerView(tokensPerMinute: rpm,
                            hasBurnRate: hasReading,
                            scale: scale)
                .frame(width: 140, height: 140)

            // 速率小气泡（有读数时显示）
            if hasReading {
                Text(speedometerFormat(rpm))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(gaugeColor(tokensPerMinute: rpm,
                                           hasBurnRate: hasReading,
                                           scale: scale).opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(width: 160, height: 160)
    }
}
