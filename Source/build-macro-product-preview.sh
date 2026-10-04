#!/bin/bash
set -euo pipefail

# Create a separate acceptance app without replacing an installed/released app,
# launching it, requesting permissions or accessing a keyboard.
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
git -C "$TASK_SOURCE_DIR" diff --quiet HEAD -- .
TASK_PREVIEW_COMMIT="$(git -C "$TASK_SOURCE_DIR" rev-parse HEAD)"
TASK_PREVIEW_DIR="$1"
mkdir -p "$TASK_PREVIEW_DIR"
TASK_PREVIEW_DIR="$(cd "$TASK_PREVIEW_DIR" && pwd)"
TASK_PREVIEW_APP="$TASK_PREVIEW_DIR/CherryMacMacroPreview.app"
if [[ -e "$TASK_PREVIEW_APP" ]]; then
    echo "Refusing to replace an existing preview app; choose a new output directory." >&2
    exit 1
fi
TASK_PREVIEW_ARCH="$(uname -m)"
TASK_PREVIEW_STAGE="$(mktemp -d "$TASK_PREVIEW_DIR/.macro-preview.XXXXXX")"
trap 'rm -rf "$TASK_PREVIEW_STAGE"' EXIT
mkdir -p "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app/Contents/MacOS"
TASK_PREVIEW_SOURCES=()
for TASK_PREVIEW_NAME in main InputRouter CherryHardware CalculatorKeyTest KeymapWrite CalculatorHardwareTestController CherryMacro HardwareProfile WindowsProfile LightingModel HardwareWindow HardwareLighting CalculatorService HardwareTests MacroPhysicalStop; do
    TASK_PREVIEW_SOURCES+=("$TASK_SOURCE_DIR/$TASK_PREVIEW_NAME.swift")
done
xcrun swiftc -D CHERRY_MACRO_PRODUCT "${TASK_PREVIEW_SOURCES[@]}" \
    -o "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app/Contents/MacOS/CherryMac" \
    -framework Cocoa -framework IOKit -framework ApplicationServices \
    -target "$TASK_PREVIEW_ARCH-apple-macos13.0"
cp "$TASK_SOURCE_DIR/Info.plist" "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app/Contents/Info.plist"
TASK_PREVIEW_PLIST="$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.cherrymac.macro-product-preview' "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName CherryMac Macro Preview' "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CherryMac Macro & Text Preview' "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.18.0' "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 20' "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Add :CherryMacSourceCommit string $TASK_PREVIEW_COMMIT" "$TASK_PREVIEW_PLIST"
plutil -lint "$TASK_PREVIEW_PLIST"
codesign --force --sign - "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app"
codesign --verify --deep --strict "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app"
mv "$TASK_PREVIEW_STAGE/CherryMacMacroPreview.app" "$TASK_PREVIEW_APP"
python3 "$TASK_SOURCE_DIR/package-macro-preview.py" "$TASK_PREVIEW_DIR"
echo "Created $TASK_PREVIEW_APP; not launched and no keyboard accessed."
