import Foundation
import GRDB

/// 本地 SQLite 存储：缓冲未上传的用量事件，支持失败重试。
final class UsageStore {
    private let dbPool: DatabasePool

    convenience init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("VibeCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(path: dir.appendingPathComponent("usage.db").path)
    }

    /// 测试钩子：允许指定任意数据库路径（生产路径见 `init()`）。
    init(path: String) throws {
        dbPool = try DatabasePool(path: path)
        try migrator.migrate(dbPool)
        try recoverStuck()
    }

    /// 崩溃后复位卡在 uploading 的行，避免永久卡死丢数据。
    func recoverStuck() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE pending_event SET status='pending' WHERE status='uploading'")
        }
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "pending_event") { t in
                t.column("source_uuid", .text).notNull()
                t.column("agent", .text).notNull()
                t.column("session_id", .text)
                t.column("model", .text)
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("cache_creation_tokens", .integer).notNull()
                t.column("cache_read_tokens", .integer).notNull()
                t.column("reasoning_tokens", .integer).notNull()
                t.column("total_tokens", .integer).notNull()
                t.column("recorded_at", .integer).notNull()
                t.column("status", .text).notNull().defaults(to: "pending") // pending | uploading
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("rowid", .integer).primaryKey(autoincrement: true)
            }
            try db.create(index: "pending_event_status_idx", on: "pending_event", columns: ["status"])
        }
        return m
    }

    /// 写入一条事件（按 source_uuid 去重）
    func enqueue(_ event: UsageEvent) throws {
        try dbPool.write { db in
            // 已存在则跳过
            let exists = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_event WHERE source_uuid = ?",
                arguments: [event.sourceUuid]
            ) ?? 0
            guard exists == 0 else { return }
            try db.execute(sql: """
                INSERT INTO pending_event
                (source_uuid, agent, session_id, model, input_tokens, output_tokens,
                 cache_creation_tokens, cache_read_tokens, reasoning_tokens,
                 total_tokens, recorded_at, status, attempts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0)
                """, arguments: [
                    event.sourceUuid, event.agent, event.sessionId, event.model,
                    event.inputTokens, event.outputTokens,
                    event.cacheCreationTokens, event.cacheReadTokens,
                    event.reasoningTokens, event.totalTokens, event.recordedAt
                ])
        }
    }

    /// 取一批待上传事件（最多 limit 条），标记为 uploading
    func fetchPending(limit: Int) throws -> [PendingEvent] {
        try dbPool.write { db in
            let rows = try PendingEvent.fetchAll(
                db, sql: """
                SELECT * FROM pending_event WHERE status = 'pending'
                ORDER BY rowid LIMIT ?
                """, arguments: [limit]
            )
            for r in rows {
                try db.execute(
                    sql: "UPDATE pending_event SET status = 'uploading' WHERE rowid = ?",
                    arguments: [r.rowid]
                )
            }
            return rows
        }
    }

    /// 上传成功：删除这些事件
    func markUploaded(rowIds: [Int64]) throws {
        guard !rowIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = String(repeating: "?,", count: rowIds.count).dropLast()
            try db.execute(
                sql: "DELETE FROM pending_event WHERE rowid IN (\(placeholders))",
                arguments: StatementArguments(rowIds)
            )
        }
    }

    /// 上传失败：回退为 pending，增加 attempts
    func markFailed(rowIds: [Int64]) throws {
        guard !rowIds.isEmpty else { return }
        try dbPool.write { db in
            let placeholders = String(repeating: "?,", count: rowIds.count).dropLast()
            try db.execute(
                sql: "UPDATE pending_event SET status = 'pending', attempts = attempts + 1 WHERE rowid IN (\(placeholders))",
                arguments: StatementArguments(rowIds)
            )
        }
    }

    /// 待上传条数（用于调试/展示）
    func pendingCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM pending_event WHERE status = 'pending'"
            ) ?? 0
        }
    }
}

// MARK: - PendingEvent Row

struct PendingEvent: FetchableRecord {
    let rowid: Int64
    let sourceUuid: String
    let agent: String
    let sessionId: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let recordedAt: Int64

    init(row: Row) {
        rowid = row["rowid"]
        sourceUuid = row["source_uuid"]
        agent = row["agent"]
        sessionId = row["session_id"]
        model = row["model"]
        inputTokens = row["input_tokens"]
        outputTokens = row["output_tokens"]
        cacheCreationTokens = row["cache_creation_tokens"]
        cacheReadTokens = row["cache_read_tokens"]
        reasoningTokens = row["reasoning_tokens"]
        totalTokens = row["total_tokens"]
        recordedAt = row["recorded_at"]
    }

    /// 转为上传用的 UsageEvent
    func toEvent() -> UsageEvent {
        UsageEvent(
            sourceUuid: sourceUuid,
            agent: agent,
            sessionId: sessionId,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            recordedAt: recordedAt
        )
    }
}
