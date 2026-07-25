import Foundation

/// 全局应用配置
enum AppConfig {
    /// 后端 API 基础地址。可在设置中覆盖。
    /// MVP 默认指向本地 dev server。
    static let defaultAPIBase = "http://localhost:3000"

    /// 上传触发：每 N 秒
    static let uploadIntervalSeconds: TimeInterval = 20
    /// 上传触发：缓冲达 N 条
    static let uploadBatchSize = 50
    /// 上传失败最大重试次数
    static let uploadMaxRetries = 5

    /// 速率聚合窗口（秒）
    static let rateWindowSeconds: TimeInterval = 60
}
