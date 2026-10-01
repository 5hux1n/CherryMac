#!/bin/bash
set -euo pipefail

TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_ARTIFACT_DIR="$(cd "$TASK_SOURCE_DIR/.." && pwd)"
TASK_BUILD_DIR="$TASK_ARTIFACT_DIR/build"
TASK_ARCH="$(uname -m)"

mkdir -p "$TASK_BUILD_DIR" "$TASK_ARTIFACT_DIR/CherryMac.app/Contents/MacOS"
xcrun swiftc "$TASK_SOURCE_DIR/main.swift" "$TASK_SOURCE_DIR/InputRouter.swift" \
    -o "$TASK_BUILD_DIR/CherryMac" \
    -framework Cocoa -framework IOKit -framework ApplicationServices \
    -target "$TASK_ARCH-apple-macos13.0"

"$TASK_BUILD_DIR/CherryMac" --self-test
cp "$TASK_SOURCE_DIR/Info.plist" "$TASK_ARTIFACT_DIR/CherryMac.app/Contents/Info.plist"
cp "$TASK_BUILD_DIR/CherryMac" "$TASK_ARTIFACT_DIR/CherryMac.app/Contents/MacOS/CherryMac"
codesign --force --sign - "$TASK_ARTIFACT_DIR/CherryMac.app"
codesign --verify --deep --strict "$TASK_ARTIFACT_DIR/CherryMac.app"
plutil -lint "$TASK_ARTIFACT_DIR/CherryMac.app/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$TASK_ARTIFACT_DIR/CherryMac.app" "$TASK_ARTIFACT_DIR/CherryMac-0.3.zip"
echo "已生成 CherryMac.app 和 CherryMac-0.3.zip；请退出旧版本后重新打开。"
