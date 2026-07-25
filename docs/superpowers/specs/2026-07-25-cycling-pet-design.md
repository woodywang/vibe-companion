# 蹬车小人悬浮动画 · 设计文档

日期：2026-07-25
状态：待用户审阅
关联预览：`docs/superpowers/specs/cycling-pet-preview.html`（评审用 CSS 原型，非交付物）

## 1. 背景与目标

Vibe Companion 的 macOS 客户端用悬浮窗展示「蹬自行车的卡通形象」，骑行速度映射 token 消耗速率。当前 `client/VibeCompanion/Resources/Animations/cycling_pet.json` 是手写占位（仅身体椭圆 + 两个转轮，无小人、无腿）。

本次目标：**设计并产出原创「小人蹬自行车」Lottie 动画**，接入现有悬浮窗管线，替换占位资源。

### 现有管线（无需重建）

- 悬浮窗：`Overlay/FloatingPetPanel.swift`（NSPanel + NSHostingView 承载 SwiftUI）
- 动画播放：`Overlay/LottiePetView.swift`（`NSViewRepresentable` 包装 `LottieAnimationView`）
- 速度映射：`Core/AppConfig.swift` `animationSpeed(tokensPerMinute:)` —— 8000 tok/min → 1.0×，clamp [0.25, 4.0]
- 资源加载：SwiftPM `.copy("../Resources/Animations")`，`LottieAnimationView(name:bundle:)`
- lottie-ios 4.5，已确认支持 `play(fromMarker:toMarker:)`（`LottieAnimationLayer.swift`）

## 2. 美术风格（用户已选定）

**纯黑线条图标风**（参考用户提供的骑行图标）：

- 单色 `#1a1a1a`，无填充色、无彩色
- 头、车轮为**空心圆环**（描边，无填充）
- 躯干/手臂/腿为**流畅粗曲线**（round linecap / linejoin）
- 侧视、俯身骑行姿态
- 车架为三角结构 + 前叉 + 把立

与现有橙色速率气泡（`Color.orange`）形成黑/橙对比，在透明悬浮窗背景上清晰。

### 部件规格（viewBox 200×200，y 向下）

| 部件 | 造型 | 线宽 | 锚点/中心 |
|---|---|---|---|
| 头 | 空心圆环 r=15 | 7 | (112, 46) |
| 躯干 | 肩(104,70)→髋(96,96) 二次曲线 | 9 | — |
| 手臂 | 肩→肘(128,74)→握把(150,82) 折线 | 7 | — |
| 大腿 ×2 | 髋→膝 线段 | 9(近)/7(远) | 髋 (96,96) |
| 小腿 ×2 | 膝→脚 线段 | 8(近)/6(远) | 膝（随大腿） |
| 车轮 ×2 | 空心圆环 r=22 + 2 辐条 | 7(环)/4(辐条) | 后(58,146) 前(150,146) |
| 车架 | 三角 + 前叉 + 把立 | **4（减细）** | 见几何常量 |
| 车座 | 短线段 | 7 | (80–96, 100) |
| 曲柄+踏板 | 绕中轴旋转短杆 + 踏板 | 5 | 中轴 (100,132)，R=16 |

### 关键几何常量

```
WB(后轮)=(58,146)   WF(前轮)=(150,146)   BB(中轴)=(100,132)   R(曲柄半径)=16
HIP(髋)=(96,96)     SHOULDER(肩)=(104,70)  HEAD(头)=(112,46)
GRIP(握把)=(150,82) SEAT(座)=(88,100)     THIGH=30  SHIN=30
```

### 腿与车架的层次（用户已决策：腿优先）

粗线条车架在中轴区会遮挡蹬踏的腿。决策：**车架三角减细至 4px、中轴区留白，腿用 9px 最粗线置于最上层**。近侧腿纯黑 `#1a1a1a`、远侧腿 `#777` 区分前后。牺牲少量车架「实」感，换取蹬踏动作清晰可见——蹬踏是本形象的灵魂。

## 3. 动画设计

单一 Lottie 文件，30fps，用顶层 `markers` 分段：

| marker | 帧段 | 内容 | 播放方式 |
|---|---|---|---|
| `idle` | 0–59 | 静坐车上、呼吸起伏（上半身 translateY ±2px）、车轮静止 | 循环 |
| `pedal` | 60–119 | 蹬踏循环（下详） | 循环，`animationSpeed` 变速 |
| `boost` | 120–149 | 躯干更前倾 + 左侧速度线 | 高速档切换 |

### pedal 蹬踏循环（60 帧 @30fps，首尾无缝）

- **车轮辐条**：绕轮心 rotation 0→360°/循环（匀速线性）
- **曲柄+踏板**：绕中轴 0→360°/循环（匀速线性）
- **腿部（核心）**：大腿+小腿两段，各为以髋/膝为 anchor 的形状图层做旋转关键帧。生成器用**两点 IK（余弦定理反解膝角）**在 12 个采样点预计算髋角/膝角，输出 Lottie 旋转关键帧。左右腿相位差 180°。
- **上半身（躯干+头+手臂）**：translateY ±2px 起伏，2 次/循环

#### 腿部 IK 正确性（已数学验证）

离线验证（Python）：由髋角+膝角重建的脚端位置与踏板圆周位置**误差 ≈ 0**（浮点精度 ~3e-14），最远脚距 52.2 < 腿总长 60（可达）。即「脚精确锁踏板」在生成器中是确定性输出，运行时零计算、无相位漂移。

> 注：CSS 预览原型中腿部视觉对不齐，是 CSS `transform` 覆盖 SVG `transform` 属性、多动画相位同步的原型层问题，**不影响** Lottie 生成器——生成器直接输出每个关键帧的绝对旋转角，无此问题。

## 4. 状态机与 Overlay 改造

### 资源产出：Python 生成器（推荐方案）

新增 `scripts/generate_cycling_pet.py`，参数化生成 Lottie JSON：

- 第 2 节所有几何常量、线宽、颜色作为脚本顶部可调常量
- 输出含 markers 的完整时间轴到 `client/VibeCompanion/Resources/Animations/cycling_pet.json`
- 形象迭代 = 改常量 → 重跑脚本；无运行时依赖；JSON 纳入版本控制

取舍：对比手写 JSON（关键帧/嵌套变换手工计算易错、不可维护）与 SwiftUI 重绘（需重写 Overlay、与现有管线冲突），生成器最可维护。

### Overlay 代码改造

**`LottiePetView.swift`**：
- 增加 `marker` 参数；用 `play(fromMarker:toMarker:)` 播放指定段并循环
- 保留 `animationSpeed` 实时绑定（pedal/boost 段）
- 状态变化时切换 marker 段

**`FloatingPetPanel.swift` / `FloatingPetContent`**：
- idle（< 1 tok/min）：播放 `idle` marker 循环 —— **替换当前的 😴 emoji 占位**
- 有速率：播放 `pedal` marker + `animationSpeed` 映射
- 高速档（速率超过阈值）：切换 `boost` marker；阈值常量加到 `AppConfig`

**`AppConfig.swift`**：
- `animationSpeed` 映射逻辑不变
- 新增 boost 触发阈值常量（如 `boostThresholdTokensPerMinute`）

### 状态过渡（MVP：瞬切）

状态变化时 lottie 切换播放段，为**瞬切**（无补间）。MVP 接受瞬切；平滑过渡（idle→pedal 间加 ~10 帧起步过渡段）作为后续可选增强，不在本次范围。

## 5. 错误处理与边界

- **资源缺失/解析失败**：lottie 加载失败时 `LottieAnimationView` 不渲染，悬浮窗显示空白。需在 `LottiePetView` 兜底——加载失败回退显示静态文本（如 🚴），避免空白窗。
- **speed 边界**：`animationSpeed` 已 clamp [0.25, 4.0]，生成器无需处理。
- **marker 未找到**：lottie `play(fromMarker:)` 找不到 marker 会退出播放。切换前校验 marker 存在，缺失则回退整段 `.loop` 播放。
- **idle↔pedal 抖动**：token 速率在阈值附近抖动会导致状态频繁切换。`FloatingPetContent` 切状态加简单滞回（如进入 idle 需持续低于阈值 N 秒）。

## 6. 测试与验证

项目**无任何测试框架**，Overlay 层为 UI，不适合单测。验证方式：

1. **生成器自校验**：脚本输出后用 Python `json` 校验合法性；打印腿部 12 个关键帧角采样表 + 脚端重建误差（应 ≈0）人工核对；校验 markers 帧段无重叠、首尾帧一致（无缝循环）。
2. **Lottie 预览**（手动）：把生成的 JSON 拖入 https://lottiefiles.github.io 或 LottieFiles 预览，肉眼确认三段动画与切换。
3. **运行时人工验证**：`scripts/build-app.sh` 构建运行，观察悬浮窗 idle/pedal/boost 三态、速度映射、状态切换、拖动。

## 7. 交付物清单

1. `scripts/generate_cycling_pet.py` —— Lottie 生成器（含自校验输出）
2. `client/VibeCompanion/Resources/Animations/cycling_pet.json` —— 生成的动画资源（含 idle/pedal/boost markers）
3. `client/VibeCompanion/Sources/Overlay/LottiePetView.swift` —— marker 播放 + 速度绑定 + 加载兜底
4. `client/VibeCompanion/Sources/Overlay/FloatingPetPanel.swift` —— 状态机（idle/pedal/boost）+ 滞回
5. `client/VibeCompanion/Sources/Core/AppConfig.swift` —— boost 阈值常量
6. `docs/superpowers/specs/cycling-pet-preview.html` —— 评审原型（保留作设计参考）

## 8. 范围外（YAGNI）

- 平滑状态过渡帧段（后续可选增强）
- 点击/悬停交互动画
- 多形象/皮肤、Rive 状态机（README 远期规划）
- 面部五官、表情细节
