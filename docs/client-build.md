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
open client/.build/app/VibeCompanion.app
```

仅验证编译（不打包）：

```bash
swift build -C client
```

## 技术栈

- **SwiftPM**（`Package.swift`）管理依赖与构建，而非 `.xcodeproj`。
- **纯 SwiftUI `Canvas`**（`Sources/Overlay/CyclingPetView.swift`）：手绘蹬车动画，`CyclingPet.revolutionsPerSecond(speed:)` 将 token 速率映射为轮子转速（圈/秒）。
- **GRDB.swift**（6.29.x）：本地 SQLite 缓冲队列。

## 首次使用

1. 启动 App（菜单栏出现图标，不出现在 Dock，因 `Info.plist` 的 `LSUIElement=true`）。
2. 菜单栏图标 -> 「⚙ 设置…」。
3. 在网站注册账户 -> 登录 -> Dashboard 点「添加设备」获取 Client Token。
4. 粘贴 Token 到设置页 -> 「保存 Token 并完成注册」。
5. 修改「服务地址」指向生产后端（默认 `http://localhost:3000`）。
6. 开始用 Claude Code / Codex CLI 编程，悬浮宠物窗随 token 速率蹬车。

## 关于宠物形象

MVP 使用纯 SwiftUI `Canvas` 手绘蹬车动画（`CyclingPetView.swift` 中的 `draw(_:size:wheelAngle:)`：橙黄色车架 + 两个旋转的轮子 + 随蹬车摆动的骑手）。
轮速由 `CyclingPet.revolutionsPerSecond(speed:)` 决定，speed 1.0 -> 1 圈/秒，clamp 在 [0.25, 4.0]。
替换形象：直接修改 `CyclingPetView.draw` 里的绘制逻辑即可，无需外部动画资源文件。
后续可扩展多档位形象（idle/慢骑/飞驰/喷火）。
