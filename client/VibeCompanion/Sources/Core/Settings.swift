import Foundation

/// 持久化用户设置（暂停状态等）到 UserDefaults。
///
/// 注意：SwiftPM 打包的 .app 中，`UserDefaults.standard` 的 domain 可能不等于
/// `CFBundleIdentifier`（取决于 bundle 加载方式）。显式用 bundle id 创建 suite，
/// 确保 `defaults write dev.vibe.companion ...` 写入的值能被读到。
final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults

    init() {
        // 优先用 bundle id suite；若失败（无 bundle 上下文）回退到 standard。
        if let d = UserDefaults(suiteName: "dev.vibe.companion") {
            self.defaults = d
        } else {
            self.defaults = .standard
        }
    }

    private enum Keys {
        static let paused = "vc.paused"
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Keys.paused) }
        set { defaults.set(newValue, forKey: Keys.paused) }
    }
}
