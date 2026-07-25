import SwiftUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator

    @State private var tokenInput: String = ""
    @State private var apiBase: String = Settings.shared.apiBase
    @State private var paused: Bool = Settings.shared.isPaused
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section("账户") {
                if Settings.shared.isRegistered {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("已注册").font(.headline)
                        Spacer()
                        Text("Token: \(maskedToken)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("登出此设备（仅本机）", role: .destructive) {
                        Settings.shared.clientToken = nil
                        Settings.shared.clientId = nil
                        message = "已登出此设备"; isError = false
                    }
                    Text("如需彻底吊销 token，请在网站 Dashboard 删除该设备。")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("在网站注册账户后，于 Dashboard 添加设备获取 Client Token，粘贴到下方：")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("vc_xxxxxxxx...", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存 Token 并完成注册") {
                        saveToken()
                    }
                    .disabled(!tokenInput.hasPrefix("vc_"))
                }
            }

            Section("服务地址") {
                TextField("API Base", text: $apiBase)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Settings.shared.apiBase = apiBase
                    message = "已保存"; isError = false
                }
            }

            Section("采集") {
                Toggle("暂停采集", isOn: $paused)
                    .onChange(of: paused) { v in Settings.shared.isPaused = v }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(isError ? .red : .green)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vibe Companion 设置")
    }

    private var maskedToken: String {
        guard let t = Settings.shared.clientToken else { return "" }
        guard t.count > 12 else { return t }
        return String(t.prefix(8)) + "…" + String(t.suffix(4))
    }

    private func saveToken() {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("vc_") else {
            message = "Token 格式不正确"; isError = true; return
        }
        Settings.shared.clientToken = trimmed
        message = "已保存！开始上传。"; isError = false
        tokenInput = ""
        // 立即触发一次上传
        coordinator.objectWillChange.send()
    }
}
