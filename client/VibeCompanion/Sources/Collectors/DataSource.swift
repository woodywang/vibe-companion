import Foundation

/// Claude Code / Codex CLI 数据源路径解析
enum DataSource {
    static var claudeProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    static var codexSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    /// 发现所有 Claude session JSONL 文件
    static func claudeFiles() -> [URL] {
        let dir = claudeProjectsDir
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// 发现所有 Codex rollout JSONL 文件
    static func codexFiles() -> [URL] {
        let dir = codexSessionsDir
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }
}
