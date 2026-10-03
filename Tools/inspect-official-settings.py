#!/usr/bin/env python3
"""Read-only PE/RTTI audit for the analyzed Utility executable; never runs it."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

EXPECTED_SHA256 = "a92412c6e3bd05d722c30e0d1ab1762570934b28bd31ea482ad2b51ce187f396"


class PE32:
    def __init__(self, data):
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("Not a PE executable")
        header = self.u32(0x3C)
        if self.take(header, 4) != b"PE\0\0":
            raise ValueError("Invalid PE signature")
        machine, count = struct.unpack("<HH", self.take(header + 4, 4))
        size = struct.unpack("<H", self.take(header + 20, 2))[0]
        optional = header + 24
        if machine != 0x14C or size < 96 or self.take(optional, 2) != b"\x0b\x01":
            raise ValueError("Expected an x86 PE32 executable")
        if not 1 <= count <= 96:
            raise ValueError("Invalid section count")
        self.base = self.u32(optional + 28)
        self.sections = []
        for i in range(count):
            row = optional + size + i * 40
            virtual_size, rva, raw_size, offset = struct.unpack("<4I", self.take(row + 8, 16))
            self.take(offset, raw_size)
            self.sections.append((rva, virtual_size, raw_size, offset))

    def take(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError("Truncated PE data")
        return self.data[offset:offset + size]

    def u32(self, offset):
        return struct.unpack("<I", self.take(offset, 4))[0]

    def at(self, address, size):
        rva = address - self.base
        for start, _, raw_size, offset in self.sections:
            if start <= rva and rva + size <= start + raw_size:
                return self.take(offset + rva - start, size)
        raise ValueError("Address is outside backed PE sections")

    def pointer(self, address):
        return struct.unpack("<I", self.at(address, 4))[0]

    def class_name(self, table):
        locator = self.pointer(table - 4)
        descriptor = self.pointer(locator + 12)
        name = self.at(descriptor + 8, 128).split(b"\0", 1)[0]
        return name.decode("ascii")


def inspect(path):
    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("Executable hash differs; version-specific addresses cannot be used")
    pe = PE32(data)
    device, profile = 0x77F604, 0x77D174
    if pe.class_name(device) != ".?AVCEevisionKeyboardDevice@@" or pe.class_name(profile) != ".?AVCKeyboardProfiledata@@":
        raise ValueError("Unexpected RTTI classes")
    expected = {0x280: 0x4F92D0, 0x2BC: 0x500790, 0x300: 0x4FB2F0, 0x324: 0x4FB970, 0x230: 0x4F9C10, 0x32C: 0x512DE0}
    for offset, target in expected.items():
        if pe.pointer(device + offset) != target:
            raise ValueError("Unexpected device virtual dispatch target")
    if pe.pointer(profile + 4) != 0x47CAC0 or pe.pointer(profile + 8) != 0x47C9A0:
        raise ValueError("Unexpected profile virtual dispatch target")
    text_checks = {
        0x50C22E: "81f900070000",  # lower bound 0x700
        0x50C23D: "81fa00080000",  # exclusive upper bound 0x800
        0x50C24C: "2d00070000",    # event index = value - 0x700
        0x50C260: "8b822c030000",  # virtual dispatch +0x32c
        0x50C69A: "81f900070000",
        0x50C6A6: "81fa00080000",
        0x50C6B2: "2d00070000",
        0x50C6C0: "8b822c030000",
    }
    for address, encoded in text_checks.items():
        expected_bytes = bytes.fromhex(encoded)
        if pe.at(address, len(expected_bytes)) != expected_bytes:
            raise ValueError("Unexpected text event dispatch instruction")
    return {
        "format": "CherryMacOfficialSettingsStaticAudit", "version": 1,
        "executableSHA256": digest, "method": "PE32 pointer and RTTI inspection; no execution or HID",
        "deviceClass": pe.class_name(device), "profileClass": pe.class_name(profile),
        "deviceVirtualTargets": {hex(k): hex(v) for k, v in expected.items()},
        "profileVirtualTargets": {"0x4": "0x47cac0", "0x8": "0x47c9a0"},
        "systemJSONGetter": "0x483100", "systemJSONSetter": "0x482e70",
        "systemWordOrder": ["Repeat", "RepeatDelay", "Key6Flag", "ReportSelectItem", "RFReportSelectItem", "WFlag", "WinFlag"],
        "textDispatch": {"eventRange": [0x700, 0x800], "upperBoundExclusive": True, "indexSubtract": 0x700, "deviceVirtualOffset": "0x32c", "target": "0x512de0", "instructionChecks": len(text_checks)},
        "limits": "Static class targets and generic event branches only; does not prove model 47 class selection, target report layout, USB setting writes, text trigger execution or persistence",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", help="Local CHERRY-Utility-Software.exe; it will only be read")
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.executable), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
