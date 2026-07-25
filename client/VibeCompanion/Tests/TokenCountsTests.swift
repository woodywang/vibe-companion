import XCTest
@testable import VibeCompanion

final class TokenCountsTests: XCTestCase {

    /// 对齐 ccusage types.rs:86-91 —— total 含全部六个桶
    func testTotalSumsAllBuckets() {
        let c = TokenCounts(input: 1, output: 2, cacheCreation5m: 4,
                            cacheCreation1h: 8, cacheRead: 16, extraTotal: 32)
        XCTAssertEqual(c.total, 63)
    }

    func testDefaultsAreZero() {
        XCTAssertEqual(TokenCounts().total, 0)
    }

    /// cacheCreationTotal 等价于 ccusage 的 cache_creation_token_count()
    func testCacheCreationTotalMergesBothTiers() {
        let c = TokenCounts(cacheCreation5m: 30, cacheCreation1h: 12)
        XCTAssertEqual(c.cacheCreationTotal, 42)
    }

    /// indicator 速率的分子：两个 cache 桶都排除
    func testInputPlusOutputExcludesCacheBuckets() {
        let c = TokenCounts(input: 7, output: 3, cacheCreation5m: 100,
                            cacheCreation1h: 200, cacheRead: 400)
        XCTAssertEqual(c.inputPlusOutput, 10)
    }

    func testAdditionCombinesBucketwise() {
        let a = TokenCounts(input: 1, output: 2, cacheCreation5m: 3,
                            cacheCreation1h: 4, cacheRead: 5, extraTotal: 6)
        let b = TokenCounts(input: 10, output: 20, cacheCreation5m: 30,
                            cacheCreation1h: 40, cacheRead: 50, extraTotal: 60)
        let s = a + b
        XCTAssertEqual(s, TokenCounts(input: 11, output: 22, cacheCreation5m: 33,
                                      cacheCreation1h: 44, cacheRead: 55, extraTotal: 66))
    }

    func testPlusEqualsAccumulates() {
        var acc = TokenCounts()
        acc += TokenCounts(input: 5)
        acc += TokenCounts(input: 5, output: 1)
        XCTAssertEqual(acc, TokenCounts(input: 10, output: 1))
    }
}
