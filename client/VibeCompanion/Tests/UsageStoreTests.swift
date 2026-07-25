import XCTest
import GRDB
@testable import VibeCompanion

final class UsageStoreTests: XCTestCase {
    func testRecoverStuckRequeues() throws {
        let tmp = NSTemporaryDirectory() + "vc-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = try UsageStore(path: tmp)
        try store.enqueue(UsageEvent(sourceUuid: "u1", agent: "claude", sessionId: nil, model: nil,
            inputTokens: 1, outputTokens: 1, cacheCreationTokens: 0, cacheReadTokens: 0,
            reasoningTokens: 0, totalTokens: 2, recordedAt: 1))
        _ = try store.fetchPending(limit: 10)             // marks it 'uploading'
        XCTAssertEqual(try store.pendingCount(), 0)

        let reopened = try UsageStore(path: tmp)           // init runs recoverStuck
        XCTAssertEqual(try reopened.pendingCount(), 1)
    }
}
