import SwiftUI
import AppKit

/// 菜单栏下拉内容
struct MenuBarContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 实时状态
            section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前速率").font(.caption).foregroundColor(.secondary)
                        Text(formatRate(coordinator.aggregator.tokensPerMinute))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text(petEmoji(coordinator.aggregator.tokensPerMinute))
                        .font(.system(size: 36))
                }
            }

            // 今日累计
            section {
                statRow(label: "今日累计", value: formatTokens(coordinator.aggregator.todayTotal))
                statRow(label: "待上传", value: "\(coordinator.pendingCount) 条")
                statRow(label: "上传状态", value: statusText(coordinator.uploadStatus))
            }

            Divider()

            // 注册状态
            if Settings.shared.isRegistered {
                Button("查看网站看板") {
                    if let url = URL(string: "\(Settings.shared.apiBase)/dashboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("查看全网排行") {
                    if let url = URL(string: "\(Settings.shared.apiBase)/leaderboard") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            // 暂停/恢复
            Button(Settings.shared.isPaused ? "▶ 恢复采集" : "⏸ 暂停采集") {
                Settings.shared.isPaused.toggle()
            }
            .keyboardShortcut("p")

            Button("⚙ 设置…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Divider()
            Button("退出 Vibe Companion") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced)).fontWeight(.medium)
        }
    }

    private func petEmoji(_ rpm: Double) -> String {
        switch rpm {
        case 0: return "😴"
        case ..<2000: return "🐢"
        case ..<10000: return "🐰"
        case ..<30000: return "🔥"
        default: return "🚀"
        }
    }

    private func formatRate(_ rpm: Double) -> String {
        if rpm < 1000 { return "\(Int(rpm)) /min" }
        return String(format: "%.1fk /min", rpm / 1000)
    }

    private func formatTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(format: "%.2fM", Double(n) / 1_000_000)
    }

    private func statusText(_ s: Uploader.Status) -> String {
        switch s {
        case .idle: return "空闲"
        case .uploading: return "上传中…"
        case .success(let n): return "已上传 \(n)"
        case .failed: return "上传失败"
        }
    }
}
