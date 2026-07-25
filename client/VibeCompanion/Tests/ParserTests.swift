import XCTest
@testable import VibeCompanion

final class ParserTests: XCTestCase {
    func testClaudeAssistant() {
        let obj: [String: Any] = [
            "type": "assistant", "uuid": "abc", "sessionId": "s1",
            "timestamp": "2026-07-25T09:30:00.000Z",
            "message": ["model": "claude-opus-4-8",
                        "usage": ["input_tokens": 10, "output_tokens": 20,
                                  "cache_creation_input_tokens": 5, "cache_read_input_tokens": 100]],
        ]
        let ev = ClaudeParser.parse(obj)
        XCTAssertEqual(ev?.sourceUuid, "abc")
        XCTAssertEqual(ev?.totalTokens, 135)
        XCTAssertEqual(ev?.effectiveTokens, 35)
    }
    func testClaudeIgnoresNonAssistant() {
        XCTAssertNil(ClaudeParser.parse(["type": "user"]))
    }
    func testCodexTokenCount() {
        let obj: [String: Any] = [
            "timestamp": "2026-07-25T09:30:00Z",
            "payload": ["type": "token_count", "session_id": "cs1",
                        "info": ["model": "gpt-5",
                                 "last_token_usage": ["input_tokens": 1, "cached_input_tokens": 2,
                                                      "output_tokens": 3, "reasoning_output_tokens": 4,
                                                      "total_tokens": 10]]],
        ]
        let ev = CodexParser.parse(obj)
        XCTAssertEqual(ev?.agent, "codex")
        XCTAssertEqual(ev?.totalTokens, 10)
        XCTAssertEqual(ev?.cacheReadTokens, 2)
    }
}
