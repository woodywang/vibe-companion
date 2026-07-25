import XCTest
@testable import VibeCompanion

final class FakeTransport: Transport {
    var status: Int = 200
    var body: Data = Data(#"{"ok":true,"inserted":1,"duplicates":0}"#.utf8)
    var calls = 0
    func send(_ req: URLRequest, _ completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
        calls += 1
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)
        completion(body, resp, nil)
    }
}

final class UploaderTests: XCTestCase {
    func testAuthFailureBlocks() throws {
        Settings.shared.clientToken = "vc_test"; Settings.shared.isPaused = false
        let store = try UsageStore(path: NSTemporaryDirectory() + "up-\(UUID().uuidString).db")
        try store.enqueue(UsageEvent(sourceUuid: "u1", agent: "claude", sessionId: nil, model: nil,
            inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            reasoningTokens: 0, totalTokens: 1, recordedAt: 1))
        let t = FakeTransport(); t.status = 401
        let up = Uploader(store: store, transport: t, now: { Date() })
        up.flush()
        XCTAssertTrue(up.authBlocked)
        XCTAssertEqual(try store.pendingCount(), 1)   // data preserved
    }

    func testTransientFailureBacksOffWithoutAuthBlock() throws {
        Settings.shared.clientToken = "vc_test"; Settings.shared.isPaused = false
        let store = try UsageStore(path: NSTemporaryDirectory() + "up-\(UUID().uuidString).db")
        try store.enqueue(UsageEvent(sourceUuid: "u2", agent: "claude", sessionId: nil, model: nil,
            inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0,
            reasoningTokens: 0, totalTokens: 1, recordedAt: 1))
        let t = FakeTransport(); t.status = 500
        let up = Uploader(store: store, transport: t, now: { Date() })
        up.flush()
        XCTAssertFalse(up.authBlocked)
        XCTAssertNotNil(up.nextRetryAt)
        XCTAssertEqual(try store.pendingCount(), 1)   // data preserved
    }
}
