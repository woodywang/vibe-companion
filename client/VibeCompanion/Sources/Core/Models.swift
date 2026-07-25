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

    /// 有效消耗 token：用于速率展示，排除 prompt cache 读取（cacheReadTokens）。
    /// cache_read 在 Claude Code 中常占 total 的 90%+ 且计费仅 1/10，计入速率
    /// 会产生天文数字且与"真实消耗速度"脱节。
    /// effective = input + output + cache_creation（与后端 queries.ts 口径一致）。
    var effectiveTokens: Int { inputTokens + outputTokens + cacheCreationTokens }

    // 字段名与后端 zod schema 一致（camelCase），无需自定义 CodingKeys。
    // JSONEncoder 默认输出 camelCase，与服务端期望完全匹配。
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
