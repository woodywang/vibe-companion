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

    /// 扫描/回扫专用串行队列。
    ///
    /// 为什么存在：首次 `rescan()` 对每个 session 文件做 `TailProbe`
    /// （open/seek/8KB/close），命中回扫窗口的还要 `tailer.watch(startAtBeginning: true)`
    /// ——后者 `queue.sync` 进 tailer 队列，同步读完**整个文件**才返回。
    /// 实测本机 150 个会话文件、共 59 MB，跑在主线程上是几百毫秒的卡顿，
    /// 且发生在菜单栏图标出现之前，并随用户活动量线性增长。
    ///
    /// **锁序不变**：改的只是 rescan 跑在哪个线程上。rescan 依旧在
    /// **释放 mapsLock 之后**才调用 `watch`，两条路径（rescan 经 `queue.sync`
    /// 进 tailer 队列后回调 handle、DispatchSource 事件在 tailer 队列上回调 handle）
    /// 仍然都是 tailer-queue → mapsLock，没有反转，也没有新增 sync 嵌套。
    ///
    /// 串行而非并发：多个 rescan 并发跑没有收益（`watch` 内部本就被 tailer
    /// 队列串行化），却会让"先登记再 watch"的时序更难推理。原先由主 run loop
    /// 提供的串行性，现在由这条队列提供。
    private let scanQueue = DispatchQueue(label: "vibe.collector.scan")

    /// - Parameter backfillWindowHours: 生产调用方须传 `AppConfig.backfillWindowHours`
    ///   （见 `AppCoordinator.start()`）；这里的字面量默认值只服务于测试。
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
        // 首次回扫派到后台，`start()` 立即返回——见 `scanQueue` 的说明
        scanQueue.async { [weak self] in self?.rescan() }
        // 每 10s 重新扫描，捕获新创建的 session 文件。
        // Timer 建在调用线程的 run loop 上（生产是主线程），但它只负责派发，
        // 实际扫描同样跑在 scanQueue 上。
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.scanQueue.async { self.rescan() }
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
