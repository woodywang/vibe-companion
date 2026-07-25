import Foundation

/// OpenAI Codex CLI 数据适配器。
struct CodexAdapter: AgentAdapter {
    let id = "codex"

    private let explicitRoots: [URL]?

    init(roots: [URL]? = nil) {
        self.explicitRoots = roots
    }

    /// `$CODEX_HOME`（逗号分隔，**不**展开 `~`——对齐 ccusage）否则 `~/.codex`。
    private var roots: [URL] {
        if let explicitRoots { return explicitRoots }
        let configured = expandTildePaths(ProcessInfo.processInfo.environment["CODEX_HOME"],
                                          expandTilde: false)
        if !configured.isEmpty { return configured }
        return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")]
    }

    /// `sessions/**/*.jsonl` 与 `archived_sessions/**/*.jsonl`。
    /// **无** `rollout-*` 前缀过滤（对齐 ccusage）。
    func discoverFiles() -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for root in roots {
            for sub in ["sessions", "archived_sessions"] {
                let dir = root.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue,
                      let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
                else { continue }
                for case let url as URL in e where url.pathExtension == "jsonl" {
                    let resolved = url.resolvingSymlinksInPath()
                    if seen.insert(resolved).inserted { out.append(resolved) }
                }
            }
        }
        return out
    }

    func parse(line: String, context: inout ParseContext) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else { return nil }

        // turn_context 只更新 sticky model，不产出 entry
        if obj["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { context.stickyModel = model }
            return nil
        }

        guard obj["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = DateParsing.parseISO8601(tsString)
        else { return nil }

        let rawInput = usage["input_tokens"] as? Int ?? 0
        let rawCached = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0

        // cached 嵌套在 input 内：先 clamp 再相减。
        // 当前实现漏了这一步，导致 cached 被重复计算。
        let cached = min(rawCached, rawInput)
        let nonCachedInput = rawInput - cached

        // total 直取文件值；reasoning 已含在 output 内，回退式才用它。
        let fileTotal = usage["total_tokens"] as? Int
        let bucketSum = nonCachedInput + cached + output
        let total = fileTotal ?? (nonCachedInput + cached + output + reasoning)
        // 差额进 extraTotal，保证 TokenCounts.total 与文件一致
        let extra = max(0, total - bucketSum)

        let counts = TokenCounts(input: nonCachedInput, output: output,
                                 cacheCreation5m: 0, cacheCreation1h: 0,
                                 cacheRead: cached, extraTotal: extra)

        // 去重键：时间戳 + model + 各 token 值，不含 sessionId（对齐 ccusage）
        let key = [tsString, context.stickyModel ?? "",
                   String(rawInput), String(rawCached), String(output),
                   String(reasoning), String(total)].joined(separator: "|")

        return UsageEntry(
            timestamp: timestamp,
            agent: id,
            sessionId: obj["session_id"] as? String ?? payload["session_id"] as? String,
            model: context.stickyModel,
            counts: counts,
            isSidechain: false,
            hasSpeed: false,
            isFastSpeed: false,
            dedupKey: key
        )
    }

    func timestamp(fromLine line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["timestamp"] as? String
        else { return nil }
        return DateParsing.parseISO8601(ts)
    }
}
