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
- **lottie-ios**（4.6.x）：蹬车动画，`animationSpeed` 映射 token 速率。
- **GRDB.swift**（6.29.x）：本地 SQLite 缓冲队列。

## 首次使用

1. 启动 App（菜单栏出现图标，不出现在 Dock，因 `Info.plist` 的 `LSUIElement=true`）。
2. 菜单栏图标 -> 「⚙ 设置…」。
3. 在网站注册账户 -> 登录 -> Dashboard 点「添加设备」获取 Client Token。
4. 粘贴 Token 到设置页 -> 「保存 Token 并完成注册」。
5. 修改「服务地址」指向生产后端（默认 `http://localhost:3000`）。
6. 开始用 Claude Code / Codex CLI 编程，悬浮宠物窗随 token 速率蹬车。

## 关于 Lottie 形象

MVP 使用 `Resources/Animations/cycling_pet.json` 作为占位蹬车动画（手写简易 JSON：橙黄色身体 + 两个旋转的轮子）。
替换形象：将新的 Lottie JSON 放入该目录，在 `LottiePetView` 调用处改 `animationName` 即可。
后续可扩展多档位形象（idle/慢骑/飞驰/喷火）与 Rive 状态机。
