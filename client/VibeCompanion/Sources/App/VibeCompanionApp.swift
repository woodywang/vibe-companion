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
    let aggregator = TokenAggregator()
    private(set) var collector: Collector?
    private var panel: FloatingPetPanel?

    /// 暂停后不再把新事件喂给聚合器（持久化到 UserDefaults）
    @Published var isPaused: Bool = Settings.shared.isPaused {
        didSet { Settings.shared.isPaused = isPaused }
    }

    init() {
        start()
    }

    private func start() {
        // 采集器 -> 聚合器
        let c = Collector()
        c.onEntry = { [weak self] entry in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.aggregator.ingest(entry)
            }
        }
        c.start()
        collector = c

        // 悬浮宠物窗
        showFloatingPanel()
    }

    private func showFloatingPanel() {
        let p = FloatingPetPanel()
        let hosting = NSHostingView(rootView: FloatingPetContent(aggregator: aggregator))
        p.contentView = hosting
        p.center()
        // 记忆上次位置（简化：默认右上角）
        p.setFrameTopLeftPoint(NSPoint(x: NSScreen.main!.frame.maxX - 200, y: NSScreen.main!.frame.maxY - 200))
        p.orderFrontRegardless()
        panel = p
    }
}
