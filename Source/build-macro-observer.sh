#!/bin/bash
set -euo pipefail
# Compile only. Self-tests and hardware observation require separate commands.
if [[ $# != 1 ]]; then
    echo 'Usage: bash Source/build-macro-observer.sh /absolute/path/CherryMacMacroObserver' >&2
    exit 2
fi
TASK_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_TEST_OUTPUT="$1"
if [[ "$TASK_TEST_OUTPUT" != /* ]]; then echo 'Output must be an absolute path.' >&2; exit 2; fi
if [[ -e "$TASK_TEST_OUTPUT" || -L "$TASK_TEST_OUTPUT" ]]; then
    echo 'Refusing to replace an existing observer binary; choose a fresh output path.' >&2
    exit 1
fi
mkdir -p "$(dirname "$TASK_TEST_OUTPUT")"
TASK_OBSERVER_STAGE="$(mktemp -d "$(dirname "$TASK_TEST_OUTPUT")/.macro-observer.XXXXXX")"
trap 'rm -rf "$TASK_OBSERVER_STAGE"' EXIT
xcrun swiftc -D CHERRY_MACRO_TEST \
    "$TASK_SOURCE_DIR/main.swift" "$TASK_SOURCE_DIR/InputRouter.swift" "$TASK_SOURCE_DIR/CherryHardware.swift" \
    "$TASK_SOURCE_DIR/CalculatorKeyTest.swift" "$TASK_SOURCE_DIR/KeymapWrite.swift" "$TASK_SOURCE_DIR/MacroObserverTest.swift" "$TASK_SOURCE_DIR/MacroPhysicalStop.swift" "$TASK_SOURCE_DIR/MacroHardwareTest.swift" \
    "$TASK_SOURCE_DIR/CherryMacro.swift" "$TASK_SOURCE_DIR/HardwareProfile.swift" "$TASK_SOURCE_DIR/WindowsProfile.swift" \
    "$TASK_SOURCE_DIR/LightingModel.swift" "$TASK_SOURCE_DIR/HardwareWindow.swift" "$TASK_SOURCE_DIR/HardwareLighting.swift" "$TASK_SOURCE_DIR/HardwareExtendedBackup.swift" "$TASK_SOURCE_DIR/ExtendedHardwareBackup.swift" "$TASK_SOURCE_DIR/ExtendedHardwareBackupStore.swift" "$TASK_SOURCE_DIR/ExtendedHardwareCapture.swift" "$TASK_SOURCE_DIR/ExtendedHardwareReadFrames.swift" "$TASK_SOURCE_DIR/ExtendedCaptureJournal.swift" "$TASK_SOURCE_DIR/ExtendedHardwareUSB.swift" "$TASK_SOURCE_DIR/ExtendedUSBRegistryIdentity.swift" "$TASK_SOURCE_DIR/ReceiverUSBInventory.swift" "$TASK_SOURCE_DIR/ReceiverPairingReports.swift" \
    "$TASK_SOURCE_DIR/CalculatorService.swift" "$TASK_SOURCE_DIR/HardwareTests.swift" \
    -o "$TASK_OBSERVER_STAGE/CherryMacMacroObserver" -framework Cocoa -framework IOKit -framework ApplicationServices -target "$(uname -m)-apple-macos13.0"
# Same-directory hard-link publication is exclusive. If another build creates
# the destination meanwhile, fail without replacing its code identity.
ln "$TASK_OBSERVER_STAGE/CherryMacMacroObserver" "$TASK_TEST_OUTPUT"
echo "Compiled $TASK_TEST_OUTPUT; no self-tests, launch, permissions or hardware access performed."
