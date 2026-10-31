#!/bin/zsh
# DataWheel 原生 SwiftUI 版打包脚本
# 开发：微信公众号 RStata
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="build/DataWheel.app"

echo "① 编译 Swift…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -disable-sandbox -parse-as-library \
  native/Sources/*.swift \
  -o "$APP/Contents/MacOS/DataWheel" \
  -target arm64-apple-macos13.0

echo "② 写入 Info.plist 与资源…"
cp native/Info.plist "$APP/Contents/Info.plist"
cp build/icon.icns "$APP/Contents/Resources/icon.icns"
cp build/menubar.png "$APP/Contents/Resources/menubar.png"
ditto "$ROOT/engine" "$APP/Contents/Resources/engine"
# Python venv 软链挂入（本机使用）
ln -sfn "$ROOT/.venv" "$APP/Contents/Resources/.venv"

echo "③ 签名（稳定身份 DataWheel Dev，保证辅助功能授权跨重编译有效）+ 注册服务…"
if security find-identity -v -p codesigning | grep -q "DataWheel Dev"; then
  codesign --force --deep --sign "DataWheel Dev" "$APP" && echo "  签名: DataWheel Dev"
else
  echo "  (未找到 DataWheel Dev 证书，回退 ad-hoc——辅助功能授权将随重编译失效)"
  codesign --force --deep --sign - "$APP"
fi
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
/System/Library/CoreServices/pbs -update 2>/dev/null || true

# 强制刷新 LaunchServices 注册与图标缓存，否则 Finder 显示通用图标
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
killall Finder Dock 2>/dev/null || true

echo "完成: $ROOT/$APP"
