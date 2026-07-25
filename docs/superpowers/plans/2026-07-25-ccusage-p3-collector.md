# P3 采集层 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 P1 的算法核心与 P2 的定价接到真实 JSONL 数据上，让速度表显示与 ccusage 一致的 burn rate。

**Architecture:** 抽出 `AgentAdapter` 协议，把 `Collector.swift` 里的两个 parser 拆成独立适配器并修正 Codex 的双计算 bug；`JsonlTailer` 增加从 offset 0 起的回扫能力；`TokenAggregator` 从 60s 滑窗改写为 `UsageWindow` + 分块重算。本计划完成后 app 行为**真正改变**。

**Tech Stack:** Swift 5.9 / SwiftPM / XCTest / DispatchSource / macOS 13+

依赖：P1 全部、P2 全部。
设计文档：`docs/superpowers/specs/2026-07-25-ccusage-burnrate-design.md` 第 5.6、6 节

## Global Constraints

- **测试命令必须带 `DEVELOPER_DIR`**：`cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Name>`
- **`Core/` 仍不得触碰 I/O**；本计划新增的 I/O 全部在 `Collectors/` 下。
- **不得改变 P1/P2 已有的公开签名**。若发现需要改，先停下来报告。
- **数值必须与 ccusage 一致。**
- 涉及文件系统的测试一律用 `FileManager.default.temporaryDirectory` 下的唯一子目录，并在 `tearDown` 中清理；**禁止读写 `~/.claude` 或 `~/.codex`**。
- 提交信息用中文，结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## File Structure

| 文件 | 状态 | 职责 |
|---|---|---|
| `Collectors/AgentAdapter.swift` | 新增 | 协议 + `ParseContext` |
| `Collectors/ClaudeAdapter.swift` | 新增 | Claude 路径发现 / 解析 / 去重键 |
| `Collectors/CodexAdapter.swift` | 新增 | Codex 同上，含双计算修正 |
| `Collectors/TailProbe.swift` | 新增 | 读文件尾部末条完整行 |
| `Core/SessionBlockCost.swift` | 新增 | 把 P2 的 cost 聚合进 P1 的 block |
| `Collectors/JsonlTailer.swift` | 改造 | 支持从 offset 0 起；修复大文件部分读 |
| `Collectors/Collector.swift` | 改造 | 退化为 adapter 调度 + 回扫决策 |
| `Core/TokenAggregator.swift` | 改造 | 滑窗 → UsageWindow + 分块重算 |
| `Core/Models.swift` | 改造 | 删除 `UsageEvent` |

---

### Task 1: AgentAdapter 协议

**Files:**
- Create: `client/VibeCompanion/Sources/Collectors/AgentAdapter.swift`
- Test: `client/VibeCompanion/Tests/AgentAdapterTests.swift`

**Interfaces:**
- Consumes: `UsageEntry`（P1）
- Produces:
  - `struct ParseContext { var stickyModel: String?; init() }`
  - `protocol AgentAdapter { var id: String { get }; func discoverFiles() -> [URL]; func parse(line: String, context: inout ParseContext) -> UsageEntry?; func timestamp(fromLine line: String) -> Date? }`
  - `func expandTildePaths(_ raw: String?, expandTilde: Bool) -> [URL]`

**背景：** `ParseContext` 是 per-file 的可变状态，存在的唯一理由是 Codex 的 model 为 sticky——由 `type == "turn_context"` 行设定，供后续 `token_count` 行使用。`timestamp(fromLine:)` 供 tail-probe 判断文件是否需要回扫，它必须能处理**任意行**（末行未必是用量行）。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/AgentAdapterTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class AgentAdapterTests: XCTestCase {

    func testParseContextStartsWithNoStickyModel() {
        XCTAssertNil(ParseContext().stickyModel)
    }

    func testExpandTildePathsSplitsOnComma() {
        let urls = expandTildePaths("/a,/b,/c", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["/a", "/b", "/c"])
    }

    func testExpandTildePathsTrimsWhitespaceAndDropsEmpty() {
        let urls = expandTildePaths(" /a , , /b ", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["/a", "/b"])
    }

    func testExpandTildePathsExpandsTildeWhenEnabled() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let urls = expandTildePaths("~/foo", expandTilde: true)
        XCTAssertEqual(urls.map(\.path), ["\(home)/foo"])
    }

    /// Codex 的 CODEX_HOME 不展开 ~（对齐 ccusage）
    func testExpandTildePathsLeavesTildeWhenDisabled() {
        let urls = expandTildePaths("~/foo", expandTilde: false)
        XCTAssertEqual(urls.map(\.path), ["~/foo"])
    }

    func testExpandTildePathsReturnsEmptyForNil() {
        XCTAssertTrue(expandTildePaths(nil, expandTilde: true).isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentAdapterTests
```

Expected: 编译失败，`cannot find 'ParseContext' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Collectors/AgentAdapter.swift`：

```swift
import Foundation

/// 解析单个文件时的可变上下文。
///
/// 存在的唯一理由是 Codex 的 model 为 sticky：由 `type == "turn_context"`
/// 行设定，供后续 `token_count` 行使用。Claude 不需要它。
struct ParseContext {
    var stickyModel: String?
    init() {}
}

/// 一个 coding agent 的数据接入点。
///
/// 新增 agent 只需实现本协议（见子项目②③），无需触碰算法层。
protocol AgentAdapter {
    /// 稳定标识，写入 `UsageEntry.agent`。
    var id: String { get }

    /// 发现该 agent 的全部 session 文件。
    func discoverFiles() -> [URL]

    /// 解析一行。非用量行返回 nil（但仍可能更新 context）。
    func parse(line: String, context: inout ParseContext) -> UsageEntry?

    /// 从**任意**一行提取时间戳，供 tail-probe 判断文件是否需要回扫。
    /// 末行未必是用量行，故不能复用 `parse`。
    func timestamp(fromLine line: String) -> Date?
}

/// 解析逗号分隔的路径列表。
///
/// `expandTilde` 对齐 ccusage 的差异行为：`CLAUDE_CONFIG_DIR` 展开 `~`，
/// 而 `CODEX_HOME` **不**展开。
func expandTildePaths(_ raw: String?, expandTilde: Bool) -> [URL] {
    guard let raw else { return [] }
    return raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { path in
            let expanded = expandTilde ? (path as NSString).expandingTildeInPath : path
            return URL(fileURLWithPath: expanded)
        }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AgentAdapterTests
```

Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Collectors/AgentAdapter.swift client/VibeCompanion/Tests/AgentAdapterTests.swift
git commit -m "$(cat <<'EOF'
feat(collectors): 添加 AgentAdapter 协议

per-file 的 ParseContext 承载 Codex 的 sticky model；
timestamp(fromLine:) 供 tail-probe 判断是否需要回扫。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: ClaudeAdapter

**Files:**
- Create: `client/VibeCompanion/Sources/Collectors/ClaudeAdapter.swift`
- Test: `client/VibeCompanion/Tests/ClaudeAdapterTests.swift`

**Interfaces:**
- Consumes: `AgentAdapter` / `ParseContext`（Task 1）、`UsageEntry` / `TokenCounts`（P1）、`claudeDedupKey`（P1）
- Produces: `struct ClaudeAdapter: AgentAdapter` — `init(roots: [URL]? = nil)`

**背景（真实数据形态，实测自本机）：**

```json
{"type":"assistant","uuid":"...","requestId":"req_...","sessionId":"...",
 "isSidechain":false,"timestamp":"2026-07-25T07:42:13.456Z",
 "message":{"id":"msg_...","model":"claude-opus-5",
   "usage":{"input_tokens":2,"output_tokens":557,
     "cache_creation_input_tokens":22240,"cache_read_input_tokens":20749,
     "cache_creation":{"ephemeral_1h_input_tokens":22240,"ephemeral_5m_input_tokens":0},
     "speed":"standard"}}}
```

要点：
- `cache_creation` 对象存在时**拆 5m/1h 并忽略**扁平的 `cache_creation_input_tokens`（实测 2615/2615 条都带该对象）
- 去重键是 `message.id:requestId`，**不是** `uuid`
- ccusage 的行判定**不检查** `type == "assistant"`，而是"含 usage 且能解码且 timestamp 与 message.usage 均存在"

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/ClaudeAdapterTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class ClaudeAdapterTests: XCTestCase {

    private let adapter = ClaudeAdapter(roots: [])

    private func parse(_ json: String) -> UsageEntry? {
        var ctx = ParseContext()
        return adapter.parse(line: json, context: &ctx)
    }

    private let full = """
    {"type":"assistant","uuid":"u1","requestId":"req_1","sessionId":"s1",
     "isSidechain":false,"timestamp":"2026-07-25T07:42:13.456Z",
     "message":{"id":"msg_1","model":"claude-opus-5",
       "usage":{"input_tokens":2,"output_tokens":557,
         "cache_creation_input_tokens":22240,"cache_read_input_tokens":20749,
         "cache_creation":{"ephemeral_1h_input_tokens":22240,"ephemeral_5m_input_tokens":0},
         "speed":"standard"}}}
    """

    func testParsesAllTokenBuckets() {
        let e = parse(full)!
        XCTAssertEqual(e.counts.input, 2)
        XCTAssertEqual(e.counts.output, 557)
        XCTAssertEqual(e.counts.cacheRead, 20749)
        XCTAssertEqual(e.counts.cacheCreation1h, 22240)
        XCTAssertEqual(e.counts.cacheCreation5m, 0)
        XCTAssertEqual(e.counts.extraTotal, 0)
    }

    func testAgentIdAndModelAndSession() {
        let e = parse(full)!
        XCTAssertEqual(e.agent, "claude")
        XCTAssertEqual(e.model, "claude-opus-5")
        XCTAssertEqual(e.sessionId, "s1")
    }

    func testDedupKeyUsesMessageIdAndRequestIdNotUuid() {
        XCTAssertEqual(parse(full)!.dedupKey, "msg_1:req_1")
    }

    func testTimestampParsedAsUTC() {
        let e = parse(full)!
        // 2026-07-25T07:42:13.456Z == 1784965333.456
        XCTAssertEqual(e.timestamp.timeIntervalSince1970, 1_784_965_333.456, accuracy: 0.002)
    }

    func testSpeedStandardIsNotFastButIsPresent() {
        let e = parse(full)!
        XCTAssertTrue(e.hasSpeed)
        XCTAssertFalse(e.isFastSpeed)
    }

    func testSpeedFastDetected() {
        let json = full.replacingOccurrences(of: "\"speed\":\"standard\"", with: "\"speed\":\"fast\"")
        let e = parse(json)!
        XCTAssertTrue(e.hasSpeed)
        XCTAssertTrue(e.isFastSpeed)
    }

    func testMissingSpeedFieldMarksHasSpeedFalse() {
        let json = full.replacingOccurrences(of: ",\"speed\":\"standard\"", with: "")
        let e = parse(json)!
        XCTAssertFalse(e.hasSpeed)
        XCTAssertFalse(e.isFastSpeed)
    }

    func testSidechainFlagParsed() {
        let json = full.replacingOccurrences(of: "\"isSidechain\":false",
                                             with: "\"isSidechain\":true")
        XCTAssertTrue(parse(json)!.isSidechain)
    }

    /// cache_creation 对象存在时，扁平字段被完全忽略
    func testNestedCacheCreationOverridesFlatField() {
        let json = """
        {"timestamp":"2026-07-25T07:00:00.000Z","requestId":"r","message":{"id":"m",
          "usage":{"input_tokens":1,"output_tokens":1,
            "cache_creation_input_tokens":99999,
            "cache_creation":{"ephemeral_1h_input_tokens":10,"ephemeral_5m_input_tokens":20}}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.cacheCreation1h, 10)
        XCTAssertEqual(e.counts.cacheCreation5m, 20)
        XCTAssertEqual(e.counts.cacheCreationTotal, 30)
    }

    /// 无 cache_creation 对象时，扁平字段整体计入 5m 档
    func testFlatCacheCreationGoesTo5mBucketWhenObjectAbsent() {
        let json = """
        {"timestamp":"2026-07-25T07:00:00.000Z","requestId":"r","message":{"id":"m",
          "usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":777}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.cacheCreation5m, 777)
        XCTAssertEqual(e.counts.cacheCreation1h, 0)
    }

    // MARK: 拒绝的行

    func testRejectsLineWithoutUsage() {
        XCTAssertNil(parse("""
        {"type":"user","timestamp":"2026-07-25T07:00:00.000Z","message":{"id":"m"}}
        """))
    }

    func testRejectsLineWithoutTimestamp() {
        XCTAssertNil(parse("""
        {"message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}
        """))
    }

    func testRejectsMalformedJson() {
        XCTAssertNil(parse("{not json"))
    }

    /// 不检查 type == "assistant"（对齐 ccusage）
    func testAcceptsUsageLineWithUnexpectedType() {
        let json = """
        {"type":"whatever","timestamp":"2026-07-25T07:00:00.000Z","requestId":"r",
         "message":{"id":"m","usage":{"input_tokens":5,"output_tokens":6}}}
        """
        XCTAssertEqual(parse(json)!.counts.input, 5)
    }

    // MARK: timestamp(fromLine:)

    func testTimestampFromNonUsageLine() {
        let ts = adapter.timestamp(fromLine: """
        {"type":"user","timestamp":"2026-07-25T07:42:13.456Z"}
        """)
        XCTAssertEqual(ts!.timeIntervalSince1970, 1_784_965_333.456, accuracy: 0.002)
    }

    func testTimestampNilForMalformedLine() {
        XCTAssertNil(adapter.timestamp(fromLine: "garbage"))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClaudeAdapterTests
```

Expected: 编译失败，`cannot find 'ClaudeAdapter' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Collectors/ClaudeAdapter.swift`：

```swift
import Foundation

/// Claude Code 数据适配器。
struct ClaudeAdapter: AgentAdapter {
    let id = "claude"

    /// nil 表示按环境变量与默认位置自行解析。测试可传 `[]` 关闭文件发现。
    private let explicitRoots: [URL]?

    init(roots: [URL]? = nil) {
        self.explicitRoots = roots
    }

    /// `$CLAUDE_CONFIG_DIR`（逗号分隔，展开 `~`）否则
    /// `${XDG_CONFIG_HOME:-~/.config}/claude` 与 `~/.claude`，
    /// 各需存在 `projects/` 子目录。
    private var roots: [URL] {
        if let explicitRoots { return explicitRoots }
        let env = ProcessInfo.processInfo.environment
        let configured = expandTildePaths(env["CLAUDE_CONFIG_DIR"], expandTilde: true)
        if !configured.isEmpty { return configured }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        return [xdg.appendingPathComponent("claude"), home.appendingPathComponent(".claude")]
    }

    func discoverFiles() -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for root in roots {
            let projects = root.appendingPathComponent("projects")
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDir),
                  isDir.boolValue,
                  let e = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let resolved = url.resolvingSymlinksInPath()
                if seen.insert(resolved).inserted { out.append(resolved) }
            }
        }
        return out
    }

    func parse(line: String, context: inout ParseContext) -> UsageEntry? {
        // 廉价前置过滤，避免对绝大多数非用量行做完整 JSON 解码
        guard line.contains("\"usage\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = DateParsing.parseISO8601(tsString),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        // cache_creation 对象存在时拆两档，并忽略扁平字段
        let cc5m: Int, cc1h: Int
        if let breakdown = usage["cache_creation"] as? [String: Any] {
            cc5m = breakdown["ephemeral_5m_input_tokens"] as? Int ?? 0
            cc1h = breakdown["ephemeral_1h_input_tokens"] as? Int ?? 0
        } else {
            cc5m = usage["cache_creation_input_tokens"] as? Int ?? 0
            cc1h = 0
        }

        let speed = usage["speed"] as? String

        return UsageEntry(
            timestamp: timestamp,
            agent: id,
            sessionId: obj["sessionId"] as? String,
            model: message["model"] as? String,
            counts: TokenCounts(input: usage["input_tokens"] as? Int ?? 0,
                                output: usage["output_tokens"] as? Int ?? 0,
                                cacheCreation5m: cc5m,
                                cacheCreation1h: cc1h,
                                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                                extraTotal: 0),
            isSidechain: obj["isSidechain"] as? Bool ?? false,
            hasSpeed: speed != nil,
            isFastSpeed: speed == "fast",
            dedupKey: claudeDedupKey(messageId: message["id"] as? String,
                                     requestId: obj["requestId"] as? String)
        )
    }

    func timestamp(fromLine line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["timestamp"] as? String
        else { return nil }
        return DateParsing.parseISO8601(ts)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ClaudeAdapterTests
```

Expected: `Executed 16 tests, with 0 failures`

> 若时间戳测试失败，检查 `Core/DateParsing.swift` 的 `parseISO8601` 是否支持小数秒。真实数据形如 `2026-07-25T07:42:13.456Z`，必须带 `.withFractionalSeconds`。若不支持，在 `DateParsing` 中补一个带小数秒的 formatter 并回退到不带小数秒的版本，同时给 `DateParsingTests.swift` 补一条小数秒用例。

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Collectors/ClaudeAdapter.swift client/VibeCompanion/Tests/ClaudeAdapterTests.swift
git commit -m "$(cat <<'EOF'
feat(collectors): 添加 ClaudeAdapter

去重键改为 messageId:requestId；cache_creation 对象存在时拆 5m/1h
并忽略扁平字段；行判定不再检查 type=="assistant"（对齐 ccusage）。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: CodexAdapter

**Files:**
- Create: `client/VibeCompanion/Sources/Collectors/CodexAdapter.swift`
- Test: `client/VibeCompanion/Tests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: `AgentAdapter` / `ParseContext`（Task 1）、`UsageEntry` / `TokenCounts`（P1）
- Produces: `struct CodexAdapter: AgentAdapter` — `init(roots: [URL]? = nil)`

**背景（真实数据形态，实测自本机）：**

```json
{"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
 "payload":{"type":"token_count","info":{
   "last_token_usage":{"input_tokens":19732,"cached_input_tokens":0,
     "output_tokens":67,"reasoning_output_tokens":0,"total_tokens":19799}}}}
```

**这是当前实现的 bug 所在**（`Collector.swift:145-152`）：`cached_input_tokens` **嵌套在 `input_tokens` 内部**，必须相减。ccusage 在 `parser.rs:305` 先 clamp（`cached.min(input)`），在 `report.rs:82-84` 相减。

另外三条：
- `total_tokens` **直取文件自带值**，不重算
- `reasoning_output_tokens` 已含在 `output_tokens` 内，**不得再加**
- Codex 无缓存写入概念，两个 cacheCreation 桶恒为 0

由于 `total` 直取而分桶之和可能小于它，差额进 `extraTotal`，使 `TokenCounts.total` 与文件一致。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/CodexAdapterTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class CodexAdapterTests: XCTestCase {

    private let adapter = CodexAdapter(roots: [])

    private func parse(_ json: String, context: inout ParseContext) -> UsageEntry? {
        adapter.parse(line: json, context: &context)
    }

    private func parse(_ json: String) -> UsageEntry? {
        var ctx = ParseContext()
        return adapter.parse(line: json, context: &ctx)
    }

    private func tokenCount(input: Int, cached: Int, output: Int,
                            reasoning: Int, total: Int) -> String {
        """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"token_count","info":{
           "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),
             "output_tokens":\(output),"reasoning_output_tokens":\(reasoning),
             "total_tokens":\(total)}}}}
        """
    }

    /// 核心修复：cached 嵌套在 input 内，必须相减
    func testCachedInputIsSubtractedFromInput() {
        let e = parse(tokenCount(input: 100, cached: 90, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.input, 10)          // 100 - 90
        XCTAssertEqual(e.counts.cacheRead, 90)
        XCTAssertEqual(e.counts.output, 5)
    }

    /// cached 超过 input 时先 clamp，避免负数
    func testCachedIsClampedToInput() {
        let e = parse(tokenCount(input: 50, cached: 80, output: 5,
                                 reasoning: 0, total: 55))!
        XCTAssertEqual(e.counts.input, 0)
        XCTAssertEqual(e.counts.cacheRead, 50)
    }

    func testNoCacheCreationBuckets() {
        let e = parse(tokenCount(input: 100, cached: 0, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.cacheCreation5m, 0)
        XCTAssertEqual(e.counts.cacheCreation1h, 0)
    }

    /// total 直取文件值，差额进 extraTotal
    func testTotalMatchesFileValue() {
        let e = parse(tokenCount(input: 100, cached: 90, output: 5,
                                 reasoning: 0, total: 105))!
        XCTAssertEqual(e.counts.total, 105)
    }

    /// reasoning 已含在 output 内，不得重复相加
    func testReasoningIsNotAddedSeparately() {
        // input 100 (cached 0) + output 20，其中 reasoning 15 已在 output 内
        let e = parse(tokenCount(input: 100, cached: 0, output: 20,
                                 reasoning: 15, total: 120))!
        XCTAssertEqual(e.counts.output, 20)
        XCTAssertEqual(e.counts.total, 120)         // 不是 135
    }

    func testTotalFallsBackWhenFileTotalMissing() {
        let json = """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"token_count","info":{
           "last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}}}
        """
        let e = parse(json)!
        XCTAssertEqual(e.counts.total, 107)         // 60 + 40 + 7
        XCTAssertEqual(e.counts.extraTotal, 0)
    }

    func testAgentId() {
        XCTAssertEqual(parse(tokenCount(input: 1, cached: 0, output: 1,
                                        reasoning: 0, total: 2))!.agent, "codex")
    }

    // MARK: sticky model

    func testTurnContextSetsStickyModelForLaterLines() {
        var ctx = ParseContext()
        let turn = """
        {"timestamp":"2026-07-16T13:16:00.000Z","type":"turn_context",
         "payload":{"model":"gpt-5.3-codex"}}
        """
        XCTAssertNil(parse(turn, context: &ctx))
        XCTAssertEqual(ctx.stickyModel, "gpt-5.3-codex")

        let e = parse(tokenCount(input: 10, cached: 0, output: 1,
                                 reasoning: 0, total: 11), context: &ctx)!
        XCTAssertEqual(e.model, "gpt-5.3-codex")
    }

    func testModelIsNilWithoutTurnContext() {
        XCTAssertNil(parse(tokenCount(input: 1, cached: 0, output: 1,
                                      reasoning: 0, total: 2))!.model)
    }

    // MARK: 去重键

    /// 去重键由 (timestamp, model, 各 token 值) 组成，不含 sessionId
    func testDedupKeyIsStableForIdenticalRecords() {
        let a = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        let b = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        XCTAssertEqual(a.dedupKey, b.dedupKey)
        XCTAssertNotNil(a.dedupKey)
    }

    func testDedupKeyDiffersWhenTokensDiffer() {
        let a = parse(tokenCount(input: 10, cached: 2, output: 3, reasoning: 0, total: 13))!
        let b = parse(tokenCount(input: 11, cached: 2, output: 3, reasoning: 0, total: 14))!
        XCTAssertNotEqual(a.dedupKey, b.dedupKey)
    }

    // MARK: 拒绝的行

    func testRejectsNonTokenCountPayload() {
        XCTAssertNil(parse("""
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg",
         "payload":{"type":"agent_message","message":"hi"}}
        """))
    }

    func testRejectsMalformedJson() {
        XCTAssertNil(parse("{nope"))
    }

    // MARK: timestamp(fromLine:)

    func testTimestampFromArbitraryLine() {
        let ts = adapter.timestamp(fromLine: """
        {"timestamp":"2026-07-16T13:16:40.694Z","type":"event_msg","payload":{}}
        """)
        XCTAssertEqual(ts!.timeIntervalSince1970, 1_784_207_800.694, accuracy: 0.002)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CodexAdapterTests
```

Expected: 编译失败，`cannot find 'CodexAdapter' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `client/VibeCompanion/Sources/Collectors/CodexAdapter.swift`：

```swift
import Foundation

/// OpenAI Codex CLI 数据适配器。
struct CodexAdapter: AgentAdapter {
    let id = "codex"

    private let explicitRoots: [URL]?

    init(roots: [URL]? = nil) {
        self.explicitRoots = roots
    }

    /// `$CODEX_HOME`（逗号分隔，**不**展开 `~`——对齐 ccusage）否则 `~/.codex`。
    private var roots: [URL] {
        if let explicitRoots { return explicitRoots }
        let configured = expandTildePaths(ProcessInfo.processInfo.environment["CODEX_HOME"],
                                          expandTilde: false)
        if !configured.isEmpty { return configured }
        return [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")]
    }

    /// `sessions/**/*.jsonl` 与 `archived_sessions/**/*.jsonl`。
    /// **无** `rollout-*` 前缀过滤（对齐 ccusage）。
    func discoverFiles() -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for root in roots {
            for sub in ["sessions", "archived_sessions"] {
                let dir = root.appendingPathComponent(sub)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                      isDir.boolValue,
                      let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
                else { continue }
                for case let url as URL in e where url.pathExtension == "jsonl" {
                    let resolved = url.resolvingSymlinksInPath()
                    if seen.insert(resolved).inserted { out.append(resolved) }
                }
            }
        }
        return out
    }

    func parse(line: String, context: inout ParseContext) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else { return nil }

        // turn_context 只更新 sticky model，不产出 entry
        if obj["type"] as? String == "turn_context" {
            if let model = payload["model"] as? String { context.stickyModel = model }
            return nil
        }

        guard obj["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let timestamp = DateParsing.parseISO8601(tsString)
        else { return nil }

        let rawInput = usage["input_tokens"] as? Int ?? 0
        let rawCached = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0

        // cached 嵌套在 input 内：先 clamp 再相减。
        // 当前实现漏了这一步，导致 cached 被重复计算。
        let cached = min(rawCached, rawInput)
        let nonCachedInput = rawInput - cached

        // total 直取文件值；reasoning 已含在 output 内，回退式才用它。
        let fileTotal = usage["total_tokens"] as? Int
        let bucketSum = nonCachedInput + cached + output
        let total = fileTotal ?? (nonCachedInput + cached + output + reasoning)
        // 差额进 extraTotal，保证 TokenCounts.total 与文件一致
        let extra = max(0, total - bucketSum)

        let counts = TokenCounts(input: nonCachedInput, output: output,
                                 cacheCreation5m: 0, cacheCreation1h: 0,
                                 cacheRead: cached, extraTotal: extra)

        // 去重键：时间戳 + model + 各 token 值，不含 sessionId（对齐 ccusage）
        let key = [tsString, context.stickyModel ?? "",
                   String(rawInput), String(rawCached), String(output),
                   String(reasoning), String(total)].joined(separator: "|")

        return UsageEntry(
            timestamp: timestamp,
            agent: id,
            sessionId: obj["session_id"] as? String ?? payload["session_id"] as? String,
            model: context.stickyModel,
            counts: counts,
            isSidechain: false,
            hasSpeed: false,
            isFastSpeed: false,
            dedupKey: key
        )
    }

    func timestamp(fromLine line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["timestamp"] as? String
        else { return nil }
        return DateParsing.parseISO8601(ts)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CodexAdapterTests
```

Expected: `Executed 14 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add client/VibeCompanion/Sources/Collectors/CodexAdapter.swift client/VibeCompanion/Tests/CodexAdapterTests.swift
git commit -m "$(cat <<'EOF'
fix(collectors): CodexAdapter 修正 cached_input_tokens 双计算

cached_input_tokens 嵌套在 input_tokens 内部，须先 clamp 再相减；
total_tokens 直取文件值，差额进 extraTotal；reasoning 已含在
output 内不得重复相加。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: TailProbe 与 JsonlTailer 回扫

**Files:**
- Create: `client/VibeCompanion/Sources/Collectors/TailProbe.swift`
- Modify: `client/VibeCompanion/Sources/Collectors/JsonlTailer.swift:36-41`（`watch` 签名）、`:53-85`（`startWatching`）、`:87-121`（`readNew`）
- Test: `client/VibeCompanion/Tests/TailProbeTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum TailProbe { static func lastCompleteLine(of url: URL, probeBytes: Int = 8192) -> String? }`
  - `JsonlTailer.watch(_ url: URL, startAtBeginning: Bool)` —— **签名变更**，原 `watch(_:)` 被替换

**⚠️ 必须一并修复的既有缺陷：** `JsonlTailer.readNew`（`JsonlTailer.swift:106-110`）当前是：

```swift
let read = read(fd, buffer, Int(toRead))
guard read > 0 else { return }
let data = Data(bytes: buffer, count: Int(read))
offsets[url] = currentSize          // ← 无论实际读了多少，都把 offset 推到 EOF
```

单次 `read(2)` **不保证**返回请求的全部字节。现有代码在 offset 定位到 EOF 时增量很小，几乎读不出问题；但本任务引入从 offset 0 起的回扫后，单次请求会达到 MB 级（本机最大文件 2.65 MB），部分读将**静默丢数据**。修法是把 offset 推进到实际读取量：`offsets[url] = offset + Int64(read)`，并循环读到无更多数据。

- [ ] **Step 1: 写失败的测试**

创建 `client/VibeCompanion/Tests/TailProbeTests.swift`：

```swift
import XCTest
@testable import VibeCompanion

final class TailProbeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String, name: String = "a.jsonl") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReturnsLastCompleteLine() throws {
        let url = try write("first\nsecond\nthird\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url), "third")
    }

    /// 末尾没有换行符时，最后一行仍算完整（文件可能正在被追加，但这是我们能拿到的最新一行）
    func testReturnsTrailingLineWithoutNewline() throws {
        let url = try write("first\nsecond")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url), "second")
    }

    func testSingleLineFile() throws {
        XCTAssertEqual(TailProbe.lastCompleteLine(of: try write("only")), "only")
    }

    func testEmptyFileReturnsNil() throws {
        XCTAssertNil(TailProbe.lastCompleteLine(of: try write("")))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(TailProbe.lastCompleteLine(of: dir.appendingPathComponent("nope.jsonl")))
    }

    /// 探测窗口只覆盖文件尾部：前面的内容不影响结果
    func testOnlyReadsTailWindow() throws {
        let filler = String(repeating: "x", count: 40_000)
        let url = try write("\(filler)\nlast-line\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url, probeBytes: 1024), "last-line")
    }

    /// 探测窗口切在多字节字符中间时不得崩溃，也不得返回乱码行
    func testHandlesMultibyteSplitAtWindowBoundary() throws {
        let url = try write("你好世界\n最后一行\n")
        XCTAssertEqual(TailProbe.lastCompleteLine(of: url, probeBytes: 10), "最后一行")
    }

    /// 窗口内一个换行都没有（末行超长）时返回 nil，调用方应保守回扫
    func testReturnsNilWhenNoNewlineInWindow() throws {
        let url = try write(String(repeating: "y", count: 5000))
        XCTAssertNil(TailProbe.lastCompleteLine(of: url, probeBytes: 100))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TailProbeTests
```

Expected: 编译失败，`cannot find 'TailProbe' in scope`。

- [ ] **Step 3: 写 TailProbe**

创建 `client/VibeCompanion/Sources/Collectors/TailProbe.swift`：

```swift
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
```

- [ ] **Step 4: 运行 TailProbe 测试确认通过**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TailProbeTests
```

Expected: `Executed 8 tests, with 0 failures`

- [ ] **Step 5: 改造 JsonlTailer**

修改 `client/VibeCompanion/Sources/Collectors/JsonlTailer.swift`。

把类文档注释（`:22-23`）改为：

```swift
/// 监听 JSONL 文件增长，自维护 byte offset 游标。
/// `watch(_:startAtBeginning:)` 决定首次定位到文件头还是 EOF——
/// 回扫与实时尾随因此共用同一条读取路径，中间没有漏数据的窗口。
```

把 `watch`（`:35-41`）替换为：

```swift
    /// 开始监听一个文件。
    /// - Parameter startAtBeginning: true 表示从文件头读起（回扫历史），
    ///   false 表示定位到 EOF（只看后续新增）。
    func watch(_ url: URL, startAtBeginning: Bool) {
        queue.sync {
            guard descriptors[url] == nil else { return }
            startWatching(url, startAtBeginning: startAtBeginning)
        }
    }
```

把 `startWatching` 签名与首次定位逻辑（`:53-65`）替换为：

```swift
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
```

把 `readNew`（`:87-121`）整体替换为：

```swift
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
```

- [ ] **Step 6: 跑全量测试确认没破坏现有行为**

```bash
cd client && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: 全部通过。`LineSplitter` 的 4 个既有测试尤其要绿——它们覆盖了跨块的半行与多字节字符，正是本次分块循环依赖的性质。

> 此时 `Collector.swift:19` 仍在调用旧的 `tailer.watch(f)`，编译会因签名变更而失败。这是预期的——Task 5 修复它。若希望本任务独立可编译，可在 Step 5 后先把 `Collector.swift:19` 临时改为 `tailer.watch(f, startAtBeginning: false)`（行为与改造前完全一致），Task 5 再替换为真正的回扫决策。

- [ ] **Step 7: 提交**

```bash
git add client/VibeCompanion/Sources/Collectors/TailProbe.swift client/VibeCompanion/Tests/TailProbeTests.swift client/VibeCompanion/Sources/Collectors/JsonlTailer.swift client/VibeCompanion/Sources/Collectors/Collector.swift
git commit -m "$(cat <<'EOF'
feat(collectors): JsonlTailer 支持历史回扫，修复部分读丢数据

watch 增加 startAtBeginning 参数，回扫与尾随共用同一条读取路径；
readNew 改为分块循环并按实际读取量推进 offset——原实现无论 read(2)
实际返回多少都把 offset 推到 EOF，回扫 MB 级文件时会静默丢数据。
新增 TailProbe 只读 8KB 尾部判断文件是否需要回扫。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 剩余任务

本文档篇幅所限，Task 5–7 见续篇 `2026-07-25-ccusage-p3b-wiring.md`：

- **Task 5**：`Collector` 改为 adapter 调度 + 回扫决策
- **Task 6**：`TokenAggregator` 重写（`UsageWindow` + 分块重算 + idle + cost 注入 + 今日累计改用 24h 窗口去重）
- **Task 7**：golden fixture 端到端校验（脱敏 JSONL 快照 + 与 `npx ccusage@20 blocks --active` 交叉验证）
