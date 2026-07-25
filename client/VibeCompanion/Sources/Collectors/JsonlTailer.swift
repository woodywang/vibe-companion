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
/// 启动时定位到 EOF（不回溯历史），之后用 DispatchSource 监听写入事件。
final class JsonlTailer {
    /// 读到一行完整 JSON 时回调
    var onLine: ((URL, String) -> Void)?

    private var descriptors: [URL: Int32] = [:]
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var offsets: [URL: Int64] = [:]
    /// 每个文件尚未凑成完整行的剩余字节（半行或被截断的多字节字符）
    private var partials: [URL: Data] = [:]
    private let queue = DispatchQueue(label: "vibe.tailer")

    /// 开始监听一个文件。若 offset 未记录，定位到 EOF。
    func watch(_ url: URL) {
        queue.sync {
            guard descriptors[url] == nil else { return }
            startWatching(url)
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

    private func startWatching(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        descriptors[url] = fd

        // 首次：定位到 EOF
        if offsets[url] == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                offsets[url] = size
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

        let toRead = currentSize - offset
        guard toRead > 0 else { return }

        lseek(fd, offset, SEEK_SET)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(toRead))
        defer { buffer.deallocate() }
        let read = read(fd, buffer, Int(toRead))
        guard read > 0 else { return }

        let data = Data(bytes: buffer, count: Int(read))
        offsets[url] = currentSize

        // 按字节拆分行，跨读取保留半行/被截断的多字节字符
        let combined = (partials[url] ?? Data()) + data
        let (lines, rest) = LineSplitter.split(combined)
        partials[url] = rest
        for line in lines {
            if let text = String(data: line, encoding: .utf8) {
                onLine?(url, text)
            }
        }
    }
}
