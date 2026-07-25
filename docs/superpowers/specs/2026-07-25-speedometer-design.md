# 速度表悬浮动画 · 设计文档

日期：2026-07-25
状态：待用户审阅
关联预览：`docs/superpowers/specs/speedometer-preview.html`（评审用 SVG/CSS/JS 原型）

## 1. 背景与目标

Vibe Companion 原计划在悬浮窗用「卡通小人蹬自行车」展示 token 消耗速率。经用户调整方向，改为更直接、更符合「速率」语义的形象：

**老式汽车速度表**：圆形表盘 + 弹性指针 + 红线区 + 数字显示窗。

### 与自行车方案的关键差异

| 维度 | 自行车方案 | 速度表方案 |
|---|---|---|
| 表现形式 | 蹬车循环动画 | 指针指向当前速率值 |
| 技术栈 | Lottie JSON + Python 生成器 | 纯 SwiftUI 绘制 |
| 速率映射 | `animationSpeed` 控制动画快慢 | 指针旋转角度直接映射 token/min |
| 复杂度 | 高（IK、循环、markers） | 低（几何图形 + 弹性动画） |

## 2. 美术风格

**经典老式汽车速度表**：

- 圆形，约 270° 弧形刻度
- 深色表盘：径向渐变 `#1b1d21` → `#2a2c31`
- 金属外环：银灰线性渐变
- 刻度/数字：白色/浅灰
- 指针：红色，中心固定
- 红线区：右侧 12k→16k 弧段，红色
- 数字显示窗：表盘下方 LCD 风格小窗，显示确切速率

## 3. 表盘规格（viewBox 200×200）

| 元素 | 几何/样式 |
|---|---|
| 外环 | 圆心 (100,100)，半径 96，银灰线性渐变 |
| 表盘 | 半径 82，深黑径向渐变 |
| 刻度 | 主刻度（0/4k/8k/12k/16k）长白条 4px；副刻度 1.5px |
| 数字 | 12px 白色粗体，`0 / 4k / 8k / 12k / 16k` |
| 红线区 | 12k→16k 弧段，红色 `#e5484d`，宽 7px |
| 指针 | 红色三角形，长 60，中心固定于 (100,100)，可旋转 |
| 中心轴帽 | 银灰圆环 + 深色中心 |
| 数字窗 | 底部 LCD：黑底 + 青绿数字 `#7ef0c1` |

## 4. 速率映射与动画

### 角度映射

- 0 tok/min → **-135°**（最左）
- 8000 tok/min → **0°**（正上方，对应 `AppConfig.animationSpeed` 的 1.0×）
- 16000 tok/min → **+135°**（最右，红线区终点）

映射公式：

```swift
let angle = -135 + (tokensPerMinute / 16000) * 270
```

实际实现中 clamp 在 [-135, 135]。

### 弹性指针动画

指针从当前角度转向目标角度时，使用 SwiftUI 的弹簧动画：

```swift
needle
  .rotationEffect(.degrees(targetAngle))
  .animation(.spring(response: 0.35, dampingFraction: 0.5), value: targetAngle)
```

效果：轻微**过冲 + 阻尼回摆**，模拟真实机械仪表质感。

### idle 状态

当 token/min < 1 时，指针目标角度为 -135°（回 0），并可用 `.spring` 缓慢落回，增强「熄火」感。

### 速率显示窗

LCD 小窗实时显示格式化速率：

- `0`–`9999`：直接显示数字
- `>=10000`：`12.3k`

## 5. 架构与代码改造

### 当前 main 状态（claude code 重构后）

经核查 main HEAD（`7448f40`），Overlay 仍为 Lottie 方案，claude code 的改动是：

- **`fbcee7f`**：`TokenAggregator` 改用 `effectiveTokens`（= input + output + cacheCreation，排除 cache_read），速率数值更合理（不再天文数字）
- **`cccdd3d`**：`LottiePetView` 修复加载空白，`LottieAnimation.named(_:bundle:subdirectory:)` 显式指定 `"Animations"` 子目录
- **新增测试目录** `client/VibeCompanion/Tests/`（7 个 XCTest 文件，`@testable import VibeCompanion` + `@MainActor` 风格）
- **`FloatingPetContent.formatRate`** 已存在并复用

本次改造基于上述真实状态。

### 新增：Overlay/SpeedometerView.swift

纯 SwiftUI 视图，负责绘制表盘 + 指针 + 数字窗。

```swift
struct SpeedometerView: View {
    let tokensPerMinute: Double
    var body: some View {
        ZStack {
            // 外环 + 表盘
            // 红线区
            // 刻度 + 数字
            // 指针（rotationEffect）
            // 中心轴帽
            // LCD 数字窗
        }
        .frame(width: 140, height: 140)
    }
}
```

### 改造：FloatingPetPanel.swift / FloatingPetContent

- 删除 `LottiePetView(...)` 引用与 `import Lottie`
- 替换为 `SpeedometerView(tokensPerMinute: aggregator.tokensPerMinute)`
- idle（`< 1` tok/min）指针回 -135°（速度表内部处理，无需 emoji 占位）
- 保持现有 `formatRate` 速率气泡徽章（橙色 capsule）
- 删除 `AppConfig.animationSpeed` 调用（速度表内联角度映射）

### 改造：LottiePetView.swift 与 AppConfig.animationSpeed

- 删除 `Overlay/LottiePetView.swift`（当前是 `cccdd3d` 修过的 subdirectory 版本）
- `AppConfig.animationSpeed(tokensPerMinute:)` 不再被引用，可一并删除（其 8000->1.0× 的映射语义已被速度表角度映射取代）

### Package.swift 与资源清理

- `Package.swift` 移除 `lottie-ios` 依赖与 `Lottie` product
- `resources` 移除 `.copy("../Resources/Animations")`
- 删除 `client/VibeCompanion/Resources/Animations/cycling_pet.json`（及若存在的 `Resources/` 目录）
- `scripts/build-app.sh` 若有 Lottie 相关步骤一并清理

## 6. 错误处理与边界

- **速率越界**：角度 clamp 在 [-135, 135]，无论 token/min 多高，指针不超出红线区。
- **无 token**：idle 时稳定指向 -135°，不抖动。
- **悬浮窗透明背景**：表盘深色不透明圆盘作为视觉主体，在透明 NSPanel 上完整呈现。
- **滞回**：可沿用/增加状态切换滞回，避免指针在阈值附近频繁跳动。

## 7. 测试与验证

项目已有 XCTest 测试目录（`client/VibeCompanion/Tests/`，`@testable import VibeCompanion` + `@MainActor` 风格）。新增测试：

- `SpeedometerViewTests.swift`：
  - 角度映射：0 -> -135°、8000 -> 0°、16000 -> 135°、超限 clamp
  - idle 阈值：< 1 tok/min 判定
  - 数字格式化：复用 `formatRate` 逻辑（`<1k` 整数、`<1M` `k`、否则 `M`）

运行时验证：

- `scripts/build-app.sh` 构建运行，观察指针随 token 消耗转动、弹性回摆、idle 回 0
- 预览 HTML 已可手动拖动验证映射和弹性
- 140×140 悬浮窗尺寸下刻度、数字、指针清晰可读

## 8. 交付物清单

1. `client/VibeCompanion/Sources/Overlay/SpeedometerView.swift` -- 纯 SwiftUI 表盘视图
2. `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift` -- `FloatingPetContent` 改用 `SpeedometerView`
3. `client/VibeCompanion/Sources/Overlay/LottiePetView.swift` -- 删除
4. `client/VibeCompanion/Tests/SpeedometerViewTests.swift` -- 角度映射/格式化单测
5. `client/Package.swift` -- 移除 lottie-ios 依赖与 Lottie product、移除 Animations 资源
6. 删除 `client/VibeCompanion/Resources/Animations/cycling_pet.json`
7. `client/VibeCompanion/Sources/Core/AppConfig.swift` -- 删除 `animationSpeed`（若无其他引用）
8. `docs/superpowers/specs/2026-07-25-speedometer-design.md` -- 本设计文档
9. `docs/superpowers/specs/speedometer-preview.html` -- 评审原型

## 9. 范围外（YAGNI）

- 小人蹬自行车方案不再实现
- Lottie 生成器、markers、循环动画、腿部 IK
- 多皮肤/仪表样式
- 数字窗以外的复杂动效
