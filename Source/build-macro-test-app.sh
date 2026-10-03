#!/bin/bash
set -euo pipefail
# Builds the isolated research App; does not launch it or access real HID.
if [[ $# != 1 || "$1" != /*.app ]]; then
    echo 'Usage: bash Source/build-macro-test-app.sh /absolute/path/CherryMacMacroTest.app' >&2
    exit 2
fi
TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_APP_OUTPUT="$1"
if [[ -e "$TASK_APP_OUTPUT" ]]; then
    echo 'Output already exists; use a fresh App path to avoid replacing an authorized or running test.' >&2
    exit 2
fi
mkdir -p "$TASK_APP_OUTPUT/Contents/MacOS"
bash "$TASK_SOURCE_DIR/build-macro-observer.sh" "$TASK_APP_OUTPUT/Contents/MacOS/CherryMacMacroTest"
"$TASK_APP_OUTPUT/Contents/MacOS/CherryMacMacroTest" --self-test
cat > "$TASK_APP_OUTPUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>CherryMac Macro Test</string>
<key>CFBundleName</key><string>CherryMac Macro Test</string>
<key>CFBundleExecutable</key><string>CherryMacMacroTest</string>
<key>CFBundleIdentifier</key><string>local.cherrymac.macro-hardware-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CherryMacMacroHardwareTest</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>仅观察 CHERRY USB 键盘的测试宏，核对按键顺序、次数及完整松开；测试日志自动保存在本机。</string>
</dict></plist>
PLIST
plutil -lint "$TASK_APP_OUTPUT/Contents/Info.plist"
codesign --force --sign - "$TASK_APP_OUTPUT"
codesign --verify --deep --strict "$TASK_APP_OUTPUT"
echo "Built $TASK_APP_OUTPUT; physical writes still require the test window action."
