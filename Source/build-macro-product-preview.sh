#!/bin/bash
set -euo pipefail

# Create a separate acceptance app without replacing an installed/released app,
# launching it, requesting permissions or accessing a keyboard.
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--lighting-acceptance" ) ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY [--lighting-acceptance]" >&2
    exit 2
fi
TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
git -C "$TASK_SOURCE_DIR" diff --quiet HEAD -- .
TASK_PREVIEW_COMMIT="$(git -C "$TASK_SOURCE_DIR" rev-parse HEAD)"
TASK_PREVIEW_DIR="$1"
mkdir -p "$TASK_PREVIEW_DIR"
TASK_PREVIEW_DIR="$(cd "$TASK_PREVIEW_DIR" && pwd)"
TASK_PREVIEW_APP_NAME="CherryMacMacroPreview.app"
TASK_PREVIEW_IDENTIFIER="local.cherrymac.macro-product-preview"
TASK_PREVIEW_DISPLAY="CherryMac Macro & Text Preview"
TASK_PREVIEW_BUNDLE_NAME="CherryMac Macro Preview"
TASK_PREVIEW_VERSION="0.28.0"
TASK_PREVIEW_BUILD="30"
TASK_PREVIEW_FLAGS=(-D CHERRY_MACRO_PRODUCT)
if [[ $# -eq 2 ]]; then
    TASK_PREVIEW_APP_NAME="CherryMacLightingAcceptance.app"
    TASK_PREVIEW_IDENTIFIER="local.cherrymac.lighting-acceptance"
    TASK_PREVIEW_DISPLAY="CherryMac Lighting Acceptance"
    TASK_PREVIEW_VERSION="0.1.5"
    TASK_PREVIEW_BUILD="6"
    TASK_PREVIEW_FLAGS+=(-D CHERRY_LIGHTING_TEST)
    TASK_PREVIEW_BUNDLE_NAME="$TASK_PREVIEW_DISPLAY"
fi
TASK_PREVIEW_APP="$TASK_PREVIEW_DIR/$TASK_PREVIEW_APP_NAME"
if [[ -e "$TASK_PREVIEW_APP" ]]; then
    echo "Refusing to replace an existing preview app; choose a new output directory." >&2
    exit 1
fi
TASK_PREVIEW_ARCH="$(uname -m)"
TASK_PREVIEW_STAGE="$(mktemp -d "$TASK_PREVIEW_DIR/.macro-preview.XXXXXX")"
trap 'rm -rf "$TASK_PREVIEW_STAGE"' EXIT
mkdir -p "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME/Contents/MacOS"
TASK_PREVIEW_SOURCES=()
for TASK_PREVIEW_NAME in main InputRouter CherryHardware CalculatorKeyTest KeymapWrite CalculatorHardwareTestController CherryMacro HardwareProfile WindowsProfile LightingModel HardwareWindow HardwareLighting CalculatorService HardwareTests MacroPhysicalStop; do
    TASK_PREVIEW_SOURCES+=("$TASK_SOURCE_DIR/$TASK_PREVIEW_NAME.swift")
done
xcrun swiftc "${TASK_PREVIEW_FLAGS[@]}" "${TASK_PREVIEW_SOURCES[@]}" \
    -o "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME/Contents/MacOS/CherryMac" \
    -framework Cocoa -framework IOKit -framework ApplicationServices \
    -target "$TASK_PREVIEW_ARCH-apple-macos13.0"
cp "$TASK_SOURCE_DIR/Info.plist" "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME/Contents/Info.plist"
TASK_PREVIEW_PLIST="$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TASK_PREVIEW_IDENTIFIER" "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $TASK_PREVIEW_BUNDLE_NAME" "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $TASK_PREVIEW_DISPLAY" "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TASK_PREVIEW_VERSION" "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TASK_PREVIEW_BUILD" "$TASK_PREVIEW_PLIST"
/usr/libexec/PlistBuddy -c "Add :CherryMacSourceCommit string $TASK_PREVIEW_COMMIT" "$TASK_PREVIEW_PLIST"
plutil -lint "$TASK_PREVIEW_PLIST"
codesign --force --sign - "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME"
codesign --verify --deep --strict "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME"
mv "$TASK_PREVIEW_STAGE/$TASK_PREVIEW_APP_NAME" "$TASK_PREVIEW_APP"
if [[ $# -eq 2 ]]; then
    python3 "$TASK_SOURCE_DIR/package-macro-preview.py" "$TASK_PREVIEW_DIR" --lighting-acceptance
else
    python3 "$TASK_SOURCE_DIR/package-macro-preview.py" "$TASK_PREVIEW_DIR"
fi
echo "Created $TASK_PREVIEW_APP; not launched and no keyboard accessed."
