import Foundation

/// 按字节切分行，保留末尾不完整的片段（可能是半行，或被截断的多字节字符）。
/// 纯逻辑、无副作用：不做 UTF-8 解码，只在原始字节层面查找 `\n`（0x0A）。
enum LineSplitter {
    static func split(_ buffer: Data) -> (lines: [Data], rest: Data) {
        let nl = UInt8(ascii: "\n")
        var lines: [Data] = []
        var start = buffer.startIndex
        var i = buffer.startIndex
        while i < buffer.endIndex {
            if buffer[i] == nl {
                if i > start { lines.append(buffer.subdata(in: start..<i)) }
                start = buffer.index(after: i)
            }
            i = buffer.index(after: i)
        }
        return (lines, buffer.subdata(in: start..<buffer.endIndex))
    }
}

/// 监听 JSONL 文件增长，自维护 byte offset 游标。
/// `watch(_:startAtBeginning:)` 决定首次定位到文件头还是 EOF——
/// 回扫与实时尾随因此共用同一条读取路径，中间没有漏数据的窗口。
final class JsonlTailer {
    /// 读到一行完整 JSON 时回调
    var onLine: ((URL, String) -> Void)?

    /// `read(2)` 的可替换入口。生产路径就是系统调用本身；
    /// 存在的唯一理由是让测试能注入 EINTR——普通文件上信号打断几乎无法自然触发，
    /// 而它恰恰是回扫路径上最危险的一种失败。
    var readBytes: (Int32, UnsafeMutableRawPointer?, Int) -> Int = { fd, buf, count in
        read(fd, buf, count)
    }

    private var descriptors: [URL: Int32] = [:]
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var offsets: [URL: Int64] = [:]
    /// 每个文件尚未凑成完整行的剩余字节（半行或被截断的多字节字符）
    private var partials: [URL: Data] = [:]
    private let queue = DispatchQueue(label: "vibe.tailer")

    /// 开始监听一个文件。
    /// - Parameter startAtBeginning: true 表示从文件头读起（回扫历史），
    ///   false 表示定位到 EOF（只看后续新增）。
    func watch(_ url: URL, startAtBeginning: Bool) {
        queue.sync {
            guard descriptors[url] == nil else { return }
            startWatching(url, startAtBeginning: startAtBeginning)
        }
    }

    /// 是否正在监听该文件。
    ///
    /// 这是"有没有真的接管成功"的**唯一权威**：`watch` 可能因 `open()` 失败
    /// （fd 耗尽、文件已被删除）而静默放弃，调用方不能拿自己的登记表当判据。
    func isWatching(_ url: URL) -> Bool {
        queue.sync { descriptors[url] != nil }
    }

    /// 当前正在监听的全部文件。
    func watchedURLs() -> Set<URL> {
        queue.sync { Set(descriptors.keys) }
    }

    /// 停止监听单个文件，释放它的 fd 与 DispatchSource。
    ///
    /// **保留 `offsets` / `partials`**：与 `stopAll` 的语义刻意不同。这里是
    /// "这个文件暂时不活跃了，先把有限资源还回去"，文件再度被写入时应当从
    /// 原游标续读；清掉游标会让它重吐整个历史文件。
    func unwatch(_ url: URL) {
        queue.sync { stopWatching(url) }
    }

    /// 停止所有监听，并把状态清回"从未 watch 过"。
    ///
    /// `offsets` / `partials` 也要清：留着的话再次 `watch` 同一个文件时会沿用旧游标，
    /// 而调用方期望的是一次全新的开始（`startAtBeginning` 会被 `offsets[url] != nil`
    /// 的判断整个绕过），半行残留还会污染重启后的第一批数据。
    func stopAll() {
        queue.sync {
            // 只 cancel：fd 由各自的 cancel handler 关闭（见 startWatching）。
            // 在这里直接 close 会在 libdispatch 仍持有该 fd 的 kqueue 注册时
            // 就把它还给进程描述符表，属于 DispatchSource 的契约违规。
            for url in Array(sources.keys) { stopWatching(url) }   // 先快照键：stopWatching 会改 sources
            offsets.removeAll()
            partials.removeAll()
        }
    }

    /// 调用方必须已在 `queue` 上。
    private func stopWatching(_ url: URL) {
        guard let src = sources.removeValue(forKey: url) else { return }
        // 同步摘掉登记，这样 `watch` / `isWatching` 立刻反映"已不再监听"，
        // 不必等 cancel handler 被队列排到。
        descriptors.removeValue(forKey: url)
        src.cancel()
    }

    private func startWatching(_ url: URL, startAtBeginning: Bool) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        descriptors[url] = fd

        // 首次定位：回扫从 0 起，否则跳到 EOF
        if offsets[url] == nil {
            if startAtBeginning {
                offsets[url] = 0
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                offsets[url] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } else {
                offsets[url] = 0
            }
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.readNew(url)
        }
        // fd 按**值**捕获，而不是回头查字典：cancel handler 是异步排队执行的，
        // 等它跑起来时 `descriptors[url]` 可能已被摘掉（unwatch/stopAll），
        // 查字典就会漏掉 close 而泄漏 fd；也可能已被同一 url 的新一轮 watch
        // 换成了另一个 fd，那就会误关别人的描述符。值捕获两种都不会发生。
        src.setCancelHandler { close(fd) }
        src.resume()
        sources[url] = src

        // 启动时也读一次（可能在我们定位 EOF 后又有写入）
        readNew(url)
    }

    private func readNew(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }

        let currentSize = lseek(fd, 0, SEEK_END)
        var offset = offsets[url] ?? 0
        if offset > currentSize {
            // 文件被截断/轮转，从头开始
            offset = 0
            partials[url] = Data()
        }
        guard currentSize > offset else { return }

        lseek(fd, offset, SEEK_SET)

        // 分块循环读到末尾。
        // 单次 read(2) 不保证返回请求的全部字节——回扫时一次要读 MB 级数据，
        // 若按单次读取量之外的值推进 offset 会静默丢数据。
        let chunkSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var pending = partials[url] ?? Data()
        var emitted: [String] = []

        while offset < currentSize {
            let want = Int(min(Int64(chunkSize), currentSize - offset))
            var err: Int32 = 0
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                let n = readBytes(fd, raw.baseAddress, want)
                if n < 0 { err = errno }   // 紧邻 read 取 errno，避免被后续调用覆盖
                return n
            }
            // read(2) 有三种结局，不能混为一谈：
            // - got < 0 且 EINTR：被信号打断，什么都没读到，原地重试（不推进 offset）。
            //   回扫历史文件时 startWatching 里这一次同步读取是唯一时机
            //   （DispatchSource 只在 .write 时才触发），放弃就是永久丢数据。
            // - got < 0 其他 errno：真的读不动了，放弃本轮。
            // - got == 0：EOF。
            if got < 0 {
                if err == EINTR { continue }
                break
            }
            if got == 0 { break }
            offset += Int64(got)

            pending.append(contentsOf: buffer[0..<got])
            let (lines, rest) = LineSplitter.split(pending)
            pending = rest
            for line in lines {
                if let text = String(data: line, encoding: .utf8) { emitted.append(text) }
            }
        }

        offsets[url] = offset
        partials[url] = pending
        for text in emitted { onLine?(url, text) }
    }
}
