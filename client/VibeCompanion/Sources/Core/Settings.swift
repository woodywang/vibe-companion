import Foundation

/// 持久化用户设置（暂停状态等）到 UserDefaults。
///
/// 注意：SwiftPM 打包的 .app 中，`UserDefaults.standard` 的 domain 可能不等于
/// `CFBundleIdentifier`（取决于 bundle 加载方式）。显式用 bundle id 创建 suite，
/// 确保 `defaults write dev.vibe.companion ...` 写入的值能被读到。
final class Settings {
    static let shared = Settings()

    private let defaults: UserDefaults

    /// 生产用：优先 bundle id suite，失败回退 standard。
    convenience init() {
        self.init(defaults: UserDefaults(suiteName: "dev.vibe.companion") ?? .standard)
    }

    /// 测试用：注入独立 suite，避免污染真实偏好。
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let paused = "vc.paused"
        static let gaugeScaleID = "vc.gaugeScaleID"
    }

    var isPaused: Bool {
        get { defaults.bool(forKey: Keys.paused) }
        set { defaults.set(newValue, forKey: Keys.paused) }
    }

    /// 速度表量程标识。未设置或值非法时回退到线性。
    var gaugeScaleID: String {
        get {
            let stored = defaults.string(forKey: Keys.gaugeScaleID) ?? ""
            return allGaugeScaleIDs.contains(stored) ? stored : "linear"
        }
        set { defaults.set(newValue, forKey: Keys.gaugeScaleID) }
    }
}
