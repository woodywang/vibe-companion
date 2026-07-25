import SwiftUI
import AppKit

/// ccusage 的档位文字。阈值 2000/5000 作用于 tokensPerMinuteForIndicator。
///
/// 本项目把它降级为菜单栏文字（偏离 D3）：表盘配色改由 Total 速率驱动，
/// 以满足"颜色和角度保持一致"。
func burnRateLevelLabel(_ level: BurnRateLevel) -> String {
    switch level {
    case .normal: return "Normal"
    case .moderate: return "Moderate"
    case .high: return "High"
    }
}

func formatCostPerHour(_ cost: Double?) -> String {
    guard let cost else { return "--" }
    return String(format: "$%.2f/h", cost)
}

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
                        Text(speedometerDisplay(rpm: coordinator.aggregator.tokensPerMinute,
                                                hasBurnRate: coordinator.aggregator.hasBurnRate))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text(petEmoji(coordinator.aggregator.level))
                        .font(.system(size: 36))
                }
            }

            // ccusage 档位（依据 input+output 速率，与表盘配色口径不同）
            section {
                statRow(label: "档位",
                        value: "\(burnRateLevelLabel(coordinator.aggregator.level))"
                             + "  (\(speedometerFormat(coordinator.aggregator.indicatorTokensPerMinute))/min)")
            }

            // 估算花费
            section {
                statRow(label: "估算花费",
                        value: formatCostPerHour(coordinator.aggregator.costPerHour))
            }

            // 今日累计
            section {
                statRow(label: "今日累计", value: formatTokens(coordinator.aggregator.todayTotal))
            }

            Divider()

            // 暂停/恢复
            Button(coordinator.isPaused ? "▶ 恢复采集" : "⏸ 暂停采集") {
                coordinator.isPaused.toggle()
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

    /// 按 ccusage 档位取表情。
    /// 原实现按 effectiveTokens 口径写死 2000/10000/30000，改用 Total 后已失效。
    private func petEmoji(_ level: BurnRateLevel) -> String {
        guard !coordinator.aggregator.isIdle, coordinator.aggregator.hasBurnRate else { return "😴" }
        switch level {
        case .normal: return "🐢"
        case .moderate: return "🐰"
        case .high: return "🚀"
        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(format: "%.2fM", Double(n) / 1_000_000)
    }
}
