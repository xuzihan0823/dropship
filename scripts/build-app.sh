#!/bin/bash
# 构建 Dropship.app —— SPM 编译 + 手工组装 macOS bundle + ad-hoc 签名
# 不依赖 Xcode 项目文件，全部产物可由纯文本源码复现。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="${1:-debug}"
APP_NAME="Dropship"
BUNDLE_ID="com.dropship.app"
APP_DIR="$ROOT/build/$APP_NAME.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "错误：未找到可执行文件 $BIN_PATH" >&2
    exit 1
fi

echo "==> 组装 bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# 打包 Go agent 二进制（若已构建），供首次连接时上传到服务器
if [[ -d "$ROOT/build/agents" ]]; then
    cp -R "$ROOT/build/agents" "$APP_DIR/Contents/Resources/agents"
    echo "    已嵌入 agent 二进制"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
# 不启用 App Sandbox：需要读取 ~/.ssh 与任意用户选定路径
codesign --force --sign - --timestamp=none "$APP_DIR" 2>/dev/null

echo "==> 完成: $APP_DIR"
