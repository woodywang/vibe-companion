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
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }
}
