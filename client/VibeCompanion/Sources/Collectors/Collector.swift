import Foundation

/// 采集器：监听 Claude Code 与 Codex CLI 的 JSONL 会话文件，
/// 解析 token 用量事件并产出 UsageEvent。
final class Collector {
    /// 采集到一条事件时回调
    var onEvent: ((UsageEvent) -> Void)?

    private let tailer = JsonlTailer()
    private var watchedFiles: Set<URL> = []

    func start() {
        tailer.onLine = { [weak self] url, line in
            self?.parse(url: url, line: line)
        }
        rescan()
        // 每 10s 重新扫描，捕获新创建的 session 文件
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        tailer.stopAll()
    }

    private func rescan() {
        let claude = DataSource.claudeFiles()
        let codex = DataSource.codexFiles()
        for f in claude + codex {
            if !watchedFiles.contains(f) {
                watchedFiles.insert(f)
                tailer.watch(f, startAtBeginning: false)
            }
        }
    }

    private func parse(url: URL, line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // 判断来源：路径含 .claude -> Claude；含 .codex -> Codex
        if url.path.contains("/.claude/") {
            if let ev = ClaudeParser.parse(obj) {
                onEvent?(ev)
            }
        } else if url.path.contains("/.codex/") {
            if let ev = CodexParser.parse(obj) {
                onEvent?(ev)
            }
        }
    }
}

// MARK: - Claude Code 解析

enum ClaudeParser {
    /// Claude: type=="assistant" 行的 message.usage 含 token 字段
    static func parse(_ obj: [String: Any]) -> UsageEvent? {
        guard obj["type"] as? String == "assistant" else { return nil }
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        let sessionId = obj["sessionId"] as? String
        let model = message["model"] as? String

        // timestamp 可能是 ISO 字符串
        let recordedAt: Int64
        if let ts = obj["timestamp"] as? String,
           let date = DateParsing.parseISO8601(ts) {
            recordedAt = Int64(date.timeIntervalSince1970 * 1000)
        } else {
            recordedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }

        return UsageEvent(
            sourceUuid: uuid,
            agent: "claude",
            sessionId: sessionId,
            model: model,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            reasoningTokens: 0,
            totalTokens: computeTotalClaude(usage),
            recordedAt: recordedAt
        )
    }

    private static func computeTotalClaude(_ usage: [String: Any]) -> Int {
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cr = usage["cache_read_input_tokens"] as? Int ?? 0
        return input + output + cc + cr
    }
}

// MARK: - Codex CLI 解析

enum CodexParser {
    /// Codex: payload.type=="token_count" 行的 payload.info.last_token_usage
    static func parse(_ obj: [String: Any]) -> UsageEvent? {
        guard let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count" else {
            return nil
        }
        guard let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any] else {
            return nil
        }

        let sessionId = (obj["payload"] as? [String: Any])?["session_id"] as? String
            ?? payload["session_id"] as? String
        let model = info["model"] as? String

        // Codex 时间戳：顶层 timestamp（ISO 字符串或 ms 数字）
        let recordedAt: Int64
        if let ts = obj["timestamp"] as? String,
           let date = DateParsing.parseISO8601(ts) {
            recordedAt = Int64(date.timeIntervalSince1970 * 1000)
        } else if let ts = obj["timestamp"] as? NSNumber {
            recordedAt = ts.int64Value
        } else {
            recordedAt = Int64(Date().timeIntervalSince1970 * 1000)
        }

        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? (input + cached + output + reasoning)

        // 去重键：sessionId + 时间戳
        let dedup = "\(sessionId ?? UUID().uuidString)-\(recordedAt)"

        return UsageEvent(
            sourceUuid: dedup,
            agent: "codex",
            sessionId: sessionId,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: cached,
            reasoningTokens: reasoning,
            totalTokens: total,
            recordedAt: recordedAt
        )
    }
}
