# 客户端构建说明

## Xcode 路径

本机 Xcode 安装于 `/Applications/Xcode.app`，但 `xcode-select` 当前指向 `/Library/Developer/CommandLineTools`。
所有构建命令需先设置：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

或一次性切换（需 sudo）：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 构建

```bash
# 从仓库根目录
./scripts/build-app.sh             # debug 版
./scripts/build-app.sh release     # release 版（优化）
open .build/app/VibeCompanion.app
```

仅验证编译（不打包）：

```bash
swift build
```

## 技术栈

- **SwiftPM**（`Package.swift`）管理构建，而非 `.xcodeproj`。
- **零第三方依赖**：UI 全部为 SwiftUI/AppKit，速度表为纯 SwiftUI 绘制。

## 首次使用

1. 启动 App（菜单栏出现图标，不出现在 Dock，因 `Info.plist` 的 `LSUIElement=true`）。
2. 开始用 Claude Code / Codex CLI 编程，悬浮速度表随 token 速率转动。

App 无需登录或任何配置，用户数据不外发；唯一的出网请求是可选拉取 LiteLLM 公开定价表用于估算花费，失败即回退内置快照。需要让读数停住时用菜单栏的「⏸ 暂停显示」（⌘P）或设置窗口的开关——它只冻结界面，统计不中断，恢复后立即显示真实用量。

## 关于速度表

`Overlay/SpeedometerView.swift` 用 SwiftUI `Canvas`/`Path` 绘制。量程由用户在设置中选择（线性 / 对数 / 自适应），三种实现与 `GaugeScale` 协议在 `Overlay/GaugeScale.swift`；指针角度、LCD 读数与表盘配色统一由 `Core/SpeedometerLogic.swift` 按**指针行程比例**换算，保证配色与指针位置同源。对应单测在 `Tests/GaugeScaleTests.swift` 与 `Tests/SpeedometerLogicTests.swift`。
