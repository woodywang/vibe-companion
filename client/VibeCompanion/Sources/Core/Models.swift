import Foundation

// MARK: - Token 用量事件

/// 一次 AI 编程回合产生的 token 用量，与后端 UsageEventInput 对应。
struct UsageEvent: Codable, Equatable, Identifiable {
    var id: String { sourceUuid }
    var sourceUuid: String
    var agent: String          // "claude" | "codex"
    var sessionId: String?
    var model: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int
    var recordedAt: Int64       // ms epoch

    // 字段名与后端 zod schema 一致（camelCase），无需自定义 CodingKeys。
    // JSONEncoder 默认输出 camelCase，与服务端期望完全匹配。

    /// 加权 token 数：排除低成本的 cacheRead，用于驱动宠物速率与今日累计。
    /// 计算属性不参与 Codable 编码，不影响上传 body。
    var weightedTokens: Int { inputTokens + outputTokens + cacheCreationTokens + reasoningTokens }
}

// MARK: - 上传 API 请求/响应

struct UsageBatchRequest: Codable {
    let events: [UsageEvent]
}

struct UsageBatchResponse: Codable {
    let ok: Bool
    let inserted: Int
    let duplicates: Int
}

// MARK: - 客户端注册响应

struct ClientRegisterResponse: Codable {
    let ok: Bool
    let clientId: String
    let clientToken: String
}
