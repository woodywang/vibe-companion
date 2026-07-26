import SwiftUI
import AppKit

/// 应用根：菜单栏 + 悬浮宠物窗 + 后台采集协调
@main
struct VibeCompanionApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator, aggregator: coordinator.aggregator)
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
    lazy var aggregator = TokenAggregator(
        pricing: pricingStore,
        retentionHours: AppConfig.windowRetentionHours,
        instantRateTauSeconds: Settings.shared.instantRateTauSeconds)
    /// 展示层读数口径：摄入永不中断，暂停只冻结这里的快照。
    lazy var display = UsageDisplay(aggregator: aggregator, paused: isPaused)
    private(set) var collector: Collector?
    private var panel: FloatingPetPanel?

    /// 暂停只冻结显示，统计照常进行（持久化到 UserDefaults）。
    /// key 仍为 `vc.paused`，改名会丢用户已有设置。
    @Published var isPaused: Bool = Settings.shared.isPaused {
        didSet {
            Settings.shared.isPaused = isPaused
            display.setPaused(isPaused)
        }
    }

    /// 界面唯一的读数来源：暂停时是冻结快照，否则是聚合器实时值。
    var snapshot: UsageSnapshot { display.snapshot }

    /// 速度表量程，改动后悬浮窗立即重建以套用新刻度。
    /// （量程标识是在 `FloatingPetContent` 初始化时捕获的，不重建不生效。）
    @Published var gaugeScaleID: String = Settings.shared.gaugeScaleID {
        didSet {
            Settings.shared.gaugeScaleID = gaugeScaleID
            rebuildFloatingPanel()
        }
    }

    /// 瞬时速率的时间常数（秒）。
    ///
    /// 不必重建悬浮窗：τ 只存在于聚合器内部，改完立即 `recompute()`
    /// 重新发布读数，表盘作为 `@ObservedObject` 观察者自动跟着刷新。
    /// 重建反而会让窗口闪一下、还会丢掉用户拖过的位置。
    @Published var instantRateTauSeconds: TimeInterval = Settings.shared.instantRateTauSeconds {
        didSet {
            Settings.shared.instantRateTauSeconds = instantRateTauSeconds
            aggregator.setInstantRateTau(instantRateTauSeconds)
        }
    }

    init() {
        start()
    }

    private func start() {
        // 采集器 -> 聚合器
        let c = Collector(backfillWindowHours: AppConfig.backfillWindowHours)
        // 暂停期间同样摄入：丢弃会让活跃块永久缺条目，速率算错而非过时。
        c.onEntry = { [weak self] entry in
            Task { @MainActor in
                self?.display.ingest(entry)
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
            coordinator: self,
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
