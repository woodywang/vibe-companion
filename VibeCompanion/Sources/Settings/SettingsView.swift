import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("显示") {
                Toggle("暂停显示", isOn: $coordinator.isPaused)
                Text("暂停只冻结界面读数，统计不会中断——会话文件照常摄入，"
                     + "恢复后数值立即反映真实用量。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("速度表量程") {
                Picker("量程", selection: $coordinator.gaugeScaleID) {
                    ForEach(allGaugeScaleIDs, id: \.self) { id in
                        Text(gaugeScale(id: id, recentPeak: 0).displayName).tag(id)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("实测瞬时速率跨三个数量级（中位约 613k、峰值超过 8M tok/min）。"
                     + "对数在整个跨度上都有分辨率，是默认；线性最直观但低速区指针贴底；"
                     + "自适应跟随近期峰值，永不溢出但刻度会变。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("表盘灵敏度") {
                Picker("平滑时间常数", selection: $coordinator.instantRateTauSeconds) {
                    ForEach(allInstantRateTauSeconds, id: \.self) { tau in
                        Text(instantRateTauLabel(tau)).tag(tau)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("表盘显示的是**瞬时**速率，这个值决定它有多跟手。"
                     + "数值越小指针越跳、反馈越快；越大越稳、响应越慢。"
                     + "实测 30 秒档相邻更新中位跳变 6.4%、约 69 秒响应到位；"
                     + "60 秒档跳变 3.3%、约 138 秒。"
                     + "（菜单栏的速率不受此项影响，那里始终是 ccusage 的区块口径。）")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }
}
