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
                Text("实测真实速率跨度可达 20 倍（约 41k – 760k tok/min）。"
                     + "线性最直观；对数在低速区更有分辨率；自适应跟随近期峰值，永不溢出但刻度会变。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }
}
