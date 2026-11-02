#!/bin/bash
# 构建「应用保险箱」AppVault.app（开源，MIT）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AppVault.app"
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macosx27.0 \
    Sources/AppVault.swift \
    -o "$APP/Contents/MacOS/AppVault"

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> 生成图标"
PY="${PYTHON:-/Users/inkpaper/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3}"
[ -x "$PY" ] || PY=python3
"$PY" scripts/generate_icon.py build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 清理扩展属性并 ad-hoc 签名"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 完成：$APP"
