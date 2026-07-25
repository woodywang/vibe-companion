import SwiftUI
import AppKit

/// 应用根：菜单栏 + 悬浮宠物窗 + 后台采集/上传协调
@main
struct VibeCompanionApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            // 菜单栏图标随速率变色
            Label {
                Text("Vibe Companion")
            } icon: {
                coordinator.menuBarIcon
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

/// 协调采集器、聚合器、上传器、悬浮窗的生命周期
@MainActor
final class AppCoordinator: ObservableObject {
    let aggregator = TokenAggregator()
    private(set) var collector: Collector?
    private(set) var uploader: Uploader?
    private var store: UsageStore?
    private var panel: FloatingPetPanel?

    @Published var uploadStatus: Uploader.Status = .idle
    @Published var pendingCount: Int = 0

    init() {
        start()
    }

    private func start() {
        // 初始化本地存储
        do {
            store = try UsageStore()
        } catch {
            NSLog("[VC] 初始化存储失败: \(error)")
            return
        }

        // 采集器 -> 聚合器 + 存储
        let c = Collector()
        c.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.aggregator.ingest(event)
                try? self?.store?.enqueue(event)
                self?.pendingCount = (try? self?.store?.pendingCount()) ?? self?.pendingCount ?? 0
            }
        }
        c.start()
        collector = c

        // 上传器
        let u = Uploader(store: store!)
        u.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.uploadStatus = status
                self?.pendingCount = (try? self?.store?.pendingCount()) ?? self?.pendingCount ?? 0
            }
        }
        u.start()
        uploader = u

        // 悬浮宠物窗
        showFloatingPanel()

        // 定时刷新待上传计数
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pendingCount = (try? self?.store?.pendingCount()) ?? self?.pendingCount ?? 0
            }
        }
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

    /// 保存新 token 后调用：解除认证阻断并恢复自动上传（重启计时器 + 立即触发一次 flush）。
    func resumeUploads() {
        uploader?.resetAuthBlock()
        uploader?.start()
    }

    /// 菜单栏图标：随速率档位变化
    var menuBarIcon: Image {
        switch aggregator.tokensPerMinute {
        case 0: return Image(systemName: "moon.zzz")
        case ..<2000: return Image(systemName: "tortoise")
        case ..<10000: return Image(systemName: "bicycle")
        case ..<30000: return Image(systemName: "flame")
        default: return Image(systemName: "bolt.fill")
        }
    }
}
