import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section("采集") {
                Toggle("暂停采集", isOn: $coordinator.isPaused)
                Text("暂停后仍会监听会话文件，但不再统计新的 token 用量。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("速度表量程") {
                Picker("量程", selection: $coordinator.gaugeScaleID) {
                    ForEach(allGaugeScaleIDs, id: \.self) { id in
                        Text(gaugeScale(id: id, recentPeak: 0).displayName).tag(id)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("实测真实速率跨度可达 20 倍（约 41k – 760k tok/min）。"
                     + "线性最直观；对数在低速区更有分辨率；自适应跟随近期峰值，永不溢出但刻度会变。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }
}
