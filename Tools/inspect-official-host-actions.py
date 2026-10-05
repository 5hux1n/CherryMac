#!/usr/bin/env python3
"""Read a fixed CommFunc.dll as data; do not load or execute the library.

This inventories named export branches and selected host API evidence. It is
not a whole-program call graph and does not authorize keyboard writes.
"""
import argparse
import hashlib
import importlib.util
import json
import struct
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "cherrymac_settings_audit", Path(__file__).with_name("inspect-official-settings.py"))
_settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_settings)
PE32 = _settings.PE32


EXPECTED_SHA256 = "c12617b0bec1131e16b5ff4159dd62cbfe0cd86a2cb5f2fe8873dc3d00f60c9b"
EXPORTS = {"UniFunc": 0x10001EF0, "UniFunc2": 0x10001FD0,
           "UniFuncForWin2000": 0x10002010}
# Compare instruction, selector, call instruction, directly called method.
BRANCHES = [
    (0x10001EF8, 0xBC, 0x10001F00, 0x100011B0),
    (0x10001F09, 0xBD, 0x10001F11, 0x100011B0),
    (0x10001F1A, 0xBE, 0x10001F22, 0x100014D0),
    (0x10001F2B, 0xBF, 0x10001F33, 0x100014D0),
    (0x10001F3C, 0xD2, 0x10001F44, 0x10001620),
    (0x10001F4D, 0xD3, 0x10001F55, 0x10001620),
    (0x10001F5E, 0xD4, 0x10001F66, 0x10001C20),
    (0x10001F6F, 0xD5, 0x10001F77, 0x10001C20),
    (0x10001F80, 0xD6, 0x10001F88, 0x10001C20),
    (0x10001F91, 0xD7, 0x10001F99, 0x10001C20),
    (0x10001FA2, 0x201, 0x10001FAC, 0x10001DD0),
    (0x10001FB5, 0x202, 0x10001FBF, 0x10001DD0),
    (0x10001FD8, 0x282, 0x10001FE7, 0x10001A30),
    (0x10001FF3, 0x291, 0x10001FFF, 0x10001EC0),
]
IMPORTS = {
    0x1000800C: "CreateThread", 0x10008110: "ShellExecuteW",
    0x10008114: "ShellExecuteExW", 0x1000813C: "MapVirtualKeyW",
    0x10008140: "keybd_event",
    0x10008144: "mouse_event", 0x10008148: "GetForegroundWindow",
    0x10008150: "AttachThreadInput", 0x10008154: "GetFocus",
    0x10008160: "PostMessageW", 0x10008178: "SendMessageW",
}


def require_bytes(pe, address, expected):
    if pe.at(address, len(expected)) != expected:
        raise ValueError(f"Unexpected instruction or data at {address:#x}")


def inspect_exports(pe):
    header = pe.u32(0x3C)
    optional = header + 24
    directory = pe.base + pe.u32(optional + 96)
    count, names_count, functions, names, ordinals = struct.unpack(
        "<5I", pe.at(directory + 20, 20))
    if not 1 <= count <= 4096 or not 1 <= names_count <= count:
        raise ValueError("Invalid export counts")
    found = {}
    for i in range(names_count):
        address = pe.base + pe.pointer(pe.base + names + i * 4)
        name = pe.at(address, 64).split(b"\0", 1)[0].decode("ascii")
        ordinal = struct.unpack("<H", pe.at(pe.base + ordinals + i * 2, 2))[0]
        if ordinal >= count:
            raise ValueError("Invalid export ordinal")
        found[name] = pe.base + pe.pointer(pe.base + functions + ordinal * 4)
    if found != EXPORTS:
        raise ValueError("Unexpected DLL exports")
    return found


def inspect(data):
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("Unsupported CommFunc.dll: SHA256 does not match analyzed version")
    pe = PE32(data)
    exports = inspect_exports(pe)
    for slot, name in IMPORTS.items():
        require_bytes(pe, pe.base + pe.pointer(slot) + 2, name.encode() + b"\0")
    branches = []
    for compare, selector, call, target in BRANCHES:
        require_bytes(pe, compare, b"\x81\xf9" + struct.pack("<I", selector))
        require_bytes(pe, call, b"\xe8" + struct.pack("<i", target - call - 5))
        branches.append({"export": "UniFunc" if compare < 0x10001FD0 else "UniFunc2",
                         "selector": selector, "compareVA": compare,
                         "callVA": call, "targetVA": target})
    # Window scroll dispatch uses PostMessageW, not a USB report send.
    require_bytes(pe, 0x100014BF, bytes.fromhex("ff1560810010"))
    # One named scrolling path invokes mouse_event with MOUSEEVENTF_WHEEL.
    require_bytes(pe, 0x10001883, bytes.fromhex("6800080000ff1544810010"))
    # Application launching path, with a dynamically resolved process-ID helper.
    require_bytes(pe, 0x10001AFF, bytes.fromhex("ff1514810010"))
    # Text selector creates the named worker, whose code sends window messages.
    require_bytes(pe, 0x10001ECE, bytes.fromhex("68301e0010"))
    require_bytes(pe, 0x10001ED7, bytes.fromhex("ff150c800010"))
    require_bytes(pe, 0x10001E8D, bytes.fromhex("6886020000"))
    require_bytes(pe, 0x10001E93, bytes.fromhex("ff1578810010"))
    legacy = []
    for compare, selector, string_push, string_address, label in [
        (0x10002019, 0xC2, 0x1000202B, 0x100084CC, "wmplayer.exe"),
        (0x1000205E, 0xC4, 0x1000206B, 0x1000849C, "calc.exe"),
        (0x10002084, 0xC5, 0x10002094, 0x1000842C, "explorer.exe"),
    ]:
        require_bytes(pe, compare, b"\x3d" + struct.pack("<I", selector))
        require_bytes(pe, string_push, b"\x68" + struct.pack("<I", string_address))
        require_bytes(pe, string_address, (label + "\0").encode("utf-16le"))
        legacy.append({"selector": selector, "compareVA": compare,
                       "referencedExecutable": label, "stringVA": string_address})
    require_bytes(pe, 0x10002021, bytes.fromhex("8b3510810010"))
    require_bytes(pe, 0x10002036, bytes.fromhex("ffd6"))
    require_bytes(pe, 0x10002077, bytes.fromhex("ff1510810010"))
    require_bytes(pe, 0x100020A0, bytes.fromhex("ff1510810010"))
    return {"schema": "cherrymac-official-host-actions-v1", "sha256": digest,
            "exports": exports, "selectorBranches": branches,
            "legacyLaunchBranches": legacy,
            "hostEvidence": {"windowScrollCallVA": 0x100014BF,
                             "mouseWheelCallVA": 0x10001888,
                             "applicationLaunchCallVA": 0x10001AFF,
                             "textWorkerVA": 0x10001E30,
                             "textMessage": 0x286},
            "hardwareWriteAuthorized": False,
            "limits": ["Static evidence from one fixed DLL; never executed",
                       "Named branches and selected API calls, not an exhaustive call graph",
                       "Does not establish keyboard bindings or firmware action encodings",
                       "Does not establish a settings command or wireless configuration support"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dll", type=Path)
    args = parser.parse_args()
    try:
        result = inspect(args.dll.read_bytes())
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, f"Read-only analysis failed: {error}\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
