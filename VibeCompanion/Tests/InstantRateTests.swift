import XCTest
@testable import VibeCompanion

final class InstantRateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_785_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: 稳态（本公式的正确性判据）

    /// **核心性质**：以恒定流量 F tok/min 持续喂入，`value` 收敛到 F。
    ///
    /// 这条比逐点断言更有意义——它检验的是「读数的单位与量纲确实是
    /// tok/min」，而不是某个中间值恰好等于某个魔数。
    ///
    /// 离散化会引入一点**系统性高估**：稳态解为
    /// `F · (Δ/τ) / (1 − exp(−Δ/τ))`，Δ 是喂入间隔。Δ/τ → 0 时该系数 → 1；
    /// 此处 Δ=0.5 秒、τ=30 秒，系数约 1.0083，故留 2% 余量。
    func testConvergesToConstantFlow() {
        for flow in [60_000.0, 613_000.0, 6_020_000.0] {
            var ema = InstantRateEMA(tau: 30)
            let step = 0.5
            let perRecord = flow * step / 60      // 每 step 秒投入的 token 数
            var elapsed = 0.0
            // 20 分钟 = 40 个时间常数，远超收敛所需
            while elapsed < 1200 {
                elapsed += step
                ema.ingest(tokens: perRecord, at: at(elapsed))
            }
            XCTAssertEqual(ema.value, flow, accuracy: flow * 0.02,
                           "恒定流量 \(flow) tok/min 应收敛到自身")
        }
    }

    /// 时间常数不改变稳态值，只改变到达稳态的快慢。
    func testSteadyStateIsIndependentOfTau() {
        let flow = 500_000.0
        for tau in allInstantRateTauSeconds {
            var ema = InstantRateEMA(tau: tau)
            let step = 0.5
            let perRecord = flow * step / 60
            var elapsed = 0.0
            while elapsed < tau * 40 {
                elapsed += step
                ema.ingest(tokens: perRecord, at: at(elapsed))
            }
            XCTAssertEqual(ema.value, flow, accuracy: flow * 0.02, "τ=\(tau)")
        }
    }

    // MARK: 衰减

    /// 单次注入后经过一个时间常数，衰减到 1/e。
    func testSingleInjectionDecaysToOneOverEAfterTau() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 100_000, at: at(0))
        let peak = ema.value
        ema.advance(to: at(30))
        XCTAssertEqual(ema.value, peak / M_E, accuracy: peak * 1e-9)
    }

    /// 一条记录的即时贡献是 `v / τ * 60`。
    func testSingleInjectionMagnitude() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 30_000, at: at(0))
        XCTAssertEqual(ema.value, 60_000, accuracy: 1e-9)
    }

    /// 长时间无输入趋近 0（并被 floor 截断为精确的 0）。
    func testDecaysToZeroWithoutInput() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 1_000_000, at: at(0))
        XCTAssertGreaterThan(ema.value, 0)
        ema.advance(to: at(3600))
        XCTAssertEqual(ema.value, 0, accuracy: 1e-12)
    }

    /// 衰减是单调的，且中途仍为正——不能一步跳到 0。
    func testDecayIsMonotonicAndPositiveMidway() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 1_000_000, at: at(0))
        var previous = ema.value
        for s in stride(from: 5.0, through: 120.0, by: 5.0) {
            ema.advance(to: at(s))
            XCTAssertLessThan(ema.value, previous)
            XCTAssertGreaterThan(ema.value, 0, "\(s)s 时不该已经归零")
            previous = ema.value
        }
    }

    // MARK: 初始与乱序

    func testStartsAtZero() {
        XCTAssertEqual(InstantRateEMA(tau: 30).value, 0)
    }

    /// 第一次见到时间点只是对表，不产生衰减。
    func testFirstAdvanceOnlySetsTheClock() {
        var ema = InstantRateEMA(tau: 30)
        ema.advance(to: at(0))
        ema.ingest(tokens: 30_000, at: at(0))
        XCTAssertEqual(ema.value, 60_000, accuracy: 1e-9)
    }

    /// 倒退的时间戳（回扫 / 乱序到达）不得让时钟回走：
    /// 若回走，之后推进到真实的"现在"会把同一段时间重复衰减一次。
    func testOutOfOrderTimestampDoesNotRewindTheClock() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 30_000, at: at(100))
        ema.ingest(tokens: 30_000, at: at(50))     // 迟到的旧记录：计入，但不倒表
        let afterLate = ema.value
        XCTAssertEqual(afterLate, 120_000, accuracy: 1e-9)

        ema.advance(to: at(130))                   // 距 t=100 三十秒
        XCTAssertEqual(ema.value, afterLate / M_E, accuracy: afterLate * 1e-9)
    }

    func testZeroTokenRecordOnlyAdvancesTheClock() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 60_000, at: at(0))
        let peak = ema.value
        ema.ingest(tokens: 0, at: at(30))
        XCTAssertEqual(ema.value, peak / M_E, accuracy: peak * 1e-9)
    }

    // MARK: 响应快慢

    /// 小 τ 反馈更快：同一次注入后同一时刻，小 τ 的读数已更高地冲上去。
    func testSmallerTauRespondsFaster() {
        var fast = InstantRateEMA(tau: 15)
        var slow = InstantRateEMA(tau: 120)
        fast.ingest(tokens: 100_000, at: at(0))
        slow.ingest(tokens: 100_000, at: at(0))
        XCTAssertGreaterThan(fast.value, slow.value)
    }

    /// 小 τ 也衰减得更快：静置后小 τ 先落回去。
    func testSmallerTauDecaysFaster() {
        var fast = InstantRateEMA(tau: 15)
        var slow = InstantRateEMA(tau: 120)
        fast.ingest(tokens: 100_000, at: at(0))
        slow.ingest(tokens: 100_000, at: at(0))
        fast.advance(to: at(300))
        slow.advance(to: at(300))
        XCTAssertLessThan(fast.value, slow.value)
    }

    // MARK: 改档

    /// 改时间常数保留当前读数——否则用户一动设置指针就掉到底。
    func testRetuneKeepsCurrentReading() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 100_000, at: at(0))
        let before = ema.value
        ema.retune(tau: 120)
        XCTAssertEqual(ema.tau, 120)
        XCTAssertEqual(ema.value, before, accuracy: 1e-9)
    }

    /// 改档之后按新的时间常数衰减。
    func testRetuneAppliesNewTauToSubsequentDecay() {
        var ema = InstantRateEMA(tau: 30)
        ema.ingest(tokens: 100_000, at: at(0))
        let before = ema.value
        ema.retune(tau: 120)
        ema.advance(to: at(120))
        XCTAssertEqual(ema.value, before / M_E, accuracy: before * 1e-9)
    }

    // MARK: 档位表

    func testTauChoicesContainDefaultAndAreUnique() {
        XCTAssertTrue(allInstantRateTauSeconds.contains(defaultInstantRateTauSeconds))
        XCTAssertEqual(Set(allInstantRateTauSeconds).count, allInstantRateTauSeconds.count)
        for tau in allInstantRateTauSeconds {
            XCTAssertGreaterThan(tau, 0)
            XCTAssertFalse(instantRateTauLabel(tau).isEmpty)
        }
    }
}
