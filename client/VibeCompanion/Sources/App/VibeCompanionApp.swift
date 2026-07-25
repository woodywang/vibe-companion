import SwiftUI
import AppKit

/// 应用根：菜单栏 + 悬浮宠物窗 + 后台采集协调
@main
struct VibeCompanionApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            // 固定图标：速率变化由悬浮速度表呈现，菜单栏保持安静
            Label {
                Text("Vibe Companion")
            } icon: {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
        }
        .menuBarExtraStyle(.window)

        // 设置窗口
        WindowGroup("设置") {
            SettingsView(coordinator: coordinator)
        }
        .defaultSize(width: 480, height: 520)
    }
}

/// 协调采集器、聚合器、悬浮窗的生命周期
@MainActor
final class AppCoordinator: ObservableObject {
    let pricingStore = PricingStore(builtinSnapshot: loadBuiltinPricingSnapshot(),
                                    cache: FilePricingCache(),
                                    fetcher: URLSessionPricingFetcher())
    lazy var aggregator = TokenAggregator(pricing: pricingStore,
                                          retentionHours: AppConfig.windowRetentionHours,
                                          idleTimeoutSeconds: AppConfig.idleTimeoutSeconds)
    private(set) var collector: Collector?
    private var panel: FloatingPetPanel?

    /// 暂停后不再把新事件喂给聚合器（持久化到 UserDefaults）
    @Published var isPaused: Bool = Settings.shared.isPaused {
        didSet { Settings.shared.isPaused = isPaused }
    }

    /// 速度表量程，改动后悬浮窗立即重建以套用新刻度。
    @Published var gaugeScaleID: String = Settings.shared.gaugeScaleID {
        didSet {
            Settings.shared.gaugeScaleID = gaugeScaleID
            rebuildFloatingPanel()
        }
    }

    init() {
        start()
    }

    private func start() {
        // 采集器 -> 聚合器
        let c = Collector(backfillWindowHours: AppConfig.backfillWindowHours)
        c.onEntry = { [weak self] entry in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.aggregator.ingest(entry)
            }
        }
        c.start()
        collector = c

        aggregator.startTicking(interval: AppConfig.recomputeIntervalSeconds)
        // 定价异步刷新，失败不影响速率显示
        Task { await pricingStore.refresh() }

        // 悬浮宠物窗
        showFloatingPanel()
    }

    private func showFloatingPanel() {
        let p = FloatingPetPanel()
        let hosting = NSHostingView(rootView: FloatingPetContent(
            aggregator: aggregator,
            gaugeScaleID: gaugeScaleID))
        p.contentView = hosting
        p.center()
        // 记忆上次位置（简化：默认右上角）。
        // 无活动显示器时（合盖 / 无头 / 全部睡眠）`NSScreen.main` 为 nil，
        // 强解包会直接 trap；退一步用任一已连接屏幕，再没有就保持 center() 的结果。
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            p.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 200, y: frame.maxY - 200))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func rebuildFloatingPanel() {
        panel?.close()
        panel = nil
        showFloatingPanel()
    }
}
