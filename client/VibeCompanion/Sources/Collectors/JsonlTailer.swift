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

    /// 停止所有监听
    func stopAll() {
        queue.sync {
            for (_, src) in sources { src.cancel() }
            for (_, fd) in descriptors { close(fd) }
            sources.removeAll()
            descriptors.removeAll()
        }
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
        src.setCancelHandler { [weak self] in
            if let fd = self?.descriptors.removeValue(forKey: url) {
                close(fd)
            }
        }
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
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            guard got > 0 else { break }
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
