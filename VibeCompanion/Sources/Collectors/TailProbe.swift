import Foundation

/// 只读文件尾部的一小段，取出末条完整行。
///
/// 用途：判断一个 session 文件的最新记录是否落在回扫窗口内。
/// 相比读全文，每个文件只付出一次 8 KB 读取的代价。
enum TailProbe {
    /// 默认探测窗口。对齐 spec 常量 `TAIL_PROBE_BYTES`。
    static let defaultProbeBytes = 8192

    /// 返回文件末条完整行；无法判定时返回 nil（调用方应保守地按"需回扫"处理）。
    static func lastCompleteLine(of url: URL, probeBytes: Int = defaultProbeBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(probeBytes) ? size - UInt64(probeBytes) : 0
        let readWholeFile = start == 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // 丢掉末尾的换行，使 "a\nb\n" 与 "a\nb" 行为一致
        var slice = data
        while let last = slice.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        guard !slice.isEmpty else { return nil }

        guard let nl = slice.lastIndex(of: UInt8(ascii: "\n")) else {
            // 窗口内没有换行符。若读的是整个文件，这就是唯一一行；
            // 否则说明末行超出窗口，无法判定。
            return readWholeFile ? String(data: slice, encoding: .utf8) : nil
        }
        let lineData = slice[slice.index(after: nl)...]
        return String(data: Data(lineData), encoding: .utf8)
    }
}
