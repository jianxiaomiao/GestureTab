#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export CLANG_MODULE_CACHE_PATH="/tmp/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

APP_DIR="$SCRIPT_DIR/GestureTab.app"
TMP_BUILD="/tmp/gesturetab_build"
rm -rf "$APP_DIR" "$TMP_BUILD"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$TMP_BUILD"

echo "正在编译 GestureTab (Universal: x86_64 + arm64)..."

swiftc -O \
  -swift-version 5 \
  -target x86_64-apple-macosx14.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  "$SCRIPT_DIR/Sources/GestureTab/"*.swift \
  -o "$TMP_BUILD/GestureTab_x86_64"

swiftc -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ApplicationServices \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  "$SCRIPT_DIR/Sources/GestureTab/"*.swift \
  -o "$TMP_BUILD/GestureTab_arm64"

lipo -create \
  "$TMP_BUILD/GestureTab_x86_64" \
  "$TMP_BUILD/GestureTab_arm64" \
  -output "$APP_DIR/Contents/MacOS/GestureTab"

rm -rf "$TMP_BUILD"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/GestureTab"

CERT_NAME="GestureTab Local Signer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "使用固定本地证书签名: $CERT_NAME"
    codesign --force --deep --sign "$CERT_NAME" "$APP_DIR"
else
    echo "⚠️ 未检测到本地固定签名证书，降级为 ad-hoc 签名（建议运行 ./setup_signing.sh）"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "✅ 打包完成 (Universal Binary): $APP_DIR"
