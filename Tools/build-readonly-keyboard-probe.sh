#!/bin/bash
set -euo pipefail
# Build once into a dedicated development directory; never launch or overwrite
# an already authorized app. No keyboard access or tests during packaging.
if [[ $# -ne 1 ]]; then echo 'Usage: build-readonly-keyboard-probe.sh OUTPUT_DIRECTORY' >&2; exit 2; fi
TASK_PROBE_SOURCE="$(cd "$(dirname "$0")" && pwd)/readonly-keyboard-probe.swift"
TASK_PROBE_FRAMES="$(dirname "$TASK_PROBE_SOURCE")/../Source/LegacyStatusTailReadFrames.swift"
TASK_PROBE_OUTPUT="$1"
mkdir -p "$TASK_PROBE_OUTPUT"
TASK_PROBE_OUTPUT="$(cd "$TASK_PROBE_OUTPUT" && pwd)"
TASK_PROBE_APP="$TASK_PROBE_OUTPUT/CherryMacReadOnlyProbeV4.app"
if [[ -e "$TASK_PROBE_APP" ]]; then echo 'App already exists; keep its code identity and permission unchanged.' >&2; exit 1; fi
TASK_PROBE_STAGE="$(mktemp -d "$TASK_PROBE_OUTPUT/.readonly-probe.XXXXXX")"
trap 'rm -rf "$TASK_PROBE_STAGE"' EXIT
TASK_PROBE_STAGED_APP="$TASK_PROBE_STAGE/CherryMacReadOnlyProbeV4.app"
mkdir -p "$TASK_PROBE_STAGED_APP/Contents/MacOS"
cp "$TASK_PROBE_SOURCE" "$TASK_PROBE_STAGE/main.swift"
env DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}" xcrun swiftc "$TASK_PROBE_STAGE/main.swift" "$TASK_PROBE_FRAMES" \
    -o "$TASK_PROBE_STAGED_APP/Contents/MacOS/CherryMacReadOnlyProbe" -framework Cocoa -framework IOKit \
    -target "$(uname -m)-apple-macos13.0" -warnings-as-errors
python3 - "$TASK_PROBE_STAGED_APP" "$TASK_PROBE_SOURCE" "$TASK_PROBE_FRAMES" <<'PY'
import hashlib,plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]);source=Path(sys.argv[2]);frames=Path(sys.argv[3]);info={'CFBundleIdentifier':'local.cherrymac.read-only-probe.v4','CFBundleExecutable':'CherryMacReadOnlyProbe','CFBundleName':'CherryMac Read Only Probe v4','CFBundleDisplayName':'CherryMac Read Only Probe v4','CFBundleShortVersionString':'0.4.0','CFBundleVersion':'4','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0','LSUIElement':True,'CherryMacProbeSourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'CherryMacProbeFramesSHA256':hashlib.sha256(frames.read_bytes()).hexdigest()}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$TASK_PROBE_STAGED_APP"
codesign --verify --deep --strict "$TASK_PROBE_STAGED_APP"
mv "$TASK_PROBE_STAGED_APP" "$TASK_PROBE_APP"
echo "Built $TASK_PROBE_APP; not launched and no keyboard accessed."
