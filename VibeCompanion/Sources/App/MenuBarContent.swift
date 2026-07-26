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
    /// 只用于触发重绘：读数一律走 `coordinator.snapshot`，暂停时它是冻结快照。
    @ObservedObject var aggregator: TokenAggregator

    var body: some View {
        let snap = coordinator.snapshot
        // 菜单栏没有表盘几何，但配色必须与指针位置一致：同样用当前量程 + gaugeZone。
        let scale = gaugeScale(id: coordinator.gaugeScaleID, recentPeak: snap.recentPeak)

        return VStack(alignment: .leading, spacing: 8) {
            // 实时状态
            section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前速率").font(.caption).foregroundColor(.secondary)
                        Text(speedometerDisplay(rpm: snap.tokensPerMinute,
                                                hasBurnRate: snap.hasBurnRate))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(gaugeColor(tokensPerMinute: snap.tokensPerMinute,
                                                        hasBurnRate: snap.hasBurnRate,
                                                        scale: scale))
                    }
                    Spacer()
                    Text(petEmoji(snap))
                        .font(.system(size: 36))
                }
            }

            // ccusage 档位（依据 input+output 速率，与表盘配色口径不同）
            section {
                statRow(label: "档位",
                        value: "\(burnRateLevelLabel(snap.level))"
                             + "  (\(speedometerFormat(snap.indicatorTokensPerMinute))/min)")
            }

            // 估算花费
            section {
                statRow(label: "估算花费",
                        value: formatCostPerHour(snap.costPerHour))
            }

            // 今日累计
            section {
                statRow(label: "今日累计", value: formatTokens(snap.todayTotal))
            }

            Divider()

            // 冻结/恢复显示（统计始终在跑）
            Button(coordinator.isPaused ? "▶ 恢复显示" : "⏸ 暂停显示") {
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
    private func petEmoji(_ snap: UsageSnapshot) -> String {
        guard !snap.isIdle, snap.hasBurnRate else { return "😴" }
        switch snap.level {
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
