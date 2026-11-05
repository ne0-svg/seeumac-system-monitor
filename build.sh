#!/bin/bash
# SysMon 构建脚本 —— 一键编译、签名、安装
# 用法：./build.sh           编译 + 安装到 /Applications（会重启正在运行的实例）
#       ./build.sh --no-install   只编译到 build/

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SeeUMac"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
SRC_DIR="Sources"

if [ ! -d "$SRC_DIR" ]; then
    echo "找不到源码目录 ./Sources"; exit 1
fi
echo "源码：$SRC_DIR"

echo "==> 编译"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

swiftc -O \
    -o "${APP}/Contents/MacOS/${APP_NAME}" \
    "${SRC_DIR}/SystemSampler.swift" \
    "${SRC_DIR}/ProcActions.swift" \
    "${SRC_DIR}/UIPanel.swift" \
    "${SRC_DIR}/main.swift"

echo "==> 写 Info.plist"
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SeeUMac</string>
    <key>CFBundleDisplayName</key><string>SeeUMac</string>
    <key>CFBundleIdentifier</key><string>com.seeumac.menubar</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>SeeUMac</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> 拷贝图标"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/"
else
    echo "  (没有 Resources/AppIcon.icns，用系统默认图标)"
fi

echo "==> 本地签名"
codesign --force --deep --sign - "${APP}" 2>&1 | grep -v "replacing existing" || true

echo "==> 完成：${APP}  ($(du -sh "${APP}" | cut -f1))"

if [ "${1:-}" != "--no-install" ]; then
    echo "==> 安装到 /Applications"
    pkill -f "MacOS/${APP_NAME}" 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP}" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "==> 已启动"
fi
