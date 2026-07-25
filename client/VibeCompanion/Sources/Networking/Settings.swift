import Foundation

/// 持久化用户设置（client_token、api_base、暂停状态等）到 UserDefaults。
///
/// 注意：SwiftPM 打包的 .app 中，`UserDefaults.standard` 的 domain 可能不等于
/// `CFBundleIdentifier`（取决于 bundle 加载方式）。显式用 bundle id 创建 suite，
/// 确保 `defaults write dev.vibe.companion ...` 写入的值能被读到。
final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults

    init() {
        // 优先用 bundle id suite；若失败（无 bundle 上下文）回退到 standard。
        // SwiftPM 打包的 .app 中，UserDefaults.standard 的 domain 可能不等于
        // CFBundleIdentifier，显式用 suite 确保配置可被外部写入与读取。
        if let d = UserDefaults(suiteName: "dev.vibe.companion") {
            self.defaults = d
        } else {
            self.defaults = .standard
        }
    }

    private enum Keys {
        static let clientToken = "vc.client_token"
        static let clientId = "vc.client_id"
        static let apiBase = "vc.api_base"
        static let paused = "vc.paused"
    }

    var clientToken: String? {
        get { defaults.string(forKey: Keys.clientToken) }
        set { defaults.set(newValue, forKey: Keys.clientToken) }
    }

    var clientId: String? {
        get { defaults.string(forKey: Keys.clientId) }
        set { defaults.set(newValue, forKey: Keys.clientId) }
    }

    var apiBase: String {
        get { defaults.string(forKey: Keys.apiBase) ?? AppConfig.defaultAPIBase }
        set { defaults.set(newValue, forKey: Keys.apiBase) }
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Keys.paused) }
        set { defaults.set(newValue, forKey: Keys.paused) }
    }

    /// 是否已完成客户端注册（持有有效 client_token）
    var isRegistered: Bool {
        guard let t = clientToken, t.hasPrefix("vc_") else { return false }
        return true
    }
}
