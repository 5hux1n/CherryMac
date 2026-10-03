#!/usr/bin/env python3
"""Read-only PE/RTTI audit for the analyzed Utility executable; never runs it."""
import argparse
import hashlib
import json
import struct
import xml.etree.ElementTree as ET
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


def inspect_model_resources(skin):
    """Validate the actual model resource, not a similarly named keyboard."""
    root = Path(skin)
    device_path = root / "XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
    option_path = root / "XML/CustomControlXML/DeviceOption_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
    device_data, option_data = device_path.read_bytes(), option_path.read_bytes()
    device, option = ET.fromstring(device_data.lstrip()), ET.fromstring(option_data.lstrip())
    if device.tag != "Window" or len(device) != 1 or device[0].tag != "EevisionKeyboardDevice":
        raise ValueError("Model resource does not select EevisionKeyboardDevice")
    names = [e.attrib.get("text") for e in option.iter("Label") if e.attrib.get("name") == "device_select_name"]
    if names != ["MX 3.0S POKEMON WIRELESS"]:
        raise ValueError("Unexpected model display name")
    return {"model": 47, "vendorID": 0x046A, "productID": 0x01CE,
            "resourceClass": device[0].tag, "displayName": names[0],
            "deviceResourceSHA256": hashlib.sha256(device_data).hexdigest(),
            "optionResourceSHA256": hashlib.sha256(option_data).hexdigest(),
            "limits": "Resource selection and fixed executable initialization only; not an observed runtime session"}


def inspect(path, skin=None):
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
        0x4FF3F7: "7515",          # nonempty branch falls through to marker
        0x4FF3F9: "c685e6fdffffa1",
        0x4FF400: "c685e7fdffff00",
        0x4FF407: "c685e8fdffff00",
        0x512047: "6a01",          # export constructs numeric flag 1
        0x512064: "68c4eb7600",    # ActionTextFlag key
        0x512E81: "3b10",          # compare logical key value while searching
    }
    for address, encoded in text_checks.items():
        expected_bytes = bytes.fromhex(encoded)
        if pe.at(address, len(expected_bytes)) != expected_bytes:
            raise ValueError("Unexpected text event dispatch instruction")
    # Tie the XML class name to its factory constructor and actual RTTI table.
    model_checks = {
        0x406C4A: "c70584d881002f000000",  # registered model 47
        0x406C54: "c70588d881006a040000",  # VID
        0x406C5E: "c7058cd88100ce010000",  # PID
        0x406C82: "6860157500",           # model option resource path
        0x488E7D: "6820a37500",           # XML class name
        0x488EBA: "e8a1d10600",           # factory constructor 0x4f6060
        0x4F609A: "c70004f67700",         # constructor vtable
        0x50B0BF: "81c1b4170000",         # reader connection storage
        0x50B165: "e856040000",           # starts raw event reader
        0x50B640: "68d0c35000",           # worker 0x50c3d0
        0x50C473: "81c1b4170000",         # reads same connection
        0x50C49A: "8a4908",               # copies ninth byte of report
    }
    for address, encoded in model_checks.items():
        expected_bytes = bytes.fromhex(encoded)
        if pe.at(address, len(expected_bytes)) != expected_bytes:
            raise ValueError("Unexpected model or event reader instruction")
    def wide_string(address, size):
        return pe.at(address, size).decode("utf-16le").split("\0", 1)[0]
    if wide_string(0x75A320, 44) != "EevisionKeyboardDevice":
        raise ValueError("Unexpected factory XML class name")
    expected_resource = "XML\\CustomControlXML\\DeviceOption_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
    if wide_string(0x751560, 160) != expected_resource:
        raise ValueError("Unexpected registered model resource path")
    result = {
        "format": "CherryMacOfficialSettingsStaticAudit", "version": 2,
        "executableSHA256": digest, "method": "PE32 pointer and RTTI inspection; no execution or HID",
        "deviceClass": pe.class_name(device), "profileClass": pe.class_name(profile),
        "deviceVirtualTargets": {hex(k): hex(v) for k, v in expected.items()},
        "profileVirtualTargets": {"0x4": "0x47cac0", "0x8": "0x47c9a0"},
        "systemJSONGetter": "0x483100", "systemJSONSetter": "0x482e70",
        "systemWordOrder": ["Repeat", "RepeatDelay", "Key6Flag", "ReportSelectItem", "RFReportSelectItem", "WFlag", "WinFlag"],
        "textDispatch": {"eventRange": [0x700, 0x800], "upperBoundExclusive": True, "indexSubtract": 0x700, "deviceVirtualOffset": "0x32c", "target": "0x512de0", "instructionChecks": len(text_checks), "nonemptyKeyRecord": [161, 0, 0], "exportedActionTextFlag": 1},
        "modelFactory": {"xmlClass": "EevisionKeyboardDevice", "constructor": "0x4f6060", "vtable": "0x77f604", "model": 47, "vendorID": 0x046A, "productID": 0x01CE, "instructionChecks": len(model_checks)},
        "rawEventReader": {"connect": "0x50b050", "start": "0x50b5c0", "worker": "0x50c3d0", "connectionObjectOffset": "0x17b4", "copiedReportBytes": 9, "eventValueBytes": [1, 2], "reportID": "not established"},
        "limits": "Static factory and reader paths only; does not prove actual interface or report ID, USB setting writes, text trigger execution or persistence",
    }
    if skin is not None:
        result["modelResource"] = inspect_model_resources(skin)
    return result



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", help="Local CHERRY-Utility-Software.exe; it will only be read")
    parser.add_argument("--skin", help="Optional extracted Skin directory; verifies target model resource without copying it")
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.executable, args.skin), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error, ET.ParseError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
