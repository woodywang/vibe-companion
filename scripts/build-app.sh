#!/bin/bash
# 将 SwiftPM 构建产物打包成 .app bundle。
# 用法: ./scripts/build-app.sh [release|debug]
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="${1:-debug}"
CONFIG_FLAG=""
if [[ "$MODE" == "release" ]]; then
  CONFIG_FLAG="-c release"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/client"
BUILD_DIR="$CLIENT/.build"
APP_NAME="VibeCompanion"
APP_BUNDLE="$BUILD_DIR/app/$APP_NAME.app"

echo "==> Building ($MODE)..."
cd "$CLIENT"
swift build $CONFIG_FLAG

# 定位可执行文件
EXE_PATH="$(swift build $CONFIG_FLAG --show-bin-path)/$APP_NAME"
if [[ ! -f "$EXE_PATH" ]]; then
  echo "ERROR: 可执行文件未找到: $EXE_PATH" >&2
  exit 1
fi

echo "==> Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM 的资源包（内置 LiteLLM 定价快照）必须一并拷入，否则 `Bundle.module`
# 只能回退到编译期烘进二进制的 `.build` 绝对路径——App 一旦离开本机、或 `.build`
# 被清掉，启动即 fatalError：
#   could not load resource bundle: from <app>/VibeCompanion_VibeCompanion.bundle
#   or <repo>/client/.build/arm64-apple-macosx/debug/VibeCompanion_VibeCompanion.bundle
# 两个候选位置都放：Contents/Resources 是 `Bundle.main.resourceURL`，
# .app 根目录是 `Bundle.main.bundleURL`（错误信息里实际报出的那个）。
BUNDLE_NAME="${APP_NAME}_${APP_NAME}.bundle"
BUNDLE_SRC="$(swift build $CONFIG_FLAG --show-bin-path)/$BUNDLE_NAME"
if [[ -d "$BUNDLE_SRC" ]]; then
  cp -R "$BUNDLE_SRC" "$APP_BUNDLE/Contents/Resources/$BUNDLE_NAME"
  cp -R "$BUNDLE_SRC" "$APP_BUNDLE/$BUNDLE_NAME"
else
  echo "ERROR: 资源包未找到: $BUNDLE_SRC" >&2
  exit 1
fi

# Info.plist: LSUIElement=true 让 App 作为菜单栏常驻（不出现在 Dock）
# NSAppTransportSecurity: 允许明文 HTTP 连 localhost（dev 后端用 http://localhost:3000）
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Vibe Companion</string>
    <key>CFBundleIdentifier</key>
    <string>dev.vibe.companion</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>VibeCompanion</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Done: $APP_BUNDLE"
echo "    打开: open \"$APP_BUNDLE\""
