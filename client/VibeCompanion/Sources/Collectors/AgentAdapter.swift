import Foundation

/// 解析单个文件时的可变上下文。
///
/// 存在的唯一理由是 Codex 的 model 为 sticky：由 `type == "turn_context"`
/// 行设定，供后续 `token_count` 行使用。Claude 不需要它。
struct ParseContext {
    var stickyModel: String?
    init() {}
}

/// 一个 coding agent 的数据接入点。
///
/// 新增 agent 只需实现本协议（见子项目②③），无需触碰算法层。
protocol AgentAdapter {
    /// 稳定标识，写入 `UsageEntry.agent`。
    var id: String { get }

    /// 发现该 agent 的全部 session 文件。
    func discoverFiles() -> [URL]

    /// 解析一行。非用量行返回 nil（但仍可能更新 context）。
    func parse(line: String, context: inout ParseContext) -> UsageEntry?

    /// 从**任意**一行提取时间戳，供 tail-probe 判断文件是否需要回扫。
    /// 末行未必是用量行，故不能复用 `parse`。
    func timestamp(fromLine line: String) -> Date?
}

/// 解析逗号分隔的路径列表。
///
/// `expandTilde` 对齐 ccusage 的差异行为：`CLAUDE_CONFIG_DIR` 展开 `~`，
/// 而 `CODEX_HOME` **不**展开。
func expandTildePaths(_ raw: String?, expandTilde: Bool) -> [URL] {
    guard let raw else { return [] }
    return raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { path in
            let finalPath = expandTilde ? (path as NSString).expandingTildeInPath : path
            // 使用 URLComponents 来保持路径的原始形式，避免 URL.path 的自动展开
            var components = URLComponents()
            components.scheme = "file"
            components.path = finalPath
            return components.url ?? URL(fileURLWithPath: finalPath)
        }
}
