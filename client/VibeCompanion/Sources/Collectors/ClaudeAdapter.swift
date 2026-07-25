import Foundation

/// Claude Code 数据适配器。
struct ClaudeAdapter: AgentAdapter {
    let id = "claude"

    /// nil 表示按环境变量与默认位置自行解析。测试可传 `[]` 关闭文件发现。
    private let explicitRoots: [URL]?

    init(roots: [URL]? = nil) {
        self.explicitRoots = roots
    }

    /// `$CLAUDE_CONFIG_DIR`（逗号分隔，展开 `~`）否则
    /// `${XDG_CONFIG_HOME:-~/.config}/claude` 与 `~/.claude`，
    /// 各需存在 `projects/` 子目录。
    private var roots: [URL] {
        if let explicitRoots { return explicitRoots }
        let env = ProcessInfo.processInfo.environment
        let configured = expandTildePaths(env["CLAUDE_CONFIG_DIR"], expandTilde: true)
        if !configured.isEmpty { return configured }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return [xdg.appendingPathComponent("claude"), home.appendingPathComponent(".claude")]
    }

    func discoverFiles() -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for root in roots {
            let projects = root.appendingPathComponent("projects")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir),
                  isDir.boolValue,
                  let e = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let resolved = url.resolvingSymlinksInPath()
                if seen.insert(resolved).inserted { out.append(resolved) }
            }
        }
        return out
    }

    func parse(line: String, context: inout ParseContext) -> UsageEntry? {
        // 廉价前置过滤，避免对绝大多数非用量行做完整 JSON 解码
        guard line.contains("\"usage\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = DateParsing.parseISO8601(tsString),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        // cache_creation 对象存在时拆两档，并忽略扁平字段
        let cc5m: Int, cc1h: Int
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            cc5m = breakdown["ephemeral_5m_input_tokens"] as? Int ?? 0
            cc1h = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
        } else {
            cc5m = usage["cache_creation_input_tokens"] as? Int ?? 0
            cc1h = 0
        }

        let speed = usage["speed"] as? String

        return UsageEntry(
            timestamp: timestamp,
            agent: id,
            sessionId: obj["sessionId"] as? String,
            model: message["model"] as? String,
            counts: TokenCounts(input: usage["input_tokens"] as? Int ?? 0,
                                output: usage["output_tokens"] as? Int ?? 0,
                                cacheCreation5m: cc5m,
                                cacheCreation1h: cc1h,
                                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                extraTotal: 0),
            isSidechain: obj["isSidechain"] as? Bool ?? false,
            hasSpeed: speed != nil,
            isFastSpeed: speed == "fast",
            dedupKey: claudeDedupKey(messageId: message["id"] as? String,
                                     requestId: obj["requestId"] as? String)
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
