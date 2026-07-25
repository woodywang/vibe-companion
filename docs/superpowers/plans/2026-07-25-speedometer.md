# 速度表悬浮动画 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用纯 SwiftUI 的老式汽车速度表替换悬浮窗现有 Lottie 蹬车动画，指针角度映射 token/min，带弹性弹簧动画。

**Architecture:** 新增纯逻辑层 `SpeedometerLogic`（角度映射/clamp/格式化，无 UI 依赖，可单测）+ SwiftUI `SpeedometerView`（绘制表盘/刻度/指针/LCD）+ 改 `FloatingPetContent` 接入。删除 Lottie 依赖、资源、`AppConfig.animationSpeed`。逻辑与视图分离便于 TDD。

**Tech Stack:** Swift 5.9, SwiftUI（macOS 13+）, SwiftPM, XCTest。移除 lottie-ios 依赖。

## Global Constraints

- 平台：macOS 13+（`.macOS(.v13)`）
- Swift 工具链 5.9
- 测试风格：`@testable import VibeCompanion` + `@MainActor`（对齐现有 `Tests/TokenAggregatorTests.swift`）
- 速率口径：`TokenAggregator.tokensPerMinute` 已是 effective 口径（排除 cache_read），直接使用，不再除/乘
- 角度映射常量：`min = -135°`, `max = +135°`, `maxValue = 16000 tok/min`（对应 1.0× 的 8000 tok/min 落在 0°）
- 提交粒度：每个 Task 末尾 commit；commit message 用 `feat/fix/refactor/chore` 前缀
- spec 文档：`docs/superpowers/specs/2026-07-25-speedometer-design.md`

---

## Task 1: 纯逻辑层 SpeedometerLogic + 单测

把角度映射/clamp/格式化做成纯函数，独立可测，无 SwiftUI 依赖。这是 TDD 起点，也是后续视图的唯一数据源。

**Files:**
- Create: `client/VibeCompanion/Sources/Core/SpeedometerLogic.swift`
- Test: `client/VibeCompanion/Tests/SpeedometerLogicTests.swift`

**Interfaces:**
- Produces:
  - `enum SpeedometerConfig` -- 常量：`angleMin = -135.0`, `angleMax = 135.0`, `valueMax = 16000.0`, `idleThreshold = 1.0`
  - `func speedometerAngle(tokensPerMinute: Double) -> Double` -- 映射并 clamp 到 [-135, 135]
  - `func speedometerIsIdle(tokensPerMinute: Double) -> Bool` -- `< idleThreshold`
  - `func speedometerFormat(_ rpm: Double) -> String` -- LCD 显示格式化

- [ ] **Step 1: 写失败测试 `SpeedometerLogicTests.swift`**

```swift
import XCTest
@testable import VibeCompanion

@MainActor
final class SpeedometerLogicTests: XCTestCase {

    // 角度映射
    func testAngleAtZeroIsMin() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 0), -135.0, accuracy: 0.001)
    }

    func testAngleAt8000IsZero() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 8000), 0.0, accuracy: 0.001)
    }

    func testAngleAt16000IsMax() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 16000), 135.0, accuracy: 0.001)
    }

    // 越界 clamp
    func testAngleClampsAboveMax() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: 1_000_000), 135.0, accuracy: 0.001)
    }

    func testAngleClampsBelowZero() {
        XCTAssertEqual(speedometerAngle(tokensPerMinute: -50), -135.0, accuracy: 0.001)
    }

    // idle
    func testIdleBelowThreshold() {
        XCTAssertTrue(speedometerIsIdle(tokensPerMinute: 0.5))
        XCTAssertTrue(speedometerIsIdle(tokensPerMinute: 0))
    }

    func testNotIdleAtOrAboveThreshold() {
        XCTAssertFalse(speedometerIsIdle(tokensPerMinute: 1.0))
        XCTAssertFalse(speedometerIsIdle(tokensPerMinute: 500))
    }

    // 格式化（对齐现有 FloatingPetContent.formatRate 行为）
    func testFormatSmall() {
        XCTAssertEqual(speedometerFormat(0), "0")
        XCTAssertEqual(speedometerFormat(999), "999")
        XCTAssertEqual(speedometerFormat(9999), "9999")
    }

    func testFormatThousands() {
        XCTAssertEqual(speedometerFormat(10_000), "10.0k")
        XCTAssertEqual(speedometerFormat(12_300), "12.3k")
    }

    func testFormatMillions() {
        XCTAssertEqual(speedometerFormat(1_000_000), "1.00M")
        XCTAssertEqual(speedometerFormat(2_340_000), "2.34M")
    }
}
```

> 注：现有 `FloatingPetContent.formatRate`（`FloatingPetPanel.swift:59`）的行为是 `<1000` 显示整数、`<1_000_000` 显示 `%.1fk`、否则 `%.2fM`。`speedometerFormat` 复用此口径（LCD 显示与气泡一致），但 0 显示 `"0"` 而非 `"/min"`。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd client && swift test --filter SpeedometerLogicTests`
Expected: 编译失败，`speedometerAngle` 等未定义。

- [ ] **Step 3: 实现 `SpeedometerLogic.swift`**

```swift
import Foundation

/// 速度表常量与映射逻辑（纯函数，无 UI 依赖，便于单测）。
/// 角度约定：-135°（最左，0 tok/min）-> 0°（正上，8000 tok/min）-> +135°（最右，16000 tok/min）。
enum SpeedometerConfig {
    static let angleMin: Double = -135.0
    static let angleMax: Double = 135.0
    static let valueMax: Double = 16_000.0   // 对应 1.0× 的 8000 落在 0°（中点）
    static let idleThreshold: Double = 1.0    // tok/min 低于此值视为 idle
}

/// token/min -> 指针角度（度），clamp 在 [-135, 135]。
func speedometerAngle(tokensPerMinute: Double) -> Double {
    let raw = SpeedometerConfig.angleMin
        + (tokensPerMinute / SpeedometerConfig.valueMax)
            * (SpeedometerConfig.angleMax - SpeedometerConfig.angleMin)
    return min(max(raw, SpeedometerConfig.angleMin), SpeedometerConfig.angleMax)
}

/// 是否处于 idle 状态（无 token 消耗）。
func speedometerIsIdle(tokensPerMinute: Double) -> Bool {
    tokensPerMinute < SpeedometerConfig.idleThreshold
}

/// LCD 数字窗格式化。口径与 FloatingPetContent.formatRate 一致：
/// <1000 整数；<1_000_000 "%.1fk"；否则 "%.2fM"。
func speedometerFormat(_ rpm: Double) -> String {
    if rpm < 1000 { return "\(Int(rpm))" }
    if rpm < 1_000_000 { return String(format: "%.1fk", rpm / 1000) }
    return String(format: "%.2fM", rpm / 1_000_000)
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd client && swift test --filter SpeedometerLogicTests`
Expected: 全部 11 个测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add client/VibeCompanion/Sources/Core/SpeedometerLogic.swift client/VibeCompanion/Tests/SpeedometerLogicTests.swift
git commit -m "feat(overlay): add SpeedometerLogic pure mapping + tests"
```

---

## Task 2: SpeedometerView SwiftUI 视图

基于 Task 1 的逻辑绘制表盘。预览原型（`speedometer-preview.html`）是设计参考，几何参数从那里移植。

**Files:**
- Create: `client/VibeCompanion/Sources/Overlay/SpeedometerView.swift`

**Interfaces:**
- Consumes:
  - `speedometerAngle(tokensPerMinute:) -> Double`（Task 1）
  - `speedometerIsIdle(tokensPerMinute:) -> Bool`（Task 1）
  - `speedometerFormat(_:) -> String`（Task 1）
  - `SpeedometerConfig.angleMin/angleMax`（Task 1）
- Produces:
  - `struct SpeedometerView: View`，初始化 `SpeedometerView(tokensPerMinute: Double)`

- [ ] **Step 1: 实现 `SpeedometerView.swift`**

几何约定（与 HTML 预览一致，viewBox 等价于 200×200 的相对坐标，SwiftUI 用 `Canvas`/`Shape` 在 140×140 frame 内绘制）：

```swift
import SwiftUI

/// 老式汽车速度表：圆形表盘 + 白刻度/数字 + 红指针 + 红线区 + LCD 数字窗。
/// 指针角度 = speedometerAngle(tokensPerMinute:)，弹簧动画带过冲回摆。
struct SpeedometerView: View {
    let tokensPerMinute: Double

    // 表盘几何（在 1.0 基准坐标系内，整体放进 140×140 frame）
    private let size: CGFloat = 140
    private let center = CGPoint(x: 100, y: 100)
    private let rimRadius: CGFloat = 96
    private let dialRadius: CGFloat = 82
    private let redlineStart: Double = 12_000   // 红线区起点 tok/min
    private let majorValues: [Double] = [0, 4000, 8000, 12000, 16000]

    var body: some View {
        let angle = speedometerAngle(tokensPerMinute: tokensPerMinute)
        let display = speedometerFormat(tokensPerMinute)

        ZStack {
            dialBackground
            redlineArc
            ticks
            numbers
            lcdWindow(display)
            needle(angle)
            centerCap
        }
        .frame(width: size, height: size)
        .scaleEffect(size / 200)   // 几何按 200 设计，缩放到 140
    }

    // MARK: - 部件

    private var dialBackground: some View {
        ZStack {
            // 金属外环
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xE8_EA_EE), Color(hex: 0x9A_A0_A8), Color(hex: 0x5B_60_68)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: rimRadius * 2, height: rimRadius * 2)
            // 表盘黑底
            Circle()
                .fill(Color(hex: 0x0C_0D_10))
                .frame(width: (rimRadius - 8) * 2, height: (rimRadius - 8) * 2)
            // 表盘径向渐变
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x33_36_3C), Color(hex: 0x17_19_1D)],
                        center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: dialRadius
                    )
                )
                .frame(width: dialRadius * 2, height: dialRadius * 2)
        }
    }

    private var redlineArc: some View {
        // 12k -> 16k 红色弧段
        let start = Angle.degrees(speedometerAngle(tokensPerMinute: redlineStart) - 90)
        let end = Angle.degrees(speedometerAngle(tokensPerMinute: 16000) - 90)
        return ArcShape(center: center, radius: 74, start: start, end: end)
            .stroke(Color(hex: 0xE5_48_4D), style: StrokeStyle(lineWidth: 7, lineCap: .round))
    }

    private var ticks: some View {
        ZStack {
            ForEach(0..<17) { i in
                let value = Double(i) * 1000
                let isMajor = majorValues.contains(value)
                let ang = speedometerAngle(tokensPerMinute: value)
                TickShape(
                    center: center,
                    innerRadius: isMajor ? 60 : 72,
                    outerRadius: 78,
                    angle: Angle.degrees(ang)
                )
                .stroke(Color.white.opacity(isMajor ? 1.0 : 0.55),
                        style: StrokeStyle(lineWidth: isMajor ? 4 : 1.5, lineCap: .round))
            }
        }
    }

    private var numbers: some View {
        ZStack {
            ForEach(majorValues, id: \.self) { value in
                let ang = speedometerAngle(tokensPerMinute: value)
                let pos = polarPoint(center: center, radius: 50, angleDeg: ang)
                Text(formatScale(value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .position(x: pos.x, y: pos.y)
            }
        }
    }

    private func lcdWindow(_ display: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: 0x0A_0C_0E))
                .frame(width: 54, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color(hex: 0x3A_3D_42), lineWidth: 1)
                )
            Text(display)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: 0x7E_F0_C1))
        }
        .position(x: center.x, y: center.y + 49)
    }

    private func needle(_ angle: Double) -> some View {
        NeedleShape()
            .fill(Color(hex: 0xE5_48_4D))
            .frame(width: 6, height: 72)
            .offset(y: -24)   // 针尖向上，中心在表盘中心
            .rotationEffect(.degrees(angle), anchor: .center)
            .position(x: center.x, y: center.y)
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: angle)
    }

    private var centerCap: some View {
        ZStack {
            Circle().fill(Color(hex: 0xC7_CC_D4))
                .frame(width: 16, height: 16)
            Circle().fill(Color(hex: 0x3A_3D_42))
                .frame(width: 6, height: 6)
        }
        .position(x: center.x, y: center.y)
    }

    // MARK: - helpers

    /// 极坐标转直角（角度：0° = 正上，顺时针为正，与 speedometerAngle 约定一致）。
    private func polarPoint(center: CGPoint, radius: CGFloat, angleDeg: Double) -> CGPoint {
        let a = (angleDeg - 90) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(a)),
                       y: center.y + radius * CGFloat(sin(a)))
    }

    private func formatScale(_ v: Double) -> String {
        if v >= 1000 { return "\(Int(v / 1000))k" }
        return "\(Int(v))"
    }
}

// MARK: - Shapes

/// 弧形（指定起止角度）。
struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat
    let start: Angle
    let end: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: center, radius: radius,
                 startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

/// 单根刻度线（从 innerRadius 到 outerRadius，绕 angle 旋转）。
struct TickShape: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let angle: Angle
    func path(in rect: CGRect) -> Path {
        let a = (angle.degrees - 90) * .pi / 180
        let inner = CGPoint(x: center.x + innerRadius * CGFloat(cos(a)),
                            y: center.y + innerRadius * CGFloat(sin(a)))
        let outer = CGPoint(x: center.x + outerRadius * CGFloat(cos(a)),
                            y: center.y + outerRadius * CGFloat(sin(a)))
        var p = Path()
        p.move(to: inner); p.addLine(to: outer)
        return p
    }
}

/// 指针（三角形：针尖向上，尾部向下短）。
struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        // rect 为 6×72：针尖在顶部中点，底部两侧为尾
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))              // 尖
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))          // 右下
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))           // 左下
        p.closeSubpath()
        return p
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
```

- [ ] **Step 2: 确认编译通过**

Run: `cd client && swift build`
Expected: BUILD SUCCEEDED（此时 SpeedometerView 还未被引用，但应编译无错）。

> 注：若 `swift build` 因 lottie-ios 依赖拉取慢/失败，可先跳过，到 Task 4 移除依赖后再构建。但建议先确认 SwiftUI 代码本身无语法/类型错误。

- [ ] **Step 3: Commit**

```bash
git add client/VibeCompanion/Sources/Overlay/SpeedometerView.swift
git commit -m "feat(overlay): add SpeedometerView SwiftUI gauge"
```

---

## Task 3: 接入 FloatingPetContent，删除 Lottie 引用

把 `SpeedometerView` 接入悬浮窗，替换 `LottiePetView`。idle 不再用 emoji，速度表指针自然回 0。

**Files:**
- Modify: `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift`（`FloatingPetContent`，约 28-64 行）
- Delete: `client/VibeCompanion/Sources/Overlay/LottiePetView.swift`

**Interfaces:**
- Consumes: `SpeedometerView(tokensPerMinute:)`（Task 2）
- Produces: `FloatingPetContent` 不再引用 `LottiePetView` / `AppConfig.animationSpeed`

- [ ] **Step 1: 改造 `FloatingPetContent`**

把 `FloatingPetPanel.swift` 的 `FloatingPetContent`（当前 28-64 行）替换为：

```swift
/// SwiftUI 内容容器：速度表显示 token 消耗速率
struct FloatingPetContent: View {
    @ObservedObject var aggregator: TokenAggregator

    var body: some View {
        let rpm = aggregator.tokensPerMinute
        let isIdle = speedometerIsIdle(tokensPerMinute: rpm)

        VStack(spacing: 2) {
            SpeedometerView(tokensPerMinute: rpm)
                .frame(width: 140, height: 140)

            // 速率小气泡（非 idle 时显示）
            if !isIdle {
                Text(speedometerFormat(rpm))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(width: 160, height: 160)
    }
}
```

要点：
- 删除 `let speed = AppConfig.animationSpeed(...)` 调用
- 删除 `import Lottie`（`FloatingPetPanel.swift` 顶部当前只有 `import SwiftUI` + `import AppKit`，无 Lottie import，确认即可）
- 删除 `if isIdle { Text("😴") } else { LottiePetView(...) }` 分支，统一用 `SpeedometerView`（idle 时指针自动回 -135°）
- 速率气泡用 `speedometerFormat`（与 LCD 一致），替换原 `formatRate`

- [ ] **Step 2: 删除 `LottiePetView.swift`**

```bash
git rm client/VibeCompanion/Sources/Overlay/LottiePetView.swift
```

- [ ] **Step 3: 确认无残留 Lottie 引用**

Run: `cd /Users/woody/Workspaces/vide-companion && grep -rn "LottiePetView\|import Lottie\|Lottie\." client/VibeCompanion/Sources/`
Expected: 无输出（或仅 `AppConfig.swift:19` 注释提到 "Lottie"，下个 Task 清理）。

- [ ] **Step 4: Commit**

```bash
git add client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift
git commit -m "refactor(overlay): wire SpeedometerView into FloatingPetContent, drop LottiePetView"
```

---

## Task 4: 清理 Package.swift / 资源 / AppConfig / build 脚本

移除 lottie-ios 依赖、动画资源、不再使用的 `animationSpeed`，以及 build 脚本里的 Lottie 资源复制步骤。

**Files:**
- Modify: `client/Package.swift`（12-30 行）
- Modify: `client/VibeCompanion/Sources/Core/AppConfig.swift`（17-24 行）
- Modify: `scripts/build-app.sh`（72-74 行）
- Delete: `client/VibeCompanion/Resources/Animations/cycling_pet.json`

- [ ] **Step 1: 改 `Package.swift`，移除 lottie-ios 依赖与资源**

把 `Package.swift` 改为（对比原文件 12-30 行）：

```swift
    dependencies: [
        // 轻量 SQLite 客户端，存储用量缓冲与 offset 游标
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeCompanion",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "VibeCompanion/Sources"
            // 速度表为纯 SwiftUI 绘制，无需 Lottie 资源
        ),
        .testTarget(
            name: "VibeCompanionTests",
            dependencies: ["VibeCompanion"],
            path: "VibeCompanion/Tests"
        )
    ]
```

变更点：
- 删除 `.package(url: "https://github.com/airbnb/lottie-ios", from: "4.5.0")` 依赖
- 删除 `.product(name: "Lottie", package: "lottie-ios")`
- 删除 `resources: [ .copy("../Resources/Animations") ]` 整块

- [ ] **Step 2: 删除 `cycling_pet.json` 资源**

```bash
git rm client/VibeCompanion/Resources/Animations/cycling_pet.json
# 若 Resources/Animations 目录已空，移除空目录
rmdir client/VibeCompanion/Resources/Animations 2>/dev/null || true
rmdir client/VibeCompanion/Resources 2>/dev/null || true
```

- [ ] **Step 3: 改 `AppConfig.swift`，删除 `animationSpeed`**

把 `AppConfig.swift` 中 17-24 行的 `animationSpeed` 函数删除（含其上方的 `/// 速率聚合窗口（秒）` 之后到文件末尾的 animationSpeed 注释与函数）：

删除这一段：
```swift
    /// token/min -> Lottie animationSpeed 映射
    static func animationSpeed(tokensPerMinute: Double) -> Double {
        // 8000 tokens/min -> 1.0x；下限 0.25，上限 4.0
        let raw = tokensPerMinute / 8000.0
        return min(max(raw, 0.25), 4.0)
    }
```

保留 `AppConfig` 其余部分（`defaultAPIBase`、`uploadIntervalSeconds`、`rateWindowSeconds` 等）。

- [ ] **Step 4: 改 `build-app.sh`，删除 Lottie 资源复制**

删除 `scripts/build-app.sh` 第 72-74 行：
```bash
# 复制 Lottie 动画资源到 bundle（SwiftPM 的 bundle resources 会嵌进二进制，
# 但 lottie-ios 的 LottieAnimationView(name:bundle:.main) 从 .app/Resources 读取更可靠）
cp -R "$CLIENT/VibeCompanion/Resources/Animations" "$APP_BUNDLE/Contents/Resources/Animations"
```

- [ ] **Step 5: 确认无残留引用**

Run: `cd /Users/woody/Workspaces/vide-companion && grep -rn "animationSpeed\|Lottie\|cycling_pet\|Animations" client/VibeCompanion/ scripts/build-app.sh 2>/dev/null`
Expected: 无输出（`docs/` 下的设计文档保留，不算残留）。

- [ ] **Step 6: 构建验证**

Run: `cd client && swift build`
Expected: BUILD SUCCEEDED（此时 lottie-ios 已移除，构建应更快）。

- [ ] **Step 7: 运行全部测试**

Run: `cd client && swift test`
Expected: 全部测试 PASS（含 Task 1 的 `SpeedometerLogicTests` 与既有测试）。

- [ ] **Step 8: 构建并启动 app 做运行时验证**

Run: `cd /Users/woody/Workspaces/vide-companion && scripts/build-app.sh && open "client/.build/app/VibeCompanion.app"`
Expected:
- 应用启动，悬浮窗显示速度表（非 emoji）
- 指针在 -135°（idle，无 token 消耗时）
- 触发 Claude Code/Codex 消耗 token 后，指针弹性转向对应角度，LCD 显示速率，橙色气泡显示相同格式
- 高速（>12k tok/min）时指针进入红色弧段区

- [ ] **Step 9: Commit**

```bash
git add client/Package.swift client/VibeCompanion/Sources/Core/AppConfig.swift scripts/build-app.sh
git commit -m "chore: remove lottie-ios dependency, cycling_pet resource, animationSpeed"
```

---

## 完成检查清单

- [ ] `SpeedometerLogic.swift` + 测试通过（11 个 case）
- [ ] `SpeedometerView.swift` 编译通过
- [ ] `FloatingPetContent` 用 `SpeedometerView`，无 Lottie 引用
- [ ] `Package.swift` 无 lottie-ios 依赖、无 Animations 资源
- [ ] `cycling_pet.json` 已删除
- [ ] `AppConfig.animationSpeed` 已删除
- [ ] `build-app.sh` 无 Lottie 资源复制步骤
- [ ] `swift build` + `swift test` 全绿
- [ ] 运行时悬浮窗显示速度表，指针弹性转动
