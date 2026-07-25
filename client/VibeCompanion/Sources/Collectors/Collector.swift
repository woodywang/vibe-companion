import Foundation

/// 采集器：调度各 agent 适配器，把它们的 session 文件接到 JsonlTailer 上，
/// 并决定每个文件是否需要回扫历史。
///
/// 解析细节全部下沉到 `AgentAdapter` 实现，本类不认识任何 JSONL 格式。
final class Collector {
    /// 解析出一条用量记录时回调。
    var onEntry: ((UsageEntry) -> Void)?

    private let adapters: [AgentAdapter]
    private let backfillWindow: TimeInterval
    private let now: () -> Date

    private let tailer = JsonlTailer()
    /// 文件 -> 负责它的 adapter
    private var ownerByFile: [URL: AgentAdapter] = [:]
    /// 文件 -> 解析上下文（Codex 的 sticky model 按文件隔离）
    private var contextByFile: [URL: ParseContext] = [:]
    private var rescanTimer: Timer?

    init(adapters: [AgentAdapter] = [ClaudeAdapter(), CodexAdapter()],
         backfillWindowHours: Double = 6,
         now: @escaping () -> Date = { Date() }) {
        self.adapters = adapters
        self.backfillWindow = backfillWindowHours * 3600
        self.now = now
    }

    func start() {
        tailer.onLine = { [weak self] url, line in
            self?.handle(url: url, line: line)
        }
        rescan()
        // 每 10s 重新扫描，捕获新创建的 session 文件
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.rescan()
        }
    }

    func stop() {
        rescanTimer?.invalidate()
        rescanTimer = nil
        tailer.stopAll()
    }

    /// 该文件是否需要从头回扫。
    ///
    /// 判据是文件**末条记录**的时间戳是否落在回扫窗口内——用 `TailProbe`
    /// 只读 8 KB 尾部即可判定，无需读全文。
    /// 探测或解析的任何一步失败都返回 true：宁可多读，不可漏数据。
    func shouldBackfill(_ url: URL, adapter: AgentAdapter) -> Bool {
        guard let line = TailProbe.lastCompleteLine(of: url),
              let ts = adapter.timestamp(fromLine: line)
        else { return true }
        return now().timeIntervalSince(ts) <= backfillWindow
    }

    // MARK: - private

    private func rescan() {
        for adapter in adapters {
            for file in adapter.discoverFiles() where ownerByFile[file] == nil {
                ownerByFile[file] = adapter
                contextByFile[file] = ParseContext()
                tailer.watch(file, startAtBeginning: shouldBackfill(file, adapter: adapter))
            }
        }
    }

    private func handle(url: URL, line: String) {
        guard let adapter = ownerByFile[url] else { return }
        var context = contextByFile[url] ?? ParseContext()
        let entry = adapter.parse(line: line, context: &context)
        contextByFile[url] = context
        if let entry { onEntry?(entry) }
    }
}
