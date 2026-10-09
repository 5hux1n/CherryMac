#!/bin/bash
set -euo pipefail
# Compile only; starting an actual hardware test is a separate explicit action.
if [[ $# != 1 ]]; then
    echo 'Usage: bash Source/build-product-test.sh /absolute/path/CherryMacProductTest' >&2
    exit 2
fi
TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_TEST_OUTPUT="$1"
if [[ "$TASK_TEST_OUTPUT" != /* ]]; then echo 'Output must be an absolute path.' >&2; exit 2; fi
mkdir -p "$(dirname "$TASK_TEST_OUTPUT")"
xcrun swiftc -D CHERRY_PRODUCT_TEST \
    "$TASK_SOURCE_DIR/main.swift" "$TASK_SOURCE_DIR/InputRouter.swift" "$TASK_SOURCE_DIR/CherryHardware.swift" \
    "$TASK_SOURCE_DIR/CalculatorKeyTest.swift" "$TASK_SOURCE_DIR/KeymapWrite.swift" "$TASK_SOURCE_DIR/ProductKeymapTest.swift" \
    "$TASK_SOURCE_DIR/CherryMacro.swift" "$TASK_SOURCE_DIR/HardwareProfile.swift" "$TASK_SOURCE_DIR/WindowsProfile.swift" \
    "$TASK_SOURCE_DIR/LightingModel.swift" "$TASK_SOURCE_DIR/HardwareWindow.swift" "$TASK_SOURCE_DIR/HardwareLighting.swift" "$TASK_SOURCE_DIR/HardwareExtendedBackup.swift" "$TASK_SOURCE_DIR/ExtendedHardwareBackup.swift" "$TASK_SOURCE_DIR/ExtendedHardwareBackupStore.swift" \
    "$TASK_SOURCE_DIR/CalculatorService.swift" "$TASK_SOURCE_DIR/HardwareTests.swift" \
    -o "$TASK_TEST_OUTPUT" -framework Cocoa -framework IOKit -framework ApplicationServices -target "$(uname -m)-apple-macos13.0"
"$TASK_TEST_OUTPUT" --product-flow-self-test
