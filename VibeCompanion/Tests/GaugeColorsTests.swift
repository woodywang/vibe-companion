import XCTest
import SwiftUI
import AppKit
@testable import VibeCompanion

/// 表盘 / 菜单栏 / 速率气泡三处共用同一份 zone→Color 映射。
final class GaugeColorsTests: XCTestCase {

    private func rgb(_ c: Color, file: StaticString = #filePath,
                     line: UInt = #line) -> (Double, Double, Double) {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else {
            XCTFail("无法转换到 sRGB", file: file, line: line)
            return (-1, -1, -1)
        }
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func assertColor(_ c: Color, hex: UInt32,
                             file: StaticString = #filePath, line: UInt = #line) {
        let (r, g, b) = rgb(c, file: file, line: line)
        XCTAssertEqual(r, Double((hex >> 16) & 0xFF) / 255, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(g, Double((hex >> 8) & 0xFF) / 255, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(b, Double(hex & 0xFF) / 255, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: zone → Color

    func testZoneColorsCoverAllThreeZones() {
        assertColor(gaugeZoneColor(.green), hex: 0x3D_D6_8C)
        assertColor(gaugeZoneColor(.yellow), hex: 0xE8_B3_39)
        assertColor(gaugeZoneColor(.red), hex: 0xE5_48_4D)
    }

    // MARK: 速率 → Color（经 gaugeZone，按指针行程比例）

    func testColorFollowsGaugeZoneOnLinearScale() {
        let s = LinearGaugeScale(maxValue: 1_000_000)
        // 阈值为行程比例 0.60 / 0.85，线性量程下等于数值比例
        assertColor(gaugeColor(tokensPerMinute: 100_000, hasBurnRate: true, scale: s),
                    hex: 0x3D_D6_8C)
        assertColor(gaugeColor(tokensPerMinute: 700_000, hasBurnRate: true, scale: s),
                    hex: 0xE8_B3_39)
        assertColor(gaugeColor(tokensPerMinute: 900_000, hasBurnRate: true, scale: s),
                    hex: 0xE5_48_4D)
    }

    /// 关键：分区按角度行程而非 value/maxValue。对数量程下 100k 只有 10% 的
    /// 数值比例，却已走过 50% 行程——两种口径颜色会不同。
    func testColorUsesSweepFractionNotValueFractionOnLogScale() {
        let s = LogGaugeScale(minValue: 10_000, maxValue: 1_000_000)
        // 行程 50% -> 绿；若按 value/maxValue = 10% 也是绿，换个点才能分辨
        assertColor(gaugeColor(tokensPerMinute: 316_228, hasBurnRate: true, scale: s),
                    hex: 0xE8_B3_39)     // 行程 75%，数值比例仅 31.6%
        assertColor(gaugeColor(tokensPerMinute: 700_000, hasBurnRate: true, scale: s),
                    hex: 0xE5_48_4D)     // 行程 ~92%，数值比例 70%
        XCTAssertEqual(gaugeZone(value: 316_228, scale: s), .yellow)
    }

    /// 无速率时（显示 `--`、指针归零）三处一致地按绿区处理。
    func testNoBurnRateFallsBackToGreen() {
        let s = LinearGaugeScale(maxValue: 1_000_000)
        assertColor(gaugeColor(tokensPerMinute: 900_000, hasBurnRate: false, scale: s),
                    hex: 0x3D_D6_8C)
    }
}
