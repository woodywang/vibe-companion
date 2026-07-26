import XCTest
@testable import VibeCompanion

final class CollectorTests: XCTestCase {

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 一个可控的假 adapter：文件列表与时间戳解析都由测试指定
    private struct FakeAdapter: AgentAdapter {
        let id = "fake"
        var files: [URL] = []
        var timestampByLine: [String: Date] = [:]
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? { nil }
        func timestamp(fromLine line: String) -> Date? { timestampByLine[line] }
    }

    private func write(_ contents: String, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func collector(_ adapter: AgentAdapter) -> Collector {
        Collector(adapters: [adapter], backfillWindowHours: 6, now: { self.now })
    }

    func testBackfillsWhenLastEntryInsideWindow() throws {
        let url = try write("old\nrecent\n", name: "a.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["recent": now.addingTimeInterval(-3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testSkipsBackfillWhenLastEntryOutsideWindow() throws {
        let url = try write("old\nancient\n", name: "b.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["ancient": now.addingTimeInterval(-10 * 3600)])
        XCTAssertFalse(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsAtExactWindowBoundary() throws {
        let url = try write("x\nedge\n", name: "c.jsonl")
        let adapter = FakeAdapter(files: [url],
                                  timestampByLine: ["edge": now.addingTimeInterval(-6 * 3600)])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 时间戳解析失败 -> 保守回扫
    func testBackfillsWhenTimestampUnparseable() throws {
        let url = try write("x\nunknown\n", name: "d.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 探测不到完整行（空文件）-> 保守回扫
    func testBackfillsWhenProbeFindsNothing() throws {
        let url = try write("", name: "e.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    func testBackfillsWhenFileMissing() {
        let url = dir.appendingPathComponent("nope.jsonl")
        let adapter = FakeAdapter(files: [url], timestampByLine: [:])
        XCTAssertTrue(collector(adapter).shouldBackfill(url, adapter: adapter))
    }

    /// 端到端：回扫真实 Claude 行并产出 entry
    func testStartEmitsEntriesFromBackfilledFile() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5}}}
        """
        let url = try write(line + "\n", name: "claude.jsonl")
        let adapter = ClaudeAdapter(roots: [])

        // 直接驱动 tailer 路径：用真实 ClaudeAdapter 但把文件列表固定住
        // now 取 entry 之后 1 小时（entry 是 2026-07-25T07:00:00Z == 1784962800）
        let c = Collector(adapters: [FixedFileAdapter(inner: adapter, files: [url])],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })
        var got: [UsageEntry] = []
        let done = expectation(description: "entry")
        done.assertForOverFulfill = false
        c.onEntry = { got.append($0); done.fulfill() }
        c.start()
        wait(for: [done], timeout: 3)
        c.stop()

        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].counts.input, 10)
        XCTAssertEqual(got[0].dedupKey, "m1:r1")
    }

    /// stop() 之后再 start() 必须还能采集。
    ///
    /// 修复前：stop() 只清 rescanTimer 与 tailer 的 sources/descriptors，
    /// 留着 ownerByFile/contextByFile 与 offsets/partials，于是重启后 rescan
    /// 对每个文件都看到"已存在"、再也不 watch——静默不采集，phase2 超时。
    func testRestartAfterStopStillCollects() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let url = try write(line + "\n", name: "restart.jsonl")
        let c = Collector(adapters: [FixedFileAdapter(inner: ClaudeAdapter(roots: []),
                                                      files: [url])],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })

        let phase1 = expectation(description: "首次 start 采到")
        phase1.assertForOverFulfill = false
        let phase2 = expectation(description: "stop 后再 start 仍能采到")
        phase2.assertForOverFulfill = false
        // onEntry 从 tailer 队列回调，计数需自带同步
        let lock = NSLock()
        var n = 0
        c.onEntry = { _ in
            lock.lock(); n += 1; let k = n; lock.unlock()
            if k == 1 { phase1.fulfill() } else { phase2.fulfill() }
        }

        c.start()
        wait(for: [phase1], timeout: 5)
        c.stop()

        c.start()
        wait(for: [phase2], timeout: 5)
        c.stop()

        lock.lock(); let final = n; lock.unlock()
        XCTAssertGreaterThanOrEqual(final, 2)
    }

    // MARK: watcher 生命周期

    /// 首轮 watch 失败的文件，后续 rescan 必须重试。
    ///
    /// 修复前：rescan 在调用 `watch` **之前**就无条件登记 ownerByFile，且从不
    /// 检查 watch 是否成功；`startWatching` 在 `open()` 失败时静默 return。
    /// 于是文件停在"已登记但没监听"的状态，而 rescan 的新文件判据正是
    /// ownerByFile，此后每轮都判定非新文件而跳过——该会话永久不被采集。
    /// 生产触发路径是 fd 耗尽，这里用"文件还不存在"制造同一种 open 失败。
    func testRetriesWatchAfterAFailedOpen() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let url = dir.appendingPathComponent("late.jsonl")
        let c = Collector(adapters: [FixedFileAdapter(inner: ClaudeAdapter(roots: []),
                                                      files: [url])],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })
        // onEntry 从 tailer 队列同步回调（watch 的首次读取走 queue.sync）
        let lock = NSLock()
        var got: [UsageEntry] = []
        c.onEntry = { lock.lock(); got.append($0); lock.unlock() }

        c.rescan()                                   // 文件尚不存在 -> open 失败
        _ = try write(line + "\n", name: "late.jsonl")
        c.rescan()                                   // 必须重新尝试

        lock.lock(); let n = got.count; lock.unlock()
        XCTAssertEqual(n, 1, "首轮 open 失败后，后续 rescan 必须重新 watch")
        c.stop()
    }

    /// 长期没写过的会话文件不该一直占着 fd。
    ///
    /// `discoverFiles()` 没有任何时间过滤，而会话目录只增不减；每个被发现的
    /// 文件都会永久持有一个 O_EVTONLY fd 与一个 DispatchSource，只有整体
    /// `stopAll()` 才释放。菜单栏 App 常驻数日，fd 数单调增长直到撞上
    /// RLIMIT_NOFILE（经 LaunchServices 启动的 .app 实测软限 256）。
    func testDoesNotWatchFilesOutsideTheActivityWindow() throws {
        let fresh = try write("x\n", name: "fresh.jsonl")
        let stale = try write("x\n", name: "stale.jsonl")
        // mtime 相对注入的 now 钉死，别让真实挂钟渗进断言
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fresh.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 3600)], ofItemAtPath: stale.path)

        let c = collector(FakeAdapter(files: [fresh, stale]))
        c.rescan()

        XCTAssertTrue(c.isWatching(fresh))
        XCTAssertFalse(c.isWatching(stale), "10 小时没写过的文件不该占着 fd")
        c.stop()
    }

    /// 已在监听的文件一旦不再活跃，必须主动释放 fd 与 DispatchSource。
    /// 只在首次发现时过滤是不够的——App 常驻期间文件是逐渐变冷的。
    func testReleasesWatcherWhenAWatchedFileGoesStale() throws {
        let url = try write("x\n", name: "cooling.jsonl")
        let c = collector(FakeAdapter(files: [url]))

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: url.path)
        c.rescan()
        XCTAssertTrue(c.isWatching(url))

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 3600)],
            ofItemAtPath: url.path)
        c.rescan()

        XCTAssertFalse(c.isWatching(url), "变冷的文件必须被回收，否则 fd 只增不减")
        c.stop()
    }

    /// 回收之后文件又被写入 -> 必须重新接管，且从上次的游标继续（不重复吐旧行）。
    func testResumesAStaleFileAfterItIsWrittenAgain() throws {
        let first = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let second = """
        {"type":"assistant","requestId":"r2","timestamp":"2026-07-25T07:05:00.000Z",\
        "message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":30,"output_tokens":40}}}
        """
        // 记录时间戳是 07:00 / 07:05，把 now 放在 07:10，两条都落在 6h 回扫窗口内
        let clock = Date(timeIntervalSince1970: 1_784_963_400)
        let url = try write(first + "\n", name: "resume.jsonl")
        let c = Collector(adapters: [FixedFileAdapter(inner: ClaudeAdapter(roots: []),
                                                      files: [url])],
                          backfillWindowHours: 6,
                          now: { clock })
        let lock = NSLock()
        var keys: [String] = []
        c.onEntry = { e in lock.lock(); keys.append(e.dedupKey ?? ""); lock.unlock() }

        try FileManager.default.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-60)], ofItemAtPath: url.path)
        c.rescan()                                   // 接管并回扫第一行
        try FileManager.default.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-10 * 3600)],
            ofItemAtPath: url.path)
        c.rescan()                                   // 变冷 -> 回收
        XCTAssertFalse(c.isWatching(url))

        // 会话被恢复：追加一行，mtime 也随之刷新
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((second + "\n").utf8))
        try handle.close()
        c.rescan()                                   // 必须重新接管

        XCTAssertTrue(c.isWatching(url))
        lock.lock(); let seen = keys; lock.unlock()
        XCTAssertEqual(seen, ["m1:r1", "m2:r2"], "重新接管应从旧游标继续，而不是重吐整个文件")
        c.stop()
    }

    /// 包装器：在 discoverFiles 里睡一觉，模拟"回扫是几百毫秒文件 I/O"
    private struct SlowDiscoverAdapter: AgentAdapter {
        let inner: AgentAdapter
        let files: [URL]
        let delay: TimeInterval
        var id: String { inner.id }
        func discoverFiles() -> [URL] { Thread.sleep(forTimeInterval: delay); return files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? {
            inner.parse(line: line, context: &context)
        }
        func timestamp(fromLine line: String) -> Date? { inner.timestamp(fromLine: line) }
    }

    /// `start()` 不得阻塞调用线程。生产里它跑在 MainActor 上、在菜单栏图标
    /// 出现之前，而回扫要 probe 上百个文件再整文件读一遍。
    func testStartDoesNotBlockCallingThread() throws {
        let line = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-07-25T07:00:00.000Z",\
        "message":{"id":"m1","model":"claude-opus-5",\
        "usage":{"input_tokens":10,"output_tokens":20}}}
        """
        let url = try write(line + "\n", name: "slow.jsonl")
        let c = Collector(adapters: [SlowDiscoverAdapter(inner: ClaudeAdapter(roots: []),
                                                         files: [url], delay: 0.5)],
                          backfillWindowHours: 24 * 365,
                          now: { Date(timeIntervalSince1970: 1_784_966_400) })
        let done = expectation(description: "entry")
        done.assertForOverFulfill = false
        c.onEntry = { _ in done.fulfill() }

        let t0 = Date()
        c.start()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 0.2, "start() 阻塞调用线程 \(elapsed)s")

        // 回扫仍要真的发生，只是挪到了后台
        wait(for: [done], timeout: 5)
        c.stop()
    }

    // MARK: 并发安全

    /// 每次 discoverFiles 都多吐一批文件，逼 rescan 反复**写** ownerByFile / contextByFile。
    ///
    /// 计数自带锁：`start()` 的首轮 rescan 跑在 Collector 的 scanQueue 上，
    /// 而本用例又从自己的队列并发驱动 rescan，两边都会调 discoverFiles。
    /// 不锁的话 TSan 会报到这个测试替身头上，把真正要看的生产侧竞争淹掉。
    private final class GrowingAdapter: AgentAdapter {
        let id = "growing"
        let dir: URL
        private let lock = NSLock()
        private var count = 0
        init(dir: URL) { self.dir = dir }
        func discoverFiles() -> [URL] {
            lock.lock()
            count = min(count + 4, 120)
            let n = count
            lock.unlock()
            return (0..<n).map { dir.appendingPathComponent("race-\($0).jsonl") }
        }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? {
            context.stickyModel = line
            return nil
        }
        func timestamp(fromLine line: String) -> Date? { nil }
    }

    /// rescan（主 run loop）与 handle（tailer 串行队列）并发读写同两个字典。
    ///
    /// 无同步时 TSan 必报 data race；同时该用例也守着死锁：rescan 若持锁调用
    /// `tailer.watch`（内部 `queue.sync`），而 handle 在 tailer 队列上等同一把锁，
    /// 就会循环等待——届时本用例超时失败而非静默通过。
    func testConcurrentRescanAndHandleDoNotRace() throws {
        // 用真实文件，让 watch 真的建起 DispatchSource 并同步回调 handle
        for i in 0..<120 { _ = try write("x\n", name: "race-\(i).jsonl") }

        let c = Collector(adapters: [GrowingAdapter(dir: dir)],
                          backfillWindowHours: 6, now: { self.now })
        c.start()
        // start() 的首轮 rescan 现在派到后台队列，到不到位不确定；
        // 这里同步再扫一次把前几个文件确定地登记进字典，
        // 让下面 handle 的那 4000 次调用一定能走到临界区而不是被 guard 挡掉。
        c.rescan()
        let seeded = (0..<4).map { dir.appendingPathComponent("race-\($0).jsonl") }

        let done = expectation(description: "concurrent churn finished")
        done.expectedFulfillmentCount = 2
        let rescans = DispatchQueue(label: "test.rescan")
        let handles = DispatchQueue(label: "test.handle")

        rescans.async {
            for _ in 0..<40 { c.rescan() }
            done.fulfill()
        }
        handles.async {
            for i in 0..<4000 { c.handle(url: seeded[i % seeded.count], line: "line-\(i)") }
            done.fulfill()
        }

        wait(for: [done], timeout: 30)
        c.stop()
    }

    /// 包装器：复用真实 adapter 的解析，但固定文件列表
    private struct FixedFileAdapter: AgentAdapter {
        let inner: AgentAdapter
        let files: [URL]
        var id: String { inner.id }
        func discoverFiles() -> [URL] { files }
        func parse(line: String, context: inout ParseContext) -> UsageEntry? {
            inner.parse(line: line, context: &context)
        }
        func timestamp(fromLine line: String) -> Date? { inner.timestamp(fromLine: line) }
    }
}
