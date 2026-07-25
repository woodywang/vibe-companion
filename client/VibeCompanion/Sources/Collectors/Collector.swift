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
    /// 保护 `ownerByFile` / `contextByFile`。
    ///
    /// 这两个字典被两条线程触碰：`rescan()` 跑在主 run loop 的 Timer 上，
    /// `handle(url:line:)` 跑在 `JsonlTailer` 的私有串行队列上。
    ///
    /// **不得**持锁调用 `tailer.watch(_:startAtBeginning:)` 或 `adapter.discoverFiles()`：
    /// 前者内部 `queue.sync` 进 tailer 队列，而 handle 正是从那条队列上来抢这把锁，
    /// 持锁调用即构成循环等待死锁；后者是文件系统 I/O，持锁会长时间占住临界区。
    private let mapsLock = NSLock()
    /// 文件 -> 负责它的 adapter（由 `mapsLock` 保护）
    private var ownerByFile: [URL: AgentAdapter] = [:]
    /// 文件 -> 解析上下文（Codex 的 sticky model 按文件隔离；由 `mapsLock` 保护）
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

    // MARK: - internal

    /// internal（而非 private）以便测试直接并发驱动 rescan 与 handle。
    func rescan() {
        for adapter in adapters {
            // discoverFiles 是文件系统 I/O：锁外调用
            for file in adapter.discoverFiles() {
                // 先登记再 watch：watch 会同步触发首次读取 -> onLine -> handle，
                // 那时字典里必须已有该 url，否则首批数据全被 handle 的 guard 丢掉。
                mapsLock.lock()
                let isNew = ownerByFile[file] == nil
                if isNew {
                    ownerByFile[file] = adapter
                    contextByFile[file] = ParseContext()
                }
                mapsLock.unlock()
                guard isNew else { continue }
                // 锁外：watch 内部 queue.sync 进 tailer 队列，持锁调用会死锁
                tailer.watch(file, startAtBeginning: shouldBackfill(file, adapter: adapter))
            }
        }
    }

    /// internal（而非 private）以便测试直接并发驱动 rescan 与 handle。
    func handle(url: URL, line: String) {
        // 锁内取出（ParseContext 是 struct，取出即拷贝）
        mapsLock.lock()
        let owner = ownerByFile[url]
        var context = contextByFile[url] ?? ParseContext()
        mapsLock.unlock()

        guard let adapter = owner else { return }
        // 锁外解析：解析可能不便宜，且不该在临界区里回调外部代码
        let entry = adapter.parse(line: line, context: &context)

        // 锁内写回
        mapsLock.lock()
        contextByFile[url] = context
        mapsLock.unlock()

        if let entry { onEntry?(entry) }
    }
}
