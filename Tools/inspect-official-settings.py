#!/usr/bin/env python3
"""Read-only PE/RTTI audit for the analyzed Utility executable; never runs it."""
import argparse
import hashlib
import html
import json
import re
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


def initialized_words(pe, start, end, destination):
    """Decode only straight-line constant word stores; never execute x86 code.

    Reject calls, jumps, unknown registers/instructions and writes outside the
    eleven-word row. This is deliberately not a general-purpose emulator.
    """
    code = pe.at(start, end - start)
    registers, words, cursor = {}, {}, 0
    while cursor < len(code):
        opcode = code[cursor]
        if 0xB8 <= opcode <= 0xBA and cursor + 5 <= len(code):
            registers[opcode - 0xB8] = struct.unpack_from("<I", code, cursor + 1)[0]
            cursor += 5
        elif code[cursor:cursor + 2] == b"\x33\xd2":
            registers[2] = 0
            cursor += 2
        elif code[cursor:cursor + 2] == b"\x33\xc0":
            registers[0] = 0
            cursor += 2
        else:
            if code[cursor:cursor + 2] == b"\x66\xa3" and cursor + 6 <= len(code):
                register, address, size = 0, struct.unpack_from("<I", code, cursor + 2)[0], 6
            elif (code[cursor:cursor + 2] == b"\x66\x89" and cursor + 7 <= len(code)
                  and code[cursor + 2] in (0x0D, 0x15)):
                register = (code[cursor + 2] >> 3) & 7
                address, size = struct.unpack_from("<I", code, cursor + 3)[0], 7
            else:
                raise ValueError("Unexpected interface initializer instruction")
            offset = address - destination
            if register not in registers or offset not in range(0, 22, 2) or offset in words:
                raise ValueError("Unexpected interface initializer store")
            words[offset] = registers[register] & 0xFFFF
            cursor += size
    if len(words) != 11:
        raise ValueError("Incomplete interface initializer")
    return [words[offset] for offset in range(0, 22, 2)]


SYSTEM_DEVICE_CHECKS = {
    0x4AEDF1: "680c027600",          # KbBasicSetWnd.xml
    0x4AEDDC: "e84fcb0400",          # initial settings getter
    0x4AF14D: "e82ea2f7ff",          # normal polling UI setup
    0x4AF16B: "e880a5f7ff",          # populate selected report index
    0x4AFA7A: "e8c19df7ff",          # read edited polling index
    0x42984A: "8b806c0a0000",        # selected-index getter
    0x4AFF1F: "e80cba0400",          # refresh seven-word settings
    0x4AFFF4: "668945e6",            # ordinary branch ReportSelectItem
    0x4B001C: "e89fb80400",          # save settings JSON
    0x4B002F: "8b8200030000",        # profile save virtual +0x300
    0x4B0045: "8b8230020000",        # device virtual +0x230
    0x4B007F: "8b82bc020000",        # parameter send virtual +0x2bc
    0x4FB8C0: "558bec",              # selected seven-word device setter
    0x4FB8CA: "05e03f0000",          # in-memory seven-word structure
    0x4FB8D2: "8908",
    0x4FB8D7: "895004",
    0x4FB8DD: "894808",
    0x4FB8E4: "6689500c",
    0x4FB910: "81c100400000",        # profile object
    0x4FB916: "e85575f8ff",          # JSON setter, not transport
    0x4FB91E: "c21000",
    0x4F99D3: "81c100400000",
    0x4F99D9: "e82297f8ff",          # JSON getter
    0x4F99E4: "81c1e03f0000",
    0x4F99EC: "8911",
    0x4F99F1: "895104",
    0x4F99F7: "895108",
    0x4F99FE: "6689410c",
    0x4F874A: "3dda010000",          # selected specialized readback allowlist
    0x4F874F: "746c",
    0x4F875E: "81fae6010000",
    0x4F8764: "7457",
    0x4F8773: "81f9ef010000",
    0x4F8779: "7442",
    0x4F8788: "3dfb010000",
    0x4F878D: "742e",
    0x4F879C: "81fa42010000",
    0x4F87A2: "7419",
    0x4F87B1: "81f94c010000",
    0x4F87B7: "0f85d6000000",
    0x4F87D0: "e82ba9f8ff",
    0x4F87FF: "c1e106",
    0x4F8822: "6bc835",
    0x4F8825: "660fb6940d40ffffff",
    0x4F8840: "6bd136",
    0x4F8843: "660fb6841540ffffff",
    0x4F8802: "51",                  # offset = bank << 6
    0x4F8803: "6a40",                # 64-byte readback
    0x4F8818: "e8c350feff",
    0x4F8834: "668990e63f0000",      # report word from parameter byte 53
    0x4F8852: "668981e83f0000",      # RF report word from parameter byte 54
    0x4F888E: "e8dda5f8ff",
}


PROFILE_SETTINGS_RELOAD_CHECKS = {
    0x4F93E3: "81c100400000",
    0x4F93E9: "e8129df8ff",
    0x4F93F1: "81c2e03f0000",
    0x4F940B: "6689420c",
    0x4F9417: "8b8200030000",
    0x4F9427: "8b828c020000",
    0x4F94D4: "81c100400000",
    0x4F94DA: "e8219cf8ff",
    0x4F94E2: "81c1e03f0000",
    0x4F94FC: "6689410c",
    0x4F954D: "8b8200030000",
    0x4F955D: "8b828c020000",
    0x4FAA63: "8b82cc020000",
    0x4FAA6E: "e80d320100",
    0x4FB008: "81f9ce010000",
    0x4FB018: "8b90ec020000",
    0x4FB023: "0f84a6010000",
    0x4FA30D: "68f8dc7600",
    0x4FA31F: "ff15ccb06e00",
    0x50DCD9: "81c2c83f0000",
    0x50DCE6: "e84511f7ff",
    0x53FA2B: "c7801421000001000000",  # initial UI selection
    0x54078C: "8b4d08",
    0x54078F: "898814210000",
    0x5407A1: "68f8647700",          # device_function_switch
    0x5407DC: "6828657700",          # device_key_function_switch
    0x540868: "83e901",
    0x54087B: "ff2495380c5400",      # UI switch dispatch
    0x540C6A: "8b8014210000",        # UI selection getter, not an ACK
    0x501DAB: "8b4508",
    0x501DAE: "50",
    0x501DB5: "e8c6e90300",          # target override calls UI setter
}


def inspect_profile_settings_reload(pe):
    for offset, target in {0x28C: 0x4FAA50, 0x2CC: 0x4FA240,
                           0x2E8: 0x501D70, 0x2EC: 0x540C60}.items():
        if pe.pointer(0x77F604 + offset) != target:
            raise ValueError("Unexpected profile settings reload virtual target")
    for address, encoded in PROFILE_SETTINGS_RELOAD_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected profile settings reload instruction")
    control_names = {0x7764F8: "device_function_switch", 0x776528: "device_key_function_switch"}
    for address, name in control_names.items():
        encoded = (name + "\0").encode("utf-16-le")
        if pe.at(address, len(encoded)) != encoded:
            raise ValueError("Unexpected profile settings refresh control name")
    return {"instructionChecks": len(PROFILE_SETTINGS_RELOAD_CHECKS),
            "profileReloadMethods": ["0x4f9320", "0x4f9440"],
            "settingsSource": "JSON getter 0x483100 to device +0x3fe0",
            "followingVirtualOffsets": ["0x300", "0x28c"],
            "selectedRefreshMethod": "0x4faa50",
            "refreshInitialCalls": {"virtual0x2cc": "0x4fa240", "direct": "0x50dc80"},
            "targetSpecificRefreshBranch": "01CE compares UI selection getter +0x2ec with 1; not a hardware reply",
            "uiSelection": {"deviceOffset": "0x2114", "initialValue": 1,
                            "setter": "0x540780", "getter": "0x540c60",
                            "targetSetterOverride": "0x501d70",
                            "controlNames": list(control_names.values())},
            "limits": "Named copy and refresh call sites only. These calls do not identify a settings USB report. Nested paths and runtime behavior remain unverified; no inference that all settings are unsupported or host-only."}


# Current dialog dispatch, separate from the legacy keyboard-image controls.
DIALOG_POLLING_CHECKS = {
    0x4AEF76: "81fada010000", 0x4AEF7C: "743e",
    0x4AEF8B: "81f9e6010000", 0x4AEF91: "7429",
    0x4AEFA0: "3def010000", 0x4AEFA5: "7415",
    0x4AEFB4: "81fa4c010000", 0x4AEFBA: "757b",
    0x4AF044: "81fafb010000", 0x4AF04A: "757d",
    0x4AF0D6: "81f942010000", 0x4AF0DC: "7565",
    0x4AF143: "6a00", 0x4AF145: "6a00",
    0x4AF14D: "e82ea2f7ff", 0x4AF160: "0fb755e6",
    0x4AF16B: "e880a5f7ff",
    0x429389: "0fb64508", 0x42938D: "85c0",
    0x42938F: "0f848c000000",  # false bypasses higher-rate visibility calls
    0x429395: "68909b7200", 0x4293A9: "68bc9b7200",
    0x4293BD: "68e89b7200", 0x4293E3: "6a01",
    0x4293ED: "8b8218010000", 0x4293F3: "ffd0",
    0x4293F5: "6a01", 0x4293FF: "8b8218010000",
    0x429405: "ffd0", 0x429407: "0fb64d0c",
    0x42940D: "7412", 0x42940F: "6a01",
    0x429419: "8b9018010000", 0x42941F: "ffd2",
    0x429421: "68149c7200",
}

# These named sites were additionally located by an offline x86 instruction
# scan. Checking them does not make the inventory exhaustive (indirect calls,
# dynamically loaded modules and alternate instruction entry points remain).
SETTINGS_DIRECT_CALLS = {
    0x4AEDDC: (0x4FB930, "dialog initial read"),
    0x4AFF1F: (0x4FB930, "dialog apply read"),
    0x4B001C: (0x4FB8C0, "dialog apply settings copy"),
    0x4F87D0: (0x483100, "parameter readback update"),
    0x4F888E: (0x482E70, "parameter readback JSON save"),
    0x4F93E9: (0x483100, "profile reload"),
    0x4F94DA: (0x483100, "profile reload"),
    0x4F99D9: (0x483100, "profile state load"),
    0x4FB916: (0x482E70, "device settings JSON save"),
    0x4FDD30: (0x482E70, "parameter event JSON save"),
    0x500A77: (0x483100, "parameter work buffer construction"),
}


def inspect_dialog_polling_dispatch(pe):
    for address, encoded in DIALOG_POLLING_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected current dialog polling dispatch instruction")
    names = {0x729B90: "polling_rate_option_4", 0x729BBC: "polling_rate_option_5",
             0x729BE8: "polling_rate_option_6", 0x729C14: "report_layout"}
    for address, name in names.items():
        encoded = (name + "\0").encode("utf-16-le")
        if pe.at(address, len(encoded)) != encoded:
            raise ValueError("Unexpected current dialog polling control name")
    calls = []
    for address, (target, role) in SETTINGS_DIRECT_CALLS.items():
        expected = b"\xe8" + struct.pack("<i", target - address - 5)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected named settings direct call")
        calls.append({"address": hex(address), "target": hex(target), "role": role})
    return {"instructionChecks": len(DIALOG_POLLING_CHECKS),
            "specialPollingSetupProducts": [0x1DA, 0x1E6, 0x1EF, 0x14C, 0x1FB, 0x142],
            "targetProduct": 0x1CE, "targetSetup": "0x4af143",
            "targetSetupArguments": [False, False],
            "higherRateVisibilityCallsBypassed": True,
            "higherRateControlNames": list(names.values())[:3],
            "selectedField": "ReportSelectItem", "namedDirectCalls": calls,
            "limits": "The checked setup path does not enable indices 4..6. Other UI mutations and indirect/dynamic module calls are not excluded. This is not hardware polling-rate support or a settings write protocol."}


# Identical member offsets do not identify an object type or wire command.
SETTINGS_LAYOUT_CHECKS = {
    0x483113: "33c0", 0x483115: "668945ec", 0x483119: "33c9",
    0x48311B: "894dee", 0x48311E: "894df2", 0x483121: "894df6",
    0x483137: "0f854b010000", 0x48313D: "68c08b7400",
    0x48315C: "0f8526010000", 0x48328B: "81c1a8040000",
    0x483294: "8911", 0x483299: "894104", 0x48329F: "895108",
    0x4832A6: "6689410c", 0x4832AD: "81c1a8040000",
    0x4832B8: "8902", 0x4832BD: "894204", 0x4832C3: "894208",
    0x4832CA: "66894a0c",
    0x481A4C: "68a0657400", 0x481BBC: "81c7a8040000",
    0x481BC2: "b908000000", 0x481BCA: "f3a5",
    0x481BCF: "81c6a8040000", 0x481BD5: "b908000000",
    0x481BDD: "f3a5", 0x4EB7B6: "81c148260000",
    0x4EB7BC: "e83f62f9ff", 0x4EB7C4: "81c7282b0000",
    0x4EB7CA: "b908000000", 0x4EB7D1: "f3a5",
}
SETTINGS_LAYOUT_NAMES = {
    0x748BC0: "SystemStages", 0x748BD8: "Repeat", 0x748BF0: "RepeatDelay",
    0x748C0C: "Key6Flag", 0x748C28: "ReportSelectItem",
    0x748C4C: "RFReportSelectItem", 0x748C70: "WFlag", 0x748C88: "WinFlag",
    0x7465A0: "SystemSetStages", 0x7465C0: "MagicEnable", 0x7465DC: "MagicType",
    0x7465F8: "EqType", 0x746610: "CustomEqSeletIndex", 0x746634: "MicInSelect",
    0x746650: "MicInValue", 0x74666C: "MicMoniterSelect", 0x746690: "MicMoniterValue",
}


def inspect_settings_layouts(pe):
    for address, encoded in SETTINGS_LAYOUT_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected settings layout instruction")
    for address, name in SETTINGS_LAYOUT_NAMES.items():
        expected = (name + "\0").encode("ascii")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected settings layout JSON name")
    return {"instructionChecks": len(SETTINGS_LAYOUT_CHECKS),
            "keyboard": {"getter": "0x483100", "namespace": "SystemStages",
                         "structureBytes": 14, "elementType": "UInt16", "elementCount": 7,
                         "localInitiallyZero": True, "earlyBranches": "0x483137 / 0x48315c to 0x483288",
                         "earlyBranchResult": "Zero-initialized local replaces member +0x4a8, then copies to output"},
            "otherSettings": {"getter": "0x481a00", "namespace": "SystemSetStages",
                              "structureBytes": 32, "elementType": "UInt32", "elementCount": 8,
                              "fieldNames": list(SETTINGS_LAYOUT_NAMES.values())[9:],
                              "namedCaller": "0x4eb7bc", "callerProfileOffset": "0x2648",
                              "callerOutputOffset": "0x2b28"},
            "limits": "The same +0x4a8 displacement occurs in different layouts. It does not prove the same object instance, shared storage, a keyboard transport or a firmware command. Zero JSON fallback does not authorize writing hardware defaults."}


# Parameter-state notifications are window messages, not vendor reports.
SETTINGS_WINDOW_MESSAGE_CHECKS = {
    0x4FDD7A: "8b8280020000", 0x4FDD80: "ffd0", 0x4FDD84: "742d",
    0x4FDD94: "0fb788e83f0000", 0x4FDD9B: "51", 0x4FDD9C: "68190c0000",
    0x4FDDA4: "8b82641f0000", 0x4FDDAB: "ff15a0be6e00",
    0x4FDDC1: "0fb788e63f0000", 0x4FDDC8: "51", 0x4FDDC9: "68190c0000",
    0x4FDDD1: "8b82641f0000", 0x4FDDD8: "ff15a0be6e00",
    0x493B81: "817d08190c0000", 0x493B88: "7534",
    0x493B90: "83b96c14000000", 0x493B99: "8b5510", 0x493B9C: "52",
    0x493B9D: "8b450c", 0x493BA0: "50", 0x493BA1: "68190c0000",
    0x493BAC: "8b916c140000", 0x493BB3: "ff15a0be6e00",
}


SETTINGS_STATUS_PREDICATE_CHECKS = {
    0x4F92DA: "83b8840a000000", 0x4F92E1: "7428",
    0x4F92E6: "83b9bc10000000", 0x4F92ED: "741c",
    0x4F92F2: "81c1380a0000", 0x4F92F8: "e8534bfeff",
    0x4F9302: "7407", 0x4F9304: "b801000000", 0x4F930B: "33c0",
    0x4DDE69: "c645bc00", 0x4DDE6D: "6a3f", 0x4DDE6F: "6a00",
    0x4DDE71: "8d45bd", 0x4DDE75: "e826941a00",
    0x4DDE84: "b901000000", 0x4DDE89: "6bd100", 0x4DDE8C: "c64415bc04",
    0x4DDE91: "b801000000", 0x4DDE96: "6bc803", 0x4DDE99: "c6440dbcaa",
    0x4DDFAF: "8b9574ffffff", 0x4DDFB5: "83ba8406000000",
    0x4DDFBC: "7507", 0x4DDFBE: "b001", 0x4DDFC0: "e9d1000000",
    0x4DDFDD: "6a40", 0x4DDFDF: "8d8d7cffffff", 0x4DDFE6: "6a40",
    0x4DDFE8: "8d55bc", 0x4DDFF2: "e889b3ffff",
    0x4DE01A: "b901000000", 0x4DE01F: "c1e103",
    0x4DE022: "0fb6940d7cffffff", 0x4DE02A: "81faff000000",
    0x4DE030: "7509", 0x4DE032: "c6857bffffff01",
    0x4DE03B: "c6857bffffff00", 0x4DE042: "83bd58ffffff01",
    0x4DE049: "7407", 0x4DE04B: "c6857bffffff00",
    0x4DE052: "b801000000", 0x4DE057: "6bc807",
    0x4DE05A: "0fb6940d7cffffff", 0x4DE062: "81faff000000",
    0x4DE068: "7507", 0x4DE06A: "c6857bffffff00",
    0x4DE071: "b801000000", 0x4DE076: "6bc807",
    0x4DE079: "0fb6940d7cffffff", 0x4DE081: "81fafe000000",
    0x4DE087: "7507", 0x4DE089: "c6857bffffff00",
    0x4DE090: "8a857bffffff",
    0x4DE967: "837d0801", 0x4DE96B: "7519",
    0x4DE970: "c7808406000000000000", 0x4DE97D: "c6819006000038",
    0x4DE986: "837d0802", 0x4DE98A: "7519",
    0x4DE98F: "c7828406000001000000", 0x4DE99C: "c6809006000037",
    0x4DE9A5: "837d0803", 0x4DE9A9: "7519",
    0x4DE9AE: "c7818406000001000000", 0x4DE9BB: "c6829006000018",
    0x4DE9C7: "c7808406000000000000", 0x4DE9D4: "c6819006000038",
    0x49A469: "8982bc100000", 0x49A475: "83b9bc10000000",
    0x49A47C: "0f84aa000000", 0x49A482: "6a02",
    0x49A48A: "81c1380a0000", 0x49A490: "e8cb440400",
    0x49A4B4: "81c1380a0000", 0x49A4BA: "e891390400",
    0x49A52C: "6a01", 0x49A534: "81c1380a0000", 0x49A53A: "e821440400",
}


def inspect_settings_status_predicate(pe):
    if pe.pointer(0x77F604 + 0x280) != 0x4F92D0:
        raise ValueError("Unexpected settings status predicate dispatch")
    for address, encoded in SETTINGS_STATUS_PREDICATE_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected settings status predicate instruction")
    return {"instructionChecks": len(SETTINGS_STATUS_PREDICATE_CHECKS),
            "virtualOffset": "0x280", "method": "0x4f92d0",
            "guards": ["device+0xa84 != 0", "device+0x10bc != 0"],
            "communicationMember": "0xa38", "helper": "0x4dde50",
            "guardAlias": {"deviceMember": "0x10bc", "communicationMember": "0x684",
                           "relationship": "0xa38 + 0x684 == 0x10bc",
                           "limits": "The outer guard excludes the helper's no-exchange case if this shared field does not change between guard and call"},
            "probe": {"reportID": 4, "commandByte": 3, "command": "0xaa",
                      "requestLength": 64, "replyLength": 64, "exchange": "0x4d9380",
                      "replyConditions": ["exchange result == 1", "reply[8] == 0xff",
                                          "reply[7] != 0xff", "reply[7] != 0xfe"]},
            "withoutExchange": {"condition": "communication+0x684 == 0", "returns": True},
            "hostSelectorSetter": {"method": "0x4de960",
                                   "cases": [{"argument": 1, "member684": 0, "byte690": 56},
                                             {"argument": 2, "member684": 1, "byte690": 55},
                                             {"argument": 3, "member684": 1, "byte690": 24},
                                             {"argument": "other", "member684": 0, "byte690": 56}],
                                   "limits": "Named host stores only; the physical transports and uses of byte690 are not classified here"},
            "namedSelectorCalls": [{"call": "0x49a490", "argument": 2,
                                    "followupProbe": "0x49a4ba"},
                                   {"call": "0x49a53a", "argument": 1}],
            "hardwareWriteAuthorized": False,
            "limits": ["Named status predicate, not a settings write acknowledgement",
                       "The physical meaning of reply[8] and selector arguments is not established",
                       "The helper's no-exchange return is not reachable through the outer guard without a state change",
                       "No live query or new product transport permission"]}


def inspect_default_macro_semantics(pe):
    """Distinguish JSON macro imports from default-path light-list locks."""
    checks = {
        0x47C788: "e8b39d0c00", 0x47C888: "05a8030000",
        0x47C891: "e88a990c00", 0x47C8CC: "c28800",
        0x4F9FB2: "81c1d8210000", 0x4F9FB8: "e8f3cefdff",
        0x4F9FCA: "81c100400000", 0x4F9FD0: "e8fb2cf8ff",
        0x4F9FE8: "81c118220000", 0x4F9FEE: "e8adaaffff",
        0x4FA031: "81c1d8210000", 0x4FA043: "8b5014", 0x4FA046: "ffd2",
        0x53F813: "81c1d8210000", 0x53F819: "e81216faff",
        0x4E0E6C: "c70004706f00", 0x4D6EBE: "ff1570bc6e00",
        0x4E0DDE: "ff156cbc6e00", 0x47CD35: "81c170040000",
        0x47CDBF: "68345e7400", 0x47CEBC: "68745e7400",
        0x47D275: "c20400",
        0x4EBCB7: "683c8d7600", 0x4EBCE3: "e87831f7ff",
        0x4EBCF8: "0f8516010000", 0x527B27: "68e4267700",
        0x527B53: "e80873f3ff", 0x53B0B7: "68a84f7700",
        0x53B0E3: "e8783df2ff", 0x53B0F8: "0f8516010000",
    }
    for address, encoded in checks.items():
        value = bytes.fromhex(encoded)
        if pe.at(address, len(value)) != value:
            raise ValueError("Unexpected default macro semantics instruction")
    if pe.pointer(0x6F7004 + 0x14) != 0x4E0DD0:
        raise ValueError("Unexpected critical-section virtual method")
    imports = {}
    for slot, name in {0x6EBC70: "EnterCriticalSection", 0x6EBC6C: "LeaveCriticalSection"}.items():
        value = (name + "\0").encode("ascii")
        if pe.at(pe.base + pe.pointer(slot) + 2, len(value)) != value:
            raise ValueError("Unexpected default refresh synchronization import")
        imports[hex(slot)] = name
    for address, name in {0x745E34: "LightInfo", 0x745E74: "LEDEffectList", 0x745E94: "LEDREGMode",
                          0x768D3C: "MacroInfo", 0x7726E4: "MacroInfo", 0x774FA8: "MacroInfo"}.items():
        value = (name + "\0").encode("ascii")
        if pe.at(address, len(value)) != value:
            raise ValueError("Unexpected default macro/light JSON field")
    return {"instructionChecks": len(checks), "hardwareWriteAuthorized": False,
            "deviceRowLoad": {"method": "0x47c700", "selectedJSONMember": "0x3a8", "copyReturn": "0x47c891"},
            "defaultRefreshLightList": {"method": "0x4f9c10", "getter": "0x47ccd0", "getterSourceMember": "0x470",
                "fields": ["LightInfo", "LEDEffectList", "LEDREGMode"], "getterSHA256": hashlib.sha256(pe.at(0x47CCD0, 0x47D278-0x47CCD0)).hexdigest(),
                "destinationVector": "0x2218", "criticalSectionMember": "0x21d8", "criticalSectionConstructor": "0x4e0e30",
                "vtable": "0x6f7004", "virtual14": "0x4e0dd0", "imports": imports,
                "conclusion": "The refresh calls are Enter/LeaveCriticalSection around a light-effect list copy, not a macro-bank erase or a send inferred from virtual +0x14."},
            "otherMacroJSONConsumers": {"methods": ["0x4ebc10", "0x527a80", "0x53b010"],
                "copyMember": "0x2584", "copyHelper": "0x45ee60", "nullBranches": ["0x4ebcf8", "0x53b0f8"],
                "model47DefaultAssociationProven": False},
            "pendingMacroStorageSemantics": True,
            "limits": "A null MacroInfo in a default JSON is not proof of hardware erasure. The three named macro consumers belong to other device classes, as resolved in defaultFinalRefresh; untraced cross-class calls remain outside that result. No execution, HID observation or persistence claim."}



def inspect_default_final_refresh(pe):
    """Resolve class-specific +2cc before interpreting repeated member offsets."""
    classes={
        0x77F050:(".?AVCEevisionHS6533Device@@",0x4EBC10),
        0x77FA58:(".?AVCEevisionMouseDevice@@",0x527A80),
        0x77FDE0:(".?AVCEevisionMousePadDevice@@",0x53B010),
        0x77F604:(".?AVCEevisionKeyboardDevice@@",0x4FA240),
    }
    for table,(name,target) in classes.items():
        if pe.class_name(table)!=name or pe.pointer(table+0x2CC)!=target:
            raise ValueError("Unexpected default refresh class dispatch")
    virtuals={0x28C:0x4FAA50,0x2CC:0x4FA240}
    for offset,target in virtuals.items():
        if pe.pointer(0x77F604+offset)!=target:
            raise ValueError("Unexpected target final-refresh dispatch")
    checks={
        0x4F9427:"8b828c020000",0x4F942D:"ffd0",
        0x4FAA63:"8b82cc020000",0x4FAA69:"ffd0",0x4FAA6E:"e80d320100",
        0x4FA28A:"81c184250000",0x4FA290:"e8cb4bf6ff",
        0x4FA2A2:"7441",0x4FA2D5:"e8b6aaffff",
        0x4FA30D:"68f8dc7600",0x4FA382:"81c18b210000",0x4FA388:"e803b1f8ff",
        0x4FA3B4:"68e4dc7600",0x4FA7D1:"68b0dd7600",0x4FA879:"680cde7600",
        0x50DCB2:"68b8e77600",0x50DCC7:"ff15a4b36e00",
        0x50DCD9:"81c2c83f0000",0x50DCE6:"e84511f7ff",
        0x5425ED:"68386a7700",0x5425F9:"ff15c0b16e00",
    }
    for address,encoded in checks.items():
        raw=bytes.fromhex(encoded)
        if pe.at(address,len(raw))!=raw:
            raise ValueError("Unexpected default final-refresh instruction")
    strings={0x76DCF8:("default_light.json","utf-16-le"),0x76DCE4:("DefaultLightName","ascii"),
             0x76DE0C:("AreaLightName","ascii"),0x76E7B8:("text_test","utf-16-le"),
             0x776A38:("DefaultData%d.json","utf-16-le")}
    for address,(name,encoding) in strings.items():
        raw=(name+"\0").encode(encoding)
        if pe.at(address,len(raw))!=raw:
            raise ValueError("Unexpected default final-refresh resource name")
    bodies={
        0x4F9320:(0x4F943D,"74e956decaf29bba242c477440ab95efb0ce9ce58171cd95e38d96770af42be5"),
        0x4FAA50:(0x4FB2E9,"0d048e10f5665239c040f279c8fd55be32863d4429b8afb8bb65a41c710bdde5"),
        0x4FA240:(0x4FAA44,"21e907a44ec5a64672e8282748b0993dc3e07e590b537cd059899a142ec14543"),
        0x50DC80:(0x50EC58,"bb2832973fc8218a1a9a5ad893c3da57abf18d6ffe62bde2cf66a90d47f73583"),
        0x542540:(0x5426B5,"5d5cf8ed145527df368cf1adb296c9273bf82960097e292fb84717310c0758d1"),
    }
    for start,(end,digest) in bodies.items():
        if hashlib.sha256(pe.at(start,end-start)).hexdigest()!=digest:
            raise ValueError("Unexpected default final-refresh function body")
    return {"instructionChecks":len(checks),"resourceNameChecks":len(strings),
            "classDispatch":{hex(table):{"class":name,"virtual2cc":hex(target)} for table,(name,target) in classes.items()},
            "targetFinalCalls":["0x4f9320 -> virtual +0x28c / 0x4faa50","0x4faa50 -> virtual +0x2cc / 0x4fa240","0x4faa50 -> 0x50dc80"],
            "target2ccInput":"default_light.json via configuration member +0x218b, with DefaultLightName and AreaLightName fields",
            "keyLabelRefresh":"0x50dc80 copies device+0x3fc8 key definitions and locates text_test using the DuiLib control lookup import",
            "defaultRowSource":"0x542540 formats DefaultData%d.json using its supplied index; separate from default_light.json",
            "functionBodies":{hex(a):{"endExclusive":hex(b),"sha256":h} for a,(b,h) in bodies.items()},
            "macroConsumerClassAssociation":"The three previously found MacroInfo consumers are +0x2cc methods of HS6533, mouse and mouse-pad classes. Target keyboard +0x2cc is a different method.",
            "pendingMacroStorageSemantics":True,
            "limits":"Class-specific virtual dispatch and named JSON/UI inputs only. Do not treat common member +0x2584 as one data type across classes. Nested callbacks, key sender branches, implicit firmware side effects and the full program remain outside this conclusion; no macro-bank erase/retention, runtime or persistence proof."}



def inspect_default_control_refresh(pe):
    """Keep per-key display state apart from the keyboard's USB configuration."""
    virtuals = {0x2EC: 0x540C60, 0x38C: 0x505AB0}
    for offset, target in virtuals.items():
        if pe.pointer(0x77F604 + offset) != target:
            raise ValueError("Unexpected default control-refresh dispatch")
    checks = {
        0x4FB008: "81f9ce010000", 0x4FB00E: "7519",
        0x4FB018: "8b90ec020000", 0x4FB01E: "ffd2",
        0x4FB020: "83f801", 0x4FB023: "0f84a6010000",
        0x4FB2B1: "0fb6915c210000", 0x4FB2B8: "83fa15",
        0x4FB2BB: "7514", 0x4FB2BD: "6a01",
        0x4FB2C7: "8b828c030000", 0x4FB2CD: "ffd0",
        0x4FB2D1: "6a00", 0x4FB2DB: "8b828c030000", 0x4FB2E1: "ffd0",
        0x505ACE: "81c124210000", 0x505AD4: "e837caf1ff",
        0x505AE9: "81c124210000", 0x505AEF: "e8fcc9f1ff",
        0x505AF6: "e8e5f6feff",
        0x4F51ED: "8988240d0000", 0x4F51F6: "ff15dcb36e00",
        0x540C6A: "8b8014210000",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError(f"Unexpected default control-refresh instruction at {address:#x}")
    name = "?Invalidate@CControlUI@DuiLib@@QAEXXZ"
    if pe.at(pe.base + pe.pointer(0x6EB3DC) + 2, len(name) + 1) != (name + "\0").encode("ascii"):
        raise ValueError("Unexpected control invalidation import")
    bodies = {
        0x4FAA50: (0x4FB2E9, "0d048e10f5665239c040f279c8fd55be32863d4429b8afb8bb65a41c710bdde5"),
        0x505AB0: (0x505B03, "1f6cc3cef9f48564e68b00048b464653f1187983eda9de2ffd7b2f38dff59b31"),
        0x4F51E0: (0x4F5202, "4de35f155029793068580baaeb3cf4bcd157f952d3b537b5931f77ed3da2f601"),
        0x540C60: (0x540C74, "4d0fc410e63150863f20be276a07066074886f21004b44d9cf5013611c204e95"),
    }
    for address, (end, expected) in bodies.items():
        if hashlib.sha256(pe.at(address, end - address)).hexdigest() != expected:
            raise ValueError("Unexpected default control-refresh function body")
    return {"instructionChecks": len(checks),
            "virtualTargets": {hex(k): hex(v) for k, v in virtuals.items()},
            "functionSHA256": {hex(k): v[1] for k, v in bodies.items()},
            "targetPredicate": {"productID": 0x01CE, "member": "0x2114", "compare": 1,
                                "controlsBlock": "0x4fb1cf"},
            "modeDisplay": {"mode": 21, "virtualOffset": "0x38c", "memberVector": "0x2124",
                            "elementMethod": "0x4f51e0", "elementMember": "0xd24",
                            "import": name, "modeArgument": "1 for 21, otherwise 0"},
            "hardwareWriteAuthorized": False,
            "conclusion": "The resolved +0x38c path updates each host key-control member and invokes CControlUI::Invalidate; the resolved +0x2ec predicate only returns a host member. Neither resolved method sends a keyboard report.",
            "pendingMacroStorageSemantics": True,
            "limits": "The containing refresh method has additional UI callbacks not all classified here. No claim about the full program, implicit firmware effects, macro erase or persistence; no execution or device access."}


def inspect_default_lighting_control_updates(pe, skin=None):
    """Resolve refresh argument sites without conflating UI and device vtables."""
    checks = {
        0x4FAA9A: "8b8ab81e0000", 0x4FAAA0: "e85b81f4ff",
        0x442C3C: "e8af0e0000", 0x442C5C: "e8ff000000",
        0x443B05: "68d01f7300", 0x443B41: "6a00",
        0x443B5C: "8b82c0010000", 0x443B62: "ffd0",
        0x442DA0: "6870217300", 0x442E6F: "6a00", 0x442E71: "6a01",
        0x442E81: "8b90c0010000", 0x442E87: "ffd2",
        0x442F12: "6a00", 0x442F14: "6a00",
        0x442F24: "8b82c0010000", 0x442F2A: "ffd0",
        0x442F48: "e8830e0000",
        0x44265B: "ff1560b86e00", 0x442733: "68a8177300", 0x442738: "68c8177300",
        0x44274B: "8b825c010000", 0x442751: "ffd0",
        0x4422A3: "c7001ca07700", 0x4422AC: "c781f0060000f49f7700",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError(f"Unexpected default lighting-control update at {address:#x}")
    if pe.class_name(0x77A01C) != ".?AVCLightControlUI@@":
        raise ValueError("Unexpected lighting-control RTTI")
    constructor_name = "??0COptionUI@DuiLib@@QAE@XZ"
    if pe.at(pe.base + pe.pointer(0x6EB860) + 2, len(constructor_name) + 1) != (constructor_name + "\0").encode("ascii"):
        raise ValueError("Unexpected mode-row constructor import")
    bodies = {
        0x4424D0: (0x442B03, "526a3da37c1e7f4161c50e3e1362b86a2777a46fc5a2f46ec0b233053edb5cff"),
        0x442C00: (0x442D4F, "55c4d8f4887fcaae599a0a51b36920bf52080b7cb671701356672d04504fbe39"),
        0x442D60: (0x442F68, "dbeee1b1a54dd4cb2285c4cd27e7d56e7386034be9f3dd9e237a7e5f91a4e6af"),
        0x443AF0: (0x443B6A, "9517326bc9331c535900e9d44608d8de2634d93927c5f7250c9475f45cbc60da"),
    }
    for address, (end, digest) in bodies.items():
        if hashlib.sha256(pe.at(address, end - address)).hexdigest() != digest:
            raise ValueError("Unexpected default lighting-control function body")
    result = {"instructionChecks": len(checks), "functionSHA256": {hex(k): v[1] for k, v in bodies.items()},
              "receiver": "device+0x1eb8 UI control, not the device itself",
              "modeRowCreation": {"method": "0x4424d0", "class": "COptionUI",
                                  "constructorImport": constructor_name, "style": "lighttab_style",
                                  "styleAttributeDispatch": "child virtual +0x15c",
                                  "controlClass": "CLightControlUI"},
              "checkboxRefresh": {"method": "0x443af0", "name": "deng_7color_check",
                                  "virtualOffset": "0x1c0", "sendNotifyArgument": False},
              "modeRows": {"method": "0x442d60", "name": "light_mode_list_layout",
                           "selectedArguments": [True, False], "otherArguments": [False, False],
                           "followingMethod": "0x443dd0"},
              "limits": "The +0x1c0 calls here use child controls, not the device vtable. Direct notification arguments are false; group peers, later mode visibility helpers and callbacks are not fully classified. No whole-chain no-write, macro-storage or firmware persistence assertion."}
    if skin is not None:
        raw = (Path(skin) / "XML/CustomControlXML/LightControl.xml").read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if digest != "fade3d80be473a8b0b21d552d902527e7e1618db3c9db80552bbf75d6d66af77":
            raise ValueError("Unexpected lighting-control resource hash")
        text = raw.decode("utf-8-sig")
        classes = {"deng_7color_check": "CheckBox", "light_mode_list_layout": "TileLayout",
                   "light_mode_text": "Label", "speed_edit": "Edit"}
        for name, expected in classes.items():
            tags = [tag for tag in re.findall(r"<[^<>]+>", text) if f'name="{name}"' in tag]
            if len(tags) != 1 or not tags[0].startswith("<" + expected + " "):
                raise ValueError("Unexpected lighting-control named element")
        styles = (Path(skin) / "main.xml").read_bytes()
        styles_digest = hashlib.sha256(styles).hexdigest()
        if styles_digest != "53d2b64104a344bcde9ee1ada4cadf96ffb5b5a3cb3b41a74da21c22c48308ce":
            raise ValueError("Unexpected main style resource hash")
        tags = [tag for tag in re.findall(r"<Style\s[^<>]+>", styles.decode("utf-8-sig")) if 'name="lighttab_style"' in tag]
        if len(tags) != 1:
            raise ValueError("Unexpected mode-row style declaration")
        value = re.search(r'value="([^"]*)"', tags[0])
        if value is None:
            raise ValueError("Missing mode-row style value")
        attributes = re.findall(r'([A-Za-z0-9_]+)="[^"]*"', html.unescape(value.group(1)))
        if "group" in attributes:
            raise ValueError("Mode-row style unexpectedly assigns an option group")
        result["modeRowCreation"]["styleResource"] = {"sha256": styles_digest,
                            "attributes": attributes, "assignsGroup": False,
                            "limits": "The named style does not set group; later attributes and live state are not classified."}
        result["resource"] = {"sha256": digest, "namedClasses": classes,
                              "method": "Exact-hash resource and bounded opening-tag matching; duplicate style attributes in the official file prevent strict XML parsing. Resource is not rewritten.",
                              "limits": "Declared classes only, not live control creation or group membership."}
    return result

def inspect_default_mode_visibility(pe):
    """Bind the target keyboard to the UI-layout dispatcher, never execute it."""
    checks = {
        0x4F609A: "c70004f67700", 0x4F6168: "c782f820000001000000",
        0x4F70A7: "8b91f8200000", 0x4F70AD: "52",
        0x4F70B4: "8b88b81e0000", 0x4F70BA: "e8f1b3f4ff",
        0x4424BD: "8988b4080000", 0x442F3B: "8b82b4080000",
        0x442F41: "50", 0x442F48: "e8830e0000",
        0x443DDF: "837dfc01", 0x443DE3: "741c",
        0x443DFA: "e801150000", 0x443E08: "e843000000",
        0x443E16: "e845200000",
        0x443F6B: "8b8218010000", 0x443F71: "ffd0",
        0x443F99: "8b8224010000", 0x443F9F: "ffd0",
        0x443DB6: "8b8218010000", 0x443DBC: "ffd0",
        0x443AC3: "ff15c4b06e00", 0x443AD9: "ff15c4b06e00",
        0x443FB9: "837db018", 0x443FBD: "0f8719120000",
        0x443FC6: "ff249598524400",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError(f"Unexpected default mode visibility instruction at {address:#x}")
    if pe.class_name(0x77F604) != ".?AVCEevisionKeyboardDevice@@":
        raise ValueError("Unexpected target keyboard layout constructor class")
    bodies = {
        0x443A70: (0x443AE5, "9176dcb3b7a8b50eb720bbb77f5f1472e11fd7a0a787d68350d431768f3fba07"),
        0x443D40: (0x443DC4, "92001a4aa9b9b93fd16131c7d8fba767ea88c5679bce0eda0366b2b1b777f9cd"),
        0x443DD0: (0x443E21, "f2bad7d11a4182ff842b38a2b78463b74cfcead82a5fc632221b22e89855cbae"),
        0x443E50: (0x445297, "86966b773c9e0f66569e6d5bea393d81bed0f8eeb33602e5e1fd70157b6d73b1"),
        0x445300: (0x445E35, "a18b32e5e779883d99c082e6c8e8db439181cbeb734dabaa2b3b68636d328455"),
        0x445E60: (0x4463F2, "a8bdab1cee0aa61a59630f9d32785806993ab7dd3e23d144fab00bea02f4b6b2"),
    }
    for address, (end, digest) in bodies.items():
        if hashlib.sha256(pe.at(address, end-address)).hexdigest() != digest:
            raise ValueError("Unexpected mode visibility function body")
    imports = {
        0x6EB3A4: "?FindSubControlByName@CPaintManagerUI@DuiLib@@QBEPAVCControlUI@2@PAV32@PB_W@Z",
        0x6EB0C4: "?SetBkImage@CControlUI@DuiLib@@QAEXPB_W@Z",
    }
    for slot, name in imports.items():
        expected=(name+"\0").encode("ascii")
        if pe.at(pe.base+pe.pointer(slot)+2,len(expected))!=expected:
            raise ValueError("Unexpected mode visibility UI import")
    table = pe.at(0x445298,25*4)
    table_digest = hashlib.sha256(table).hexdigest()
    if table_digest != "e2edccb02b7dbb3e562db26a9f15c6dcca2b56a0ce63905f87fcb2c8fa399d81":
        raise ValueError("Unexpected target mode visibility branch table")
    branches = struct.unpack("<25I",table)
    if any(not 0x443FCD <= address < 0x445297 for address in branches):
        raise ValueError("Mode visibility branch exceeds target helper")
    return {"instructionChecks": len(checks), "hardwareWriteAuthorized": False,
            "targetModeBranches": {"address": "0x445298", "sha256": table_digest,
                                   "targets": [hex(v) for v in branches], "fallback": "0x4451dc",
                                   "limits": "Helper argument positions 0..24 only; the argument's origin and per-mode capability flags require separate tracing. Not a lighting hardware-code table."},
            "functionSHA256": {hex(k): v[1] for k,v in bodies.items()},
            "targetLayout": {"constructorTable": "0x77f604", "deviceMember": "0x20f8", "initialValue": 1,
                             "copyCall": "0x4f70ba", "controlMember": "0x8b4",
                             "dispatcher": "0x443dd0", "targetHelper": "0x443e50",
                             "otherLayouts": {"2": "0x445300", "3": "0x445e60"}},
            "namedUIOperations": {"visibleVirtualOffset": "0x118", "enabledVirtualOffset": "0x124",
                                  "backgroundImageHelper": "0x443a70", "sameModeVisibilityHelper": "0x443d40",
                                  "imports": {hex(k):v for k,v in imports.items()}},
            "limits": "The target constructor initializes layout 1 and the named initialization copies it to the light control. This narrows the next capability audit to 0x443e50; later member changes, live control types, all branch effects and callbacks remain separate work. Function hashes exclude adjacent jump-table data. No firmware macro retention, complete no-write or persistence claim."}


def inspect_default_mode_options(pe, defaults_dir=None):
    """Fixed instruction sites for model47 layout-1 editor capabilities."""
    checks = {
        0x442c51: "0fb65508",
        0x442c5c: "e8ff000000",
        0x442f31: "8b4d08",
        0x443f8f: "6a01",
        0x443f99: "8b8224010000",
        0x443f9f: "ffd0",
        0x443fdf: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444037: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x44405b: "6a018b4de48b118b4de48b8218010000ffd0",
        0x444084: "6a008b4df48b118b4df48b8224010000ffd0",
        0x4440df: "6a008b4dec8b118b4dec8b8224010000ffd0",
        0x4440f1: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x444115: "6a018b4de48b118b4de48b8218010000ffd0",
        0x444148: "6a018b4df48b118b4df48b8224010000ffd0",
        0x4441a0: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x4441b2: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x4441d6: "6a018b4de48b118b4de48b8218010000ffd0",
        0x44457b: "6a018b4df48b118b4df48b8224010000ffd0",
        0x4445d6: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x4445fa: "6a018b4de48b118b4de48b8218010000ffd0",
        0x4446da: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444732: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444756: "6a018b4de48b118b4de48b8218010000ffd0",
        0x4448cc: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444924: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444936: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x44495a: "6a008b4de48b118b4de48b8218010000ffd0",
        0x444b0d: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444b65: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444b89: "6a018b4de48b118b4de48b8218010000ffd0",
        0x444bb2: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444c0a: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444c1c: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x444c40: "6a018b4de48b118b4de48b8218010000ffd0",
        0x444d20: "6a018b4df48b118b4df48b8224010000ffd0",
        0x444d78: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444d8a: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x444dae: "6a018b4de48b118b4de48b8218010000ffd0",
        0x444e1d: "6a008b4df48b118b4df48b8224010000ffd0",
        0x444e2f: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x444e41: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x444e65: "6a008b4de48b118b4de48b8218010000ffd0",
        0x444ea2: "6a008b4df48b118b4df48b8224010000ffd0",
        0x444ee3: "6a008b4dec8b118b4dec8b8224010000ffd0",
        0x444ef5: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x444f5f: "6a008b4de48b118b4de48b8218010000ffd0",
        0x44509e: "6a008b4df48b118b4df48b8224010000ffd0",
        0x4450b0: "6a018b4dec8b118b4dec8b8224010000ffd0",
        0x4450c2: "6a008b4ddc8b118b4ddc8b8224010000ffd0",
        0x4450e6: "6a008b4de48b118b4de48b8218010000ffd0",
        0x47ae9c: "686c507400",
        0x47aeb0: "8845c0",
        0x4faa82: "81c65c210000",
        0x4faa92: "f3a5",
    }
    for address, encoded in checks.items():
        expected=bytes.fromhex(encoded)
        if pe.at(address,len(expected))!=expected:
            raise ValueError(f"Unexpected model47 mode option instruction at {address:#x}")
    if pe.at(0x74506C,11)!=b"SelectItem\0":
        raise ValueError("Unexpected lighting selector field")
    entries = [(0, 0, True, True, True, True), (1, 1, True, False, False, False), (2, 2, True, False, True, True), (8, 10, True, True, True, True), (10, 12, True, True, True, True), (13, 15, False, False, True, True), (16, 18, True, True, True, True), (17, 19, True, False, True, True), (19, 21, True, False, True, True), (20, 3, False, False, False, True), (21, 8, False, False, False, False), (23, 23, False, False, False, True)]
    rows=[dict(zip(["officialIndex","hardwareCode","speed","direction","rainbow","color"],entry)) for entry in entries]
    result={"instructionChecks":len(checks),"hardwareWriteAuthorized":False,"modes":rows,
            "selectorOrigin":"LightInfo.SelectItem stored at getter structure byte 0; 4FAA50 copies device+215C into 442C00, which forwards that byte through 442D60 to the layout helper.",
            "directionDefault":"443F8F/443F9F enables the direction layout before the mode switch; listed cases explicitly disable it.",
            "colorMeaning":"colorpallet_layout enabled state; not an assertion that every mode uses a single RGB color or supports per-key animation.",
            "limits":"Fixed official UI option rules for the visible model47 modes, paired with its retained mapping. No firmware visual behavior, persistence, transport expansion or complete notification-chain assertion."}
    if defaults_dir is not None:
        path=Path(defaults_dir)/"default_light.json";raw=path.read_bytes()
        if len(raw)>16*1024*1024:raise ValueError("Default lighting resource exceeds analysis bound")
        modes=json.loads(raw.decode("utf-8-sig"))["DefaultLightName"][47]
        if [i for i,v in enumerate(modes) if v["visible"]]!=[v["officialIndex"] for v in rows] or any(modes[v["officialIndex"]]["value"]!=v["hardwareCode"] for v in rows):
            raise ValueError("Model47 visible mode mapping differs")
        result["modeResourceSHA256"]=hashlib.sha256(raw).hexdigest()
    return result


def inspect_default_key_action_branch(pe):
    """Distinguish factory-record copying from action binding serialization."""
    virtuals = {0x2A0: 0x4FEFB0, 0x2A4: 0x4FE970, 0x2EC: 0x540C60}
    for offset, target in virtuals.items():
        if pe.pointer(0x77F604 + offset) != target:
            raise ValueError("Unexpected default key/action dispatch")
    checks = {
        0x47E9E0: "b914000000", 0x47EA6C: "83c214",
        0x47D544: "c745dc00000000",  # record starts with action link = 0
        0x47D54D: "8945e0", 0x47D550: "8945e4",
        0x47D553: "8945e8", 0x47D556: "8945ec",
        0x47D601: "68d05f7400", 0x47D62D: "e86ea90c00",
        0x47D637: "7536", 0x47D66A: "8945dc",
        0x47D66F: "c745dc00000000",  # missing/null ActionLink
        0x47D676: "68f85f7400", 0x47D6AC: "7536",
        0x47D6E4: "c745e0ffffffff",  # missing/null action index = -1
        0x47D6F2: "e899120000", 0x47D71B: "e810170000",
        0x4FF04C: "0fb688f91d0000", 0x4FF053: "6bd103",
        0x4FF065: "8d840a30270000", 0x4FF07D: "e89e7c1800",
        0x4FF0DD: "81bd38fdffffff000000", 0x4FF0E7: "7502",
        0x4FF0FA: "833800", 0x4FF0FD: "0f8412040000",
        0x4FF136: "8b4804", 0x4FF14D: "e84ef1f7ff",
        0x4FF156: "685ce07600", 0x4FF17F: "83bd30fdffff04",
        0x4FF192: "ff248df4f64f00",
        0x4FF486: "8a4810", 0x4FF49E: "8a4011", 0x4FF4B6: "8a5012",
        0x4FF66B: "c1e209", 0x4FF693: "e878affdff",
        0x4FF6B5: "e826aafdff",
        0x4FB008: "81f9ce010000", 0x4FB00E: "7519",
        0x4FB018: "8b90ec020000", 0x4FB01E: "ffd2",
        0x540C6A: "8b8014210000", 0x540C73: "c3",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected default key/action instruction")
    strings = {0x745F78: "KeyList", 0x745FA0: "Assignment",
               0x745FB4: "DefaultAssignment", 0x745FD0: "ActionLink",
               0x745FF8: "ActionLinkIndex", 0x76E05C: "ActionType"}
    for address, name in strings.items():
        raw = (name + "\0").encode("ascii")
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected default key/action JSON field")
    targets = [0x4FF477, 0x4FF199, 0x4FF1FA, 0x4FF341, 0x4FF413]
    if [pe.pointer(0x4FF6F4 + i * 4) for i in range(5)] != targets:
        raise ValueError("Unexpected action type dispatch table")
    bodies = {
        0x47D490: (0x47D756, "777129680f69b019811a53cc854c090cd4000e680f9ae7492fb915221efe069d"),
        0x4FEFB0: (0x4FF6F4, "712d34313c3ad2464b3c10a557f9a09bab16a197727bd78f8f00482ae4e6240f"),
        0x540C60: (0x540C74, "4d0fc410e63150863f20be276a07066074886f21004b44d9cf5013611c204e95"),
    }
    for start, (end, digest) in bodies.items():
        if hashlib.sha256(pe.at(start, end - start)).hexdigest() != digest:
            raise ValueError("Unexpected default key/action function body")
    return {
        "instructionChecks": len(checks), "fieldNameChecks": len(strings),
        "virtualTargets": {hex(k): hex(v) for k, v in virtuals.items()},
        "recordLayout": {"bytes": 20, "actionLinkOffset": 0, "actionIndexOffset": 4,
                         "assignmentBytes": [10, 11, 12], "defaultAssignmentBytes": [16, 17, 18]},
        "missingActionFields": {"ActionLink": 0, "ActionLinkIndex": -1},
        "factoryCopy": {"member": "0x2730", "length": "3 * byte(device+0x1df9)",
                        "copyCall": "0x4ff07d", "actionlessBranch": "0x4ff0fd -> 0x4ff515",
                        "conclusion": "Zero ActionLink skips action lookup/encoding and retains the copied factory record; JSON Assignment is not used to override it in this branch."},
        "actionDispatch": {"table": "0x4ff6f4", "targets": [hex(a) for a in targets],
                           "limits": "Only reached for a nonzero ActionLink and a mapped physical slot; macro binding encoding does not itself prove macro-bank writes."},
        "targetFinalPredicate": {"call": "0x4fb01e", "virtualOffset": "0x2ec",
                                 "target": "0x540c60", "readsMember": "0x2114",
                                 "conclusion": "The resolved method only returns a host member; no nested call or device exchange."},
        "functionBodies": {hex(a): {"endExclusive": hex(b), "sha256": h} for a, (b, h) in bodies.items()},
        "pendingMacroStorageSemantics": True, "hardwareWriteAuthorized": False,
        "limits": "Named getter, key sender and one final predicate only. Begin/end exchanges, other callbacks and implicit firmware effects can still affect storage. No whole-program macro erase/retention or persistence claim.",
    }


def inspect_default_configuration_path(pe, defaults_dir=None):
    """Audit the confirmed default-button branch, without authorizing reset."""
    checks = {
        0x48E87C: "680cbb7500", 0x48E897: "e814be0100",
        0x4AA6C7: "688cfb7500", 0x4AA6D5: "e8d6c8f9ff",
        0x4AA6EB: "e830dffeff", 0x4AA701: "8b8290020000",
        0x4AA720: "8b90a4020000", 0x4AA750: "8b82bc020000",
        0x4F933C: "e8afb5f3ff", 0x4F9351: "e8ea910400",
        0x4F9366: "e89533f8ff", 0x4F9398: "e873a60200",
        0x4F93D4: "8b82c4020000", 0x4F93DA: "ffd0",
        0x4FE98A: "e8a104f8ff", 0x4FE99E: "8b90a0020000",
        0x5425AB: "e810010000", 0x5425ED: "68386a7700",
        0x5425F9: "ff15c0b16e00", 0x542616: "ff15d0b66e00",
        0x434903: "6880fb7200", 0x434949: "8b9140080000",
        0x42B4BA: "8b80240b0000",
        0x4FF065: "8d840a30270000", 0x4FF07D: "e89e7c1800",
        0x4FF5A4: "81f9d7010000", 0x4FF5EF: "81fada010000",
        0x4FF604: "81f9e6010000", 0x4FF619: "3def010000",
        0x4FF62D: "81fa4c010000", 0x4FF633: "7533",
        0x4FF66B: "c1e209", 0x4FF67C: "6bd103",
        0x4FF693: "e878affdff", 0x4FF6B5: "e826aafdff",
        0x47C747: "e8448d0000", 0x47C753: "8b82a0040000",
        0x47C788: "e8b39d0c00",
        0x500819: "e8c2a5f7ff", 0x500831: "83f819",
        0x500836: "c685f1feffff00", 0x50084B: "81c1e4250000",
        0x500851: "e89a1cf2ff", 0x500856: "8a10",
        0x500858: "8895f1feffff", 0x422504: "8d0488",
        0x4FA7B8: "68a8dd7600", 0x4FA7D1: "68b0dd7600",
        0x4FA7F8: "e873c20400", 0x4FA810: "81c1e4250000",
        0x4FA816: "e83583f8ff",
        0x408E02: "c7054c41820001000000",
        0x54366D: "898840220000",
        0x53FAC6: "c7824022000001000000", 0x53FC3C: "c7824022000000000000",
        0x49992C: "698500fcffff1c010000", 0x499936: "8b88280d8200",
        0x499943: "e8189d0a00", 0x49B8BD: "e89e7d0a00",
        0x49D333: "e828630a00", 0x49E5C2: "e899500a00",
        0x501210: "83b84022000000",
        0x4F93AD: "8b9030020000", 0x4F93B3: "ffd2",
        0x4F93B8: "e8230d0000", 0x4F93C6: "e8e520f3ff",
        0x5013E9: "81fac7000000", 0x5013EF: "0f85f0030000",
        0x5018F7: "8b5508", 0x5018FA: "c1e209",
        0x50190A: "e8c1a7fbff", 0x50190F: "6bc003",
        0x501926: "e8b5b4fdff",
        0x408DDA: "c7053c4182007e000000",
        0x4997CE: "699500fcffff1c010000", 0x4997D8: "8b82180d8200",
        0x4997E5: "e8467b0a00", 0x49B77B: "e8b05b0a00",
        0x49D20F: "e81c410a00", 0x49E4AE: "e87d2e0a00",
        0x541359: "898208210000", 0x54137A: "8b8808210000",
        0x541384: "81c150210000", 0x54138A: "e8b137fbff",
        0x541410: "81c150210000", 0x54141E: "8910",
        0x4F4B72: "e899d9f2ff", 0x4F4B77: "394508",
        0x4F4B8B: "e8e088fcff", 0x4F4BB7: "e834dbf2ff",
        0x50320F: "0fb691f91d0000", 0x503216: "3955ec",
        0x503219: "7d32", 0x503240: "e8ab86fbff",
        0x503245: "c700ff000000", 0x50325F: "837df87e",
        0x4BC0DA: "e811fdffff", 0x4BC0DF: "8b00",
        0x4BBDFA: "e831000000", 0x4BBDFF: "83c004",
        0x4FF041: "e8dab2fdff", 0x4DA3B7: "c644059803",
        0x4DA37A: "c78540ffffff22000000",
        0x4DA655: "c64405bc04", 0x4DA671: "c6440dbc89",
        0x4DA680: "c64405bc09", 0x4DA6D9: "0fb708",
        0x4DA6DC: "398d74ffffff", 0x4DA798: "e883c51a00",
        0x4DA7C5: "83bd70ffffff40", 0x4DA83A: "e841ebffff",
        0x4DCF54: "e8c79d1a00",
        0x4D925B: "b900020000", 0x4D9263: "66890a",
        0x4D929B: "c6829006000038",
        0x4FC1CC: "e84fe1fdff", 0x4FC1D7: "0fb691f91d0000",
        0x4FC1DE: "6bc203", 0x4FC1E8: "81c1380a0000",
        0x4FC1EE: "e81d24feff", 0x4FC1F3: "85c0", 0x4FC1F5: "7505",
        0x4DE617: "0fb74508", 0x4DE61B: "3d00020000",
        0x4DE620: "7e04", 0x4DE62D: "668911",
        0x4F8300: "e83b3e0000",



    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected default configuration instruction")
    methods = {0x230: 0x4F9C10, 0x2A0: 0x4FEFB0, 0x290: 0x4F9320, 0x2A4: 0x4FE970, 0x2BC: 0x500790, 0x2C4: 0x501190}
    for offset, target in methods.items():
        if pe.pointer(0x77F604 + offset) != target:
            raise ValueError("Unexpected model default configuration virtual target")
    for address, name in {0x75BB0C: "default_btn", 0x75FB8C: "message_text_22",
                          0x776A38: "DefaultData%d.json", 0x72FB80: "device_nprofile_combo"}.items():
        expected = (name + "\0").encode("utf-16-le")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected default configuration string")
    imports = {0x6EB1C0: "?Format@CDuiString@DuiLib@@QAAHPB_WZZ",
               0x6EB6D0: "??HCDuiString@DuiLib@@QBE?AV01@ABV01@@Z",
               0x6EB3A4: "?FindSubControlByName@CPaintManagerUI@DuiLib@@QBEPAVCControlUI@2@PAV32@PB_W@Z"}
    for address, name in imports.items():
        expected = (name + "\0").encode("ascii")
        if pe.at(pe.base + pe.pointer(address) + 2, len(expected)) != expected:
            raise ValueError("Unexpected default configuration import")
    result = {"instructionChecks": len(checks), "button": "default_btn", "confirmation": "message_text_22",
            "handler": "0x4aa6b0", "modelVirtualCalls": {hex(k): hex(v) for k, v in methods.items()},
            "defaultFilePattern": "DefaultData%d.json", "defaultFilePathCompositionMethod": "0x542540",
            "fileIndexControl": "device_nprofile_combo", "profileIndexGetter": "0x42b4b0",
            "followingBindingDispatchOffset": "0x2a0", "hardwareWriteAuthorized": False,
            "limits": "Confirmed button and model virtual targets only; default file index, complete model extraction, nested binding dispatch and physical effects remain unverified. This is not a standalone factory-reset report or product reset implementation."}


    result["bindingWrite"] = {"method": "0x4fefb0", "initialTableMember": "0x2730",
                              "payloadBytes": "deviceInfo byte +0x1df9 multiplied by 3",
                              "model01CEOffset": "profile index shifted left 9 (multiplied by 512)",
                              "sendMethod": "0x4da610", "finalMethod": "0x4da0e0",
                              "limits": "Entry and final write branch only; complete action conversion and sender internals are not reclassified here."}
    result["defaultColorProcessing"] = {"registeredModelIndex": 47, "rowStride": "0x11c",
                                         "flagColumn": "0x820d28", "modelFlagAddress": "0x82414c",
                                         "registeredValue": 1, "constructorStores": [1, 0], "setter": "0x543660", "objectMember": "0x2240",
                                         "callerSites": ["0x499943", "0x49b8bd", "0x49d333", "0x49e5c2"],
                                         "colorGuard": "0x501210 checks object member +0x2240",
                                         "limits": "Static registration, column transfer and color guard; actual selected object index, loaded color source and full restore ordering remain unverified. Not proof of a live color write or prior blackout root cause."}
    # Whole bounded function fingerprint covers loop, mapping guards and both
    # palette branches. The fixed EXE is read, never executed.
    palette_hash = hashlib.sha256(pe.at(0x4FA0E0, 0x154)).hexdigest()
    if palette_hash != "578c980f529151c8194e0b287521b0fcd45265b0f6745b1f5e4f857a8f66afc6":
        raise ValueError("Unexpected default color palette function")
    result["defaultColorPalette"] = {"method": "0x4fa0e0", "functionSHA256": palette_hash,
        "logicalRedIndices": [44, 64, 65, 66, 96, 113, 114, 115],
        "redRGBA": [255, 0, 0, 255], "otherMappedRGBA": [255, 255, 255, 255],
        "vector": "object+0x2150; existing vector length from 0x422510",
        "registeredColorCount": {"modelIndex": 47, "column": "0x820d18", "rowStride": "0x11c", "cell": "0x82413c", "value": 126, "initializationStore": "0x408dda"},
        "colorCountSetter": {"method": "0x541330", "countMember": "0x2108", "vectorResize": "0x4f4b40", "resizeCall": "0x54138a", "initialRGBA": [0, 0, 0, 0], "callerSites": ["0x4997e5", "0x49b77b", "0x49d20f", "0x49e4ae"]},
        "mapping": "object+0x2138 via 0x4bb8f0",
        "guards": "signed mapping < 255 and mapping*3 <= 512; no lower bound added by this official method",
        "callOrder": ["0x4f93b3 virtual+0x230 refresh", "0x4f93b8 palette initialization", "0x4f93da virtual+0x2c4 color processing"],
        "colorConversion": "(component * 255) >> 8 => 254 for a 255 component; palette overwrites alpha, unlike ordinary brightness loading",
        "mappingLength": {"initializationMethod": "0x5031f0", "initialKeys": "all integers in [0, deviceInfo[5]) are inserted into +0x2138 with FF values", "logicalLoopBound": 126, "sizeGetter": "0x4bc0d0 -> 0x4bbdf0 -> count member", "offlineRequiredKeyCount": 126, "offlineColorBytes": 378, "limits": "Mapping initialization and bounded matching path only; this does not prove that no other runtime path inserts additional keys"},
        "model01CE": {"skipsPID00C7Overrides": True, "bankOffset": "profile index * 512", "sendLength": "mapping container size * 3", "sender": "0x4dcde0"},
        "hardwareWriteAuthorized": False,
        "limits": "Static model47 color count, setter and resize are confirmed. The current offline color stage uses 126 logical entries and requires deviceInfo[5]==126; it is included in the candidate but remains separate from the parameter-only plan and cannot authorize writing. The traced mapping initializer inserts 126 keys under the product key-count guard. Other runtime insertions, live object selection, complete reset transaction and physical effects still require verification. Not blackout root cause evidence."}
    for address, length, expected_hash in [(0x4DA610, 0x2BB, "9017029bbd555ac5ac62e2c8e0662290020c8a2ce80daa0bb9d184a4971c1b4d"), (0x4DCDE0, 0x2B1, "357ca182786e495806b961a3ab3e16d9b30b5bb4588325fbaa4991c2ce608258")]:
        if hashlib.sha256(pe.at(address, length)).hexdigest() != expected_hash:
            raise ValueError("Unexpected default bank helper function")
    result["defaultKeyReports"] = {"helper": "0x4da610", "functionSHA256": "9017029bbd555ac5ac62e2c8e0662290020c8a2ce80daa0bb9d184a4971c1b4d",
        "preflight": {"caller": "0x4ff041", "helper": "0x4da320", "command": "03; 83 only for selector 1", "bytes": 34, "purpose": "deviceInfo query, not the color begin command"},
        "command": "09; 89 only for selector 1", "reportID": 4,
        "lengthSource": "first word of communication object; not helper length argument at EBP+0x0c",
        "lengthInitialization": {"constructorValue": 512, "initializer": "0x4fc140", "caller": "0x4f8300", "readDeviceInfo": "0x4fc1cc -> 0x4da320", "value": "deviceInfo[5] * 3", "setter": "0x4de610", "setterCall": "0x4fc1ee", "setterLimit": 512, "setterStore": "0x4de62d", "fixedProductValue": 378, "capacityConstructorValue": 56},
        "capacitySource": "communication+0x690", "offsetSource": "third helper argument + chunk start",
        "payloadStart": 8, "flag": 0, "checksumRange": [3, 63],
        "shortFinalPacket": "Only valid payload bytes overwritten; previous payload tail retained in checksum-covered report buffer",
        "colorHelperSamePaddingRule": {"method": "0x4dcde0", "functionSHA256": "357ca182786e495806b961a3ab3e16d9b30b5bb4588325fbaa4991c2ce608258", "lengthSource": "second helper argument at EBP+0x0c"},
        "offlineScope": {"bank": 0, "capacity": 56, "keyBytes": 378, "hardwareReady": False, "pendingSenderLengthState": False},
        "limits": "Official key sender uses object-state length while color sender uses supplied length. The traced initializer overwrites constructor length 512 with deviceInfo[5]*3; current product scope requires key count 126. Offline reports do not broaden ordinary key authorization, prove firmware ignores padding or explain prior blackout."}
    result["defaultLightingConversion"] = {"getter": "0x47ade0", "modeTableMember": "0x25e4",
                                           "indexLimit": 25, "outOfRangeFallbackIndex": 0,
                                           "entryStride": 4, "output": "low byte of selected table entry",
                                           "source": "DefaultLightName model row value entries",
                                           "limits": "Index conversion is distinct from mode visibility and actual visual behavior; no device writing or physical acceptance."}
    if defaults_dir is not None:
        light_path = Path(defaults_dir) / "default_light.json"
        light_data = light_path.read_bytes()
        if len(light_data) > 16 * 1024 * 1024:
            raise ValueError("Default lighting resource exceeds analysis bound")
        light_root = json.loads(light_data.decode("utf-8-sig"))
        light_rows = light_root.get("DefaultLightName") if isinstance(light_root, dict) else None
        if not isinstance(light_rows, list) or len(light_rows) <= 47:
            raise ValueError("Default lighting resource lacks model47")
        modes = light_rows[47]
        if not isinstance(modes, list) or len(modes) != 25 or any(
                not isinstance(m, dict) or type(m.get("value")) is not int or not 0 <= m["value"] <= 255
                or type(m.get("visible")) is not bool for m in modes):
            raise ValueError("Unexpected model47 default lighting mode rows")
        result["defaultLightingConversion"]["resourceSHA256"] = hashlib.sha256(light_data).hexdigest()
        result["defaultLightingConversion"]["modeCodes"] = [m["value"] for m in modes]
        rows = []
        for index in range(5):
            path = Path(defaults_dir) / f"DefaultData{index}.json"
            data = path.read_bytes()
            if len(data) > 16 * 1024 * 1024:
                raise ValueError("Default file exceeds analysis bound")
            root = json.loads(data.decode("utf-8-sig"))
            devices = root.get("Device") if isinstance(root, dict) else None
            if not isinstance(devices, list):
                raise ValueError("Default file lacks Device array")
            matches = [(i, row) for i, row in enumerate(devices) if isinstance(row, dict) and row.get("//") == "47"]
            if len(matches) != 1:
                raise ValueError("Expected one model47 default row")
            position, row = matches[0]
            keys = row.get("KeyList")
            if not isinstance(keys, list) or len(keys) != 126:
                raise ValueError("Unexpected default key count")
            if any(not isinstance(key, dict) or set(key) != {"Assignment", "DefaultAssignment"}
                   or any(type(key[field]) is not int or not 0 <= key[field] <= 0xFFFFFF
                          for field in ("Assignment", "DefaultAssignment")) for key in keys):
                raise ValueError("Unexpected model47 default key/action fields")
            selected = row.get("LightInfo", {}).get("SelectItem")
            if type(selected) is not int or not 0 <= selected < len(modes):
                raise ValueError("Invalid default lighting index")
            canonical = json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
            rows.append({"file": path.name, "fileSHA256": hashlib.sha256(data).hexdigest(),
                         "modelArrayIndex": position, "modelRowSHA256": hashlib.sha256(canonical).hexdigest(),
                         "keyCount": len(keys), "keyFields": ["Assignment", "DefaultAssignment"],
                         "actionlessKeyCount": len(keys),
                         "templateIdentity": row.get("DeviceBasicInfo"),
                         "lightingModeIndex": selected, "mappedModeCode": modes[selected]["value"],
                         "mappedModeVisible": modes[selected]["visible"]})
        result["defaultFiles"] = {"rows": rows, "sameModelRowAcrossFiveFiles": len({r["modelRowSHA256"] for r in rows}) == 1,
                                  "limits": "Read-only template identity and content comparison, not physical USB identity, firmware defaults or permission to restore unsupported lighting modes."}
    return result



def inspect_external_property_binding(pe, dll_path=None):
    """Follow named dynamic bindings; optionally read the DLL's request tables."""
    checks = {
        0x472C12: "ff15a8bc6e00", 0x472C37: "6864f97300",
        0x472C43: "ff15a0bc6e00", 0x472C49: "a348cc7c00",
        0x472C65: "68a8f97300", 0x472C71: "ff15a0bc6e00",
        0x472C77: "a338cc7c00", 0x472EF6: "685cfa7300",
        0x472F19: "ff1538cc7c00", 0x4EC8B1: "68cc8e7600",
        0x4EC8DC: "ff1538cc7c00", 0x4F204D: "6818947600",
        0x4F2078: "ff1538cc7c00",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected external property binding instruction")
    for address, name in {0x6EBCA8: "LoadLibraryExW", 0x6EBCA0: "GetProcAddress"}.items():
        expected = (name + "\0").encode("ascii")
        if pe.at(pe.base + pe.pointer(address) + 2, len(expected)) != expected:
            raise ValueError("Unexpected external property binding import")
    for address, name in {0x73F964: "ConfLibInit", 0x73F9A8: "PropertyControl"}.items():
        expected = (name + "\0").encode("ascii")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected dynamic export name")
    requests = {0x73FA5C: "GetSupportFeature", 0x768ECC: "GetMaxVol", 0x769418: "VolumeControl"}
    for address, name in requests.items():
        expected = (name + "\0").encode("utf-16-le")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected external property request name")
    result = {"instructionChecks": len(checks), "binding": "LoadLibraryExW then GetProcAddress",
              "propertyFunctionPointer": "0x7ccc38", "initializationFunctionPointer": "0x7ccc48",
              "namedCalls": {"0x472f19": "GetSupportFeature", "0x4ec8dc": "GetMaxVol", "0x4f2078": "VolumeControl"},
              "hardwareWriteAuthorized": False,
              "limits": "Named calls only; no model47 binding, keyboard repeat setter, firmware command or absence of other settings paths is established. Generic device-specific requests may dispatch beyond this library."}
    if dll_path is None:
        return result
    data = Path(dll_path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != "b3997b03c2f842386af172cb96c2c63af4e5a69dfe07693646e5c23764a52127":
        raise ValueError("osConfLib hash differs from the analyzed version")
    dll = PE32(data)
    dll_checks = {
        0x10004C95: "e886d8ffff", 0x10004CA7: "3d00000100",
        0x10004CD2: "e839060000", 0x10004CE5: "8b0485b875ff0f",
        0x10004D0A: "ffd0", 0x10002523: "8b0c85a8710310",
        0x10002560: "83f86f", 0x10002570: "8b04b568730310",
        0x100025B0: "83fe5c", 0x10002563: "72be",
        0x100025B3: "72bb", 0x100025BA: "8d8600000100",
        0x1000FEC7: "687cf10210", 0x1000FEF8: "ff1500a00210",
        0x1000FF27: "68a8f10210", 0x1000FF31: "ff1520a00210",
        0x1000FF7B: "ff1508a00210", 0x1000FF4F: "a104920310",
        0x1000FF5E: "ffd0", 0x10010F02: "6874eb0210",
        0x10010F0A: "6864eb0210", 0x10010F0F: "ff1504a20210",
        0x10010F1F: "8b4a30", 0x10010F28: "ffd1",

    }
    for address, encoded in dll_checks.items():
        expected = bytes.fromhex(encoded)
        if dll.at(address, len(expected)) != expected:
            raise ValueError("Unexpected external property dispatch instruction")
    tables = []
    for address, count in ((0x100371A8, 111), (0x10037368, 92)):
        names = []
        for index in range(count):
            target = dll.pointer(address + index * 4)
            raw = bytearray()
            for offset in range(0, 512, 2):
                unit = dll.at(target + offset, 2)
                if unit == b"\0\0":
                    break
                raw.extend(unit)
            else:
                raise ValueError("External property name exceeds bound")
            name = raw.decode("utf-16-le")
            if not name or name in names:
                raise ValueError("Empty or duplicate external property name")
            names.append(name)
        tables.append({"address": hex(address), "count": count, "names": names})
    if not all(name in tables[1]["names"] for name in requests.values()):
        raise ValueError("Named main executable requests absent from library lookup")
    handlers = {"EXControl": 0x1000FE80, "DeviceSpecificControl": 0x10010E40}
    for name, target in handlers.items():
        index = tables[1]["names"].index(name)
        if dll.pointer(0x100375B8 + index * 4) != target:
            raise ValueError("Unexpected generic property handler table entry")
    imports = {0x1002A000: "RegCreateKeyExW", 0x1002A020: "RegSetValueExW",
               0x1002A008: "RegQueryValueExW", 0x1002A204: "CoCreateInstance"}
    for address, name in imports.items():
        expected = (name + "\0").encode("ascii")
        if dll.at(dll.base + dll.pointer(address) + 2, len(expected)) != expected:
            raise ValueError("Unexpected generic property handler import")
    for address, name in {0x1002F17C: "SOFTWARE\\C-Media\\Hook", 0x1002F1A8: "EnableEX"}.items():
        expected = (name + "\0").encode("utf-16-le")
        if dll.at(address, len(expected)) != expected:
            raise ValueError("Unexpected EXControl registry string")
    result["library"] = {"sha256": digest, "lookupMethod": "0x10002520",
                         "propertyMethod": "0x10004c70", "instructionChecks": len(dll_checks),
                         "requestTables": tables,
                         "genericHandlers": {"functionTable": "0x100375b8", "targets": {k: hex(v) for k, v in handlers.items()},
                                             "EXControl": {"registryKey": "SOFTWARE\\C-Media\\Hook", "value": "EnableEX", "followingCallbackPointer": "0x10039204"},
                                             "DeviceSpecificControl": {"creationAPI": "CoCreateInstance", "followingVirtualOffset": "0x30"},
                                             "limits": "Named registry and COM paths only; callback, virtual effects and model association remain unclassified. Not a keyboard HID setting command."},
                         "limits": "Fixed bounded name tables contain audio and generic device controls; names alone do not prove handler effects or keyboard support."}
    return result


def inspect_settings_ui_control_actions(path):
    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    expected_hash = "aff70e5182c4d3e5d592db39f7edf17721f86b37ef3f801ed7f7108c9f79c90b"
    if digest != expected_hash:
        raise ValueError("DuiLib hash differs from the analyzed version")
    pe = PE32(data)
    exports = {"?Selected@COptionUI@DuiLib@@UAEX_N0@Z": 0x110A9400,
               "?Selected@CCheckBoxUI@DuiLib@@UAEX_N0@Z": 0x110A9290,
               "??0CCheckBoxUI@DuiLib@@QAE@XZ": 0x110A8540,
               "??0COptionUI@DuiLib@@QAE@XZ": 0x110A8570,
               "?SetVisible@CControlUI@DuiLib@@UAEX_N@Z": 0x1105B620,
               "?SetEnabled@COptionUI@DuiLib@@UAEX_N@Z": 0x110A9820,
               "?SetEnabled@CSliderUI@DuiLib@@UAEX_N@Z": 0x110B6510,
               "?SetValue@CSliderUI@DuiLib@@QAEXH@Z": 0x110B6610,
               "?SendNotify@CPaintManagerUI@DuiLib@@QAEXPAVCControlUI@2@PB_WIJ_N@Z": 0x11068AD0}
    directory = pe.base + pe.u32(pe.u32(0x3C) + 24 + 96)
    count, names_count, functions, names, ordinals = struct.unpack("<5I", pe.at(directory + 20, 20))
    if not 1 <= names_count <= count <= 65536:
        raise ValueError("Invalid UI DLL export table")
    found = {}
    for index in range(names_count):
        name_address = pe.base + pe.pointer(pe.base + names + index * 4)
        name = pe.at(name_address, 256).split(b"\0", 1)[0].decode("ascii")
        if name not in exports:
            continue
        ordinal = struct.unpack("<H", pe.at(pe.base + ordinals + index * 2, 2))[0]
        if ordinal >= count or name in found:
            raise ValueError("Invalid or duplicate UI DLL export")
        found[name] = pe.base + pe.pointer(pe.base + functions + ordinal * 4)
    if found != exports or pe.class_name(0x11113C94) != ".?AVCOptionUI@DuiLib@@" or pe.pointer(0x11113C94 + 0x1C0) != 0x110A9400:
        raise ValueError("Unexpected option selection export or virtual table")
    if pe.class_name(0x111141BC) != ".?AVCSliderUI@DuiLib@@" or pe.pointer(0x111141BC + 0x190) != 0x110AA520:
        raise ValueError("Unexpected slider value callback virtual table")
    if pe.class_name(0x11113E5C) != ".?AVCCheckBoxUI@DuiLib@@" or pe.pointer(0x11113E5C + 0x1C0) != 0x110A9290:
        raise ValueError("Unexpected checkbox selection virtual target")
    for table, enabled in [(0x11113C94,0x110A9820),(0x11113E5C,0x110A9820),(0x111141BC,0x110B6510)]:
        if pe.pointer(table+0x118)!=0x1105B620 or pe.pointer(table+0x124)!=enabled:
            raise ValueError("Unexpected named widget visibility/enabled virtual target")
    if hashlib.sha256(pe.at(0x110A9290, 0x110A93FD - 0x110A9290)).hexdigest() != "cf73a3e50345835c37d433a6af4e41b47aeb5f006feea7c446f351ea08f183c6":
        raise ValueError("Unexpected checkbox selection function body")
    group_bodies = {
        0x110A8570: (0x110A8653, "57c7bd925f06f125de6cd7d927a75ad5d13306ce3ad75319806dc4bde6c03be6"),
        0x1104DE80: (0x1104DEAB, "673939656768db6d3cf7aa68d91f289868f9520c0b20dbbf10462080595aabef"),
        0x1104F530: (0x1104F565, "f21c86381271b6462859e5e0baebefe70866dbabdce72987113cfd6246daccd6"),
        0x110A99B0: (0x110A9A16, "d272b57dce786db66e45d5acc3a0446f08e039bb1a2280343c820e07e659b065"),
    }
    for address, (end, expected) in group_bodies.items():
        if hashlib.sha256(pe.at(address, end - address)).hexdigest() != expected:
            raise ValueError("Unexpected option-group initialization body")
    checks = {
        0x110A85BB: "81c15c0b0000", 0x110A85C1: "e8ba58faff",
        0x1104DE9F: "66894c0204", 0x1104F54C: "7509",
        0x110A947C: "e8af60faff", 0x110A9486: "0f859f000000",
        0x110A99DD: "e84e5bfaff", 0x110A99E7: "7527",
        0x110A8552: "c7005c3e1111", 0x110A929C: "0fb688580b0000",
        0x110A9397: "0fb64d0c", 0x110A939D: "7423", 0x110A93BD: "e80ef7fbff",
        0x110A93C4: "0fb6450c", 0x110A93CA: "7423", 0x110A93EA: "e8e1f6fbff",
        0x110A9381: "6a01", 0x110A9383: "6a00", 0x110A9393: "ffd0",
        0x110AA557: "0fb68818070000", 0x110AA560: "0f84a7000000",
        0x110AA584: "8b8a24070000", 0x110AA5A8: "8b8a1c070000",
        0x110AA5C8: "6870c41111", 0x110AA5F6: "8b422c", 0x110AA5F9: "ffd0",
        0x110A940C: "0fb688580b0000", 0x110A9413: "0fb65508",
        0x110A9419: "7505", 0x110A941B: "e935010000",
        0x110A9426: "8888580b0000", 0x110A94F1: "6a01", 0x110A94F3: "6a00",
        0x110A94FD: "8b82c0010000", 0x110A9503: "ffd0",
        0x110A9507: "0fb64d0c", 0x110A950D: "741a",
        0x110A9524: "e8a7f5fbff", 0x110A952B: "0fb64d0c",
        0x110A9531: "741a", 0x110A9548: "e883f5fbff",
        0x110A9550: "e87bebfaff", 0x110A9558: "c20800",
        0x110B662E: "e88d3effff", 0x110B6636: "c20400",
        0x110AA4F9: "898824070000", 0x110AA502: "e8c9dbfaff",
        0x110AA50F: "8b9090010000", 0x110AA515: "ffd2",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected UI control action instruction")
    return {"dllSHA256": digest, "instructionChecks": len(checks), "exports": {k: hex(v) for k, v in exports.items()},
            "namedWidgetVisibility": {"visibleOffset": "0x118", "enabledOffset": "0x124", "tables": ["0x11113c94", "0x11113e5c", "0x111141bc"], "limits": "Known option, checkbox and slider vtables only; resource declarations and live layout children are not interchangeable. Nested effects of these setters are not classified here."},
            "optionGroupInitialization": {"groupMember": "0xb5c", "initialUTF16FirstUnit": 0,
                                          "emptyCheck": "0x1104f530", "emptySkipsPeerLoop": True,
                                          "managerRegistration": "Empty groups skip this method's explicit group-registration call; its base manager call is not classified here.",
                                          "functionSHA256": {hex(k): v[1] for k, v in group_bodies.items()},
                                          "limits": "Initial group state and named branch only, not live groups or all later setters."},
            "checkboxSelection": {"virtualTable": "0x11113e5c", "target": "0x110a9290",
                                  "functionSHA256": "cf73a3e50345835c37d433a6af4e41b47aeb5f006feea7c446f351ea08f183c6",
                                  "parameters": ["selected", "sendNotify"],
                                  "directNotifyCalls": ["0x110a93bd", "0x110a93ea"],
                                  "directNotifyGuard": "second argument must be nonzero",
                                  "peerArguments": [False, True]},
            "optionVirtualTable": "0x11113c94", "selectedMethodOffset": "0x1c0",
            "selectedParameters": ["selected", "sendNotify"],
            "messageUpdateArguments": [True, False],
            "directNotifyCalls": ["0x110a9524", "0x110a9548"],
            "directNotifyGuard": "second argument must be nonzero; the audited child update passes zero",
            "groupPeerSelection": {"virtualOffset": "0x1c0", "arguments": [False, True]},
            "sliderValueUpdate": {"forwardMethod": "0x110aa4c0", "valueMember": "0x724", "followingVirtualOffset": "0x190", "callbackMethod": "0x110aa520", "followingTextVirtualOffset": "0x2c"},
            "hardwareWriteAuthorized": False,
            "limits": "Current option direct notify is bypassed, but peer virtual dispatch, slider text virtual dispatch and invalidation are not exhaustively classified. No assertion that all callbacks lack hardware effects or that firmware polling settings are unsupported."}


def inspect_settings_child_polling_message(pe):
    if pe.class_name(0x77813C) != ".?AVCBasicSetWnd@@" or pe.pointer(0x77813C + 0x80) != 0x426A70:
        raise ValueError("Unexpected basic settings child message dispatch")
    checks = {
        0x426AD4: "81ea170c0000", 0x426ADD: "837dd823",
        0x426AEA: "0fb68848744200", 0x426AF1: "ff248df0734200",
        0x42707A: "8b450c", 0x427083: "668b4d10", 0x42708F: "52",
        0x427096: "50", 0x42709A: "e851260000", 0x42709F: "e92d030000",
        0x429727: "0fb788b2090000", 0x42972E: "0fb7550c",
        0x429734: "0f85dd000000", 0x429740: "8b4d08", 0x429743: "89886c0a0000",
        0x429749: "68449e7200", 0x429757: "ff157cb16e00",
        0x42977F: "ff15ecb06e00", 0x4297A5: "6810b97200",
        0x4297AA: "68609e7200", 0x4297B6: "ff15c0b16e00",
        0x4297EA: "6a00", 0x4297EC: "6a01", 0x4297FC: "8b82c0010000",
        0x429802: "ffd0", 0x42982F: "c20800",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected child polling message instruction")
    # Decode the compact switch, including its byte-index table. Searching for
    # the literal 0xc19 alone misses this normalized dispatch.
    index = pe.at(0x427448 + 0xC19 - 0xC17, 1)[0]
    if index != 2 or pe.pointer(0x4273F0 + index * 4) != 0x42707A:
        raise ValueError("Unexpected child polling message switch target")
    names = {0x729E44: "report_slider", 0x729E60: "%s%d", 0x72B910: "polling_rate_option_"}
    for address, name in names.items():
        expected = (name + "\0").encode("utf-16-le")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected polling update control name")
    imports = {0x6EB17C: "?FindControl@CPaintManagerUI@DuiLib@@QBEPAVCControlUI@2@PB_W@Z",
               0x6EB0EC: "?SetValue@CSliderUI@DuiLib@@QAEXH@Z",
               0x6EB1C0: "?Format@CDuiString@DuiLib@@QAAHPB_WZZ"}
    for address, name in imports.items():
        expected = (name + "\0").encode("ascii")
        if pe.at(pe.base + pe.pointer(address) + 2, len(expected)) != expected:
            raise ValueError("Unexpected child polling UI import")
    return {"instructionChecks": len(checks), "childClass": "CBasicSetWnd",
            "vtable": "0x77813c", "messageMethodOffset": "0x80", "messageMethod": "0x426a70",
            "switch": {"subtract": "0xc17", "maximumIndex": 35, "byteIndexTable": "0x427448",
                       "targetTable": "0x4273f0", "message": "0xc19", "targetIndex": index, "target": "0x42707a"},
            "updateMethod": "0x4296f0", "guard": "low16(lParam) equals child member +0x9b2",
            "selectedIndexStore": {"source": "wParam", "childMember": "0xa6c"},
            "uiOperations": ["FindControl(report_slider) then CSliderUI.SetValue(selectedIndex)",
                             "Format(polling_rate_option_%d, selectedIndex) then control virtual +0x1c0 with arguments 1, 0"],
            "hardwareWriteAuthorized": False,
            "limits": "Named child dispatch and UI update only; indirect UI callbacks and other module paths remain unclassified. This is not a firmware settings write command or proof that no such command exists."}


def inspect_settings_window_messages(pe):
    for address, encoded in SETTINGS_WINDOW_MESSAGE_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected settings window message instruction")
    # In this fixed, unbound PE image the IAT holds a hint/name RVA. Check the
    # actual import name rather than treating the call address as HID evidence.
    name_address = pe.base + pe.pointer(0x6EBEA0) + 2
    if pe.at(name_address, 13) != b"SendMessageW\0":
        raise ValueError("Unexpected settings notification import")
    return {"instructionChecks": len(SETTINGS_WINDOW_MESSAGE_CHECKS),
            "apiImport": "SendMessageW", "iatAddress": "0x6ebea0",
            "source": "parameter state update 0x4fd620",
            "wordReads": {"RFReportSelectItem": "0x4fdd94", "ReportSelectItem": "0x4fddc1"},
            "message": "0xc19", "firstWindowMember": "0x1f64",
            "relay": {"comparison": "0x493b81", "childWindowMember": "0x146c",
                      "forwardCall": "0x493bb3", "argumentsPreserved": ["wParam", "lParam"]},
            "limits": "These calls send a Windows window message. The named +0x280 predicate is separately audited as a status query; the normalized child polling handler is separately audited; indirect callbacks remain unclassified. This does not establish or exclude a separate firmware settings command."}


def inspect_polling_reload_allowlist(pe):
    checks = {0x4FDB6C: "81fada010000", 0x4FDB7E: "81f9e6010000",
              0x4FDB90: "3df7010000", 0x4FDBA1: "81fae2010000",
              0x4FDBB3: "81f9ef010000", 0x4FDBC5: "3dfb010000",
              0x4FDBD6: "81fa42010000", 0x4FDBE8: "81f94c010000",
              0x4FDBEE: "752a", 0x4FDBF3: "660fb682ba3f0000",
              0x4FDBFE: "668981e63f0000", 0x4FDC08: "660fb682bb3f0000",
              0x4FDC13: "668981e83f0000", 0x4FDD04: "81c1e03f0000",
              0x4FDD30: "e83b51f8ff"}
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected polling reload allowlist instruction")
    return {"instructionChecks": len(checks), "method": "0x4fd620",
            "products": [0x1DA, 0x1E6, 0x1F7, 0x1E2, 0x1EF, 0x1FB, 0x142, 0x14C],
            "includesTarget": False,
            "sourceMembers": {"ReportSelectItem": "0x3fba", "RFReportSelectItem": "0x3fbb"},
            "destinationMembers": {"ReportSelectItem": "0x3fe6", "RFReportSelectItem": "0x3fe8"},
            "subsequentJSONSetter": "0x482e70",
            "limits": "On this reload path, 01CE skips the two raw-byte-to-setting assignments. Subsequent JSON serialization and the previously audited polling window notification can therefore use existing settings values; they do not prove fresh firmware polling readback. Pointer-based consumers and other reload paths are not globally excluded."}


def inspect_other_parameter_sender_classes(pe):
    tables = {
        0x77F050: (".?AVCEevisionHS6533Device@@", {0x2BC: 0x4ED810}),
        0x77FA58: (".?AVCEevisionMouseDevice@@", {0x2B8: 0x52DFF0, 0x2BC: 0x52E060}),
        0x77F604: (".?AVCEevisionKeyboardDevice@@", {0x2B8: 0x500360, 0x2BC: 0x500790}),
    }
    for table, (name, methods) in tables.items():
        if pe.class_name(table) != name:
            raise ValueError("Unexpected parameter sender RTTI class")
        for offset, method in methods.items():
            if pe.pointer(table + offset) != method:
                raise ValueError("Unexpected parameter sender class method")
    checks = {0x52E0DB: "0fb7881a1e0000", 0x52E0E2: "81f9bbbb0000",
              0x52E0E8: "7524", 0x52E104: "e8b7070000",
              0x4ED845: "81c148260000", 0x4ED84B: "e890d5f8ff",
              0x4ED8EF: "6a15", 0x4ED907: "e834fdfeff"}
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected other-class parameter sender instruction")
    return {"instructionChecks": len(checks),
            "classes": [{"vtable": hex(table), "class": name,
                         "methods": {hex(offset): hex(method) for offset, method in methods.items()}}
                        for table, (name, methods) in tables.items()],
            "mouseSpecialBranch": {"caller": "0x52e104", "product": 0xBBBB, "method": "0x52e8c0"},
            "hs6533Structure": {"profileMember": "0x2648", "getter": "0x47ade0",
                                "parameterWriteLength": 21},
            "limits": "These named senders are associated with distinct RTTI classes. Mouse and HS6533 virtual methods are not the target keyboard's virtual dispatch and must not be copied as its settings protocol. Direct or indirect calls outside these inspected paths are not globally excluded."}


def inspect_profile_selection_send(pe):
    checks = {
        0x48FB41: "6800d37400", 0x48FB84: "e8674dfaff",
        0x48FBAA: "e8c1b50100", 0x4AB1CC: "8b4508",
        0x4AB1D9: "e82294f8ff", 0x4AB249: "8b4508",
        0x4AB255: "8b82b8020000", 0x500371: "8a5508",
        0x500374: "88540dff", 0x5004CF: "7527",
        0x5004F8: "6a00", 0x5004FA: "6a01",
        0x500504: "8d4415ff", 0x500512: "e829d1fdff",
        0x500522: "e8b99bfdff", 0x4B6A1E: "6a00",
        0x4B6A23: "e84847ffff",
    }
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected profile selection send instruction")
    label = "device_nprofile_combo".encode("utf-16le") + b"\0\0"
    if pe.at(0x74D300, len(label)) != label or pe.pointer(0x77F604 + 0x2B8) != 0x500360:
        raise ValueError("Unexpected profile selection control or virtual target")
    return {"instructionChecks": len(checks), "control": "device_nprofile_combo",
            "selectedIndexGetter": "0x4348f0", "dispatch": "0x4ab170",
            "deviceVirtualOffset": "0x2b8", "targetVirtualMethod": "0x500360",
            "fallbackReport": {"helper": "0x4dd640", "offset": 0, "length": 1,
                               "payload": "low byte of requested profile index"},
            "otherBranchProducts": [0x1DE, 0x1E0, 0x1E2, 0x1E4, 0x1DA, 0x1DB,
                                    0x1E6, 0x1E8, 0x1F7, 0x1F9, 0x1EF, 0x1F1,
                                    0x1FB, 0x1FD, 0x14C, 0x14E],
            "otherBranchIncludesTarget": False,
            "limits": "This named one-byte path selects a configuration profile, not a seven-word system setting. It does not establish the target's usable profile count, successful firmware persistence, or authorize a product write entry. Other parameter helper callers remain separately classified."}


def inspect_parameter_sender_lengths(pe):
    checks = {
        0x500A77: "e88426f8ff", 0x500A82: "889525ffffff",
        0x500A8E: "888526ffffff", 0x500ACB: "b910000000",
        0x500AD0: "8db5f0feffff", 0x500AD6: "f3a5",
        0x5010DB: "c1e206", 0x5010DF: "6a09",
        0x5010FA: "e841c5fdff", 0x5010FF: "8b4508",
        0x501105: "83c015", 0x501109: "6a01",
        0x501124: "e817c5fdff", 0x501129: "b901000000",
        0x50113C: "83c018", 0x501140: "6a01",
        0x50115B: "e8e0c4fdff", 0x501160: "6a01",
        0x50116E: "e86d8ffdff", 0x501173: "b801000000",
        0x4DD659: "c645bc00", 0x4DD65D: "6a3f",
        0x4DD682: "c6440dbc06", 0x4DD6F9: "3b550c",
        0x4DD715: "3b4d0c", 0x4DD72F: "8b4d0c",
        0x4DD78D: "8b4508", 0x4DD7A4: "e877951a00",
        0x4DD846: "e835bbffff", 0x4DD877: "8b8560ffffff",
        0x4DD897: "b89affffff", 0x4DD8B6: "b899ffffff",
    }
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected parameter sender length instruction")
    return {"instructionChecks": len(checks), "helper": "0x4dd640",
            "helperLengthSource": "second stack argument [ebp+0x0c]",
            "helperSourcePointer": "first stack argument [ebp+0x08]",
            "helperCommand": 6, "reportBytes": 64,
            "helperSHA256": hashlib.sha256(pe.at(0x4DD640, 0x4DD8D7-0x4DD640)).hexdigest(),
            "workBufferPollingOffsets": {"ReportSelectItem": 53, "RFReportSelectItem": 54},
            "fallbackWrites": [{"offset": 0, "length": 9}, {"offset": 21, "length": 1},
                               {"offset": 24, "length": 1}],
            "bankOffset": "profile index << 6", "fallbackIncludesPollingOffsets": False,
            "outerChecksEachSendReturn": False, "outerReturn": 1,
            "limits": "Named fallback and helper only. Helper honors the passed length, unlike the separately analyzed key sender. Outer function ignores these send/finish return values; its success does not prove firmware application. Other model branches and independent send paths are not excluded."}


def inspect_settings_post_apply(pe):
    checks = {
        0x4B0099: "e988020000", 0x4B0336: "83b90026000000",
        0x4B0345: "83baf405000000", 0x4B035F: "0f8481020000",
        0x4B0365: "688c027600", 0x4B04FB: "e830c20300",
        0x4EC73C: "81c65c210000", 0x4EC742: "b90b000000",
        0x4EC74A: "f3a566a5a4", 0x4FB990: "e85b5b0400",
        0x4FB998: "81c65c210000", 0x4FB9B6: "e865f9f7ff",
        0x5414FC: "81c75c210000", 0x54150A: "f3a566a5a4",
        0x4F6446: "c7800026000000000000",
        0x4B88AA: "81f999000000", 0x4B88C4: "81fafb010000",
        0x4B88DE: "3def010000", 0x4B88F7: "81f9da010000",
        0x4B88FD: "0f85d4020000", 0x4B8909: "e8d287f7ff",
        0x4B8911: "899570fdffff", 0x4B8BD1: "898800260000",
    }
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected settings post-apply instruction")
    if pe.pointer(0x77F604 + 0x324) != 0x4FB970:
        raise ValueError("Unexpected post-apply structure setter")
    label = "device_select_layout".encode("utf-16le") + b"\0\0"
    if pe.at(0x76028C, len(label)) != label:
        raise ValueError("Unexpected post-apply device list")
    return {"instructionChecks": len(checks), "entry": "0x4b0326",
            "deviceList": "device_select_layout", "requiredDeviceMember": "0x2600",
            "requiredWindowMember": "0x5f4", "structureBytes": 47,
            "structureMember": "0x215c", "getter": "0x4ec730",
            "structureSetterVirtualOffset": "0x324", "structureSetter": "0x4fb970",
            "profileJSONSetter": "0x47b320",
            "targetConstructorInitialFlag": 0,
            "selectionFlagWriter": "0x4b8bd1",
            "selectionFlagWriterProductAllowlist": [0x99, 0x1FB, 0x1EF, 0x1DA],
            "selectionFlagWriterIncludesTarget": False,
            "limits": "Post-apply device-list path copies the lighting structure, then invokes save/refresh/parameter virtual methods. This named selection setter excludes 01CE; initialization is not proof of every later runtime value, and other possible setters or indirect paths are not excluded. This is not a seven-word settings transport or a hardware acceptance result."}


def inspect_basic_apply_refresh(pe):
    """Classify the named post-dialog refresh, without executing its call graph."""
    checks = {
        0x4B0045: "8b8230020000",
        0x4B004B: "ffd0",
        0x4F9C95: "81c100400000",
        0x4F9C9B: "e84011f8ff",
        0x4F9CB5: "81c75c210000",
        0x4F9CC3: "f3a5",
        0x4F9D95: "3b8d00ffffff",
        0x4F9D9B: "0f8400010000",
        0x4F9DAF: "8b904c030000",
        0x4F9DF3: "ff248da4a04f00",
        0x4F9EA7: "81c1f8210000",
        0x4F9EAD: "e8fecffdff",
        0x4F9EC5: "e89625f8ff",
        0x4F9EDD: "81c124220000",
        0x4F9F07: "e8a4f30000",
        0x4F9F21: "e84af60000",
        0x4F9F3B: "e880f90000",
        0x5094D1: "81c150210000",
        0x5094D7: "e81490f1ff",
        0x5094DF: "8810",
        0x5094F7: "884801",
        0x509510: "884802",
        0x509556: "885803",
        0x47C4B7: "68205d7400",
        0x47C4EA: "68145d7400",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected basic-settings refresh instruction")
    for address in [0x745D14, 0x745D20]:
        if pe.at(address, 10) != b"LightList\0":
            raise ValueError("Unexpected refresh lighting-list name")
    ranges = {
        "0x4f9c10": {"end": "0x4fa0a4",
                     "sha256": "36f8296ec612106b40301b54eac0267cc4b8e7ef231171d863ecb724a883744a"},
        "0x5092b0": {"end": "0x509566",
                     "sha256": "a10c2d7baf14c5f35a45daf388c267939d2988e34f64740b0cb2c834346bc041"},
        "0x509570": {"end": "0x5098b5",
                     "sha256": "f7ec3e2e4742c7e963b1e965e7057800dc52b7079961a5eee5cb1d0a730c1c27"},
        "0x5098c0": {"end": "0x509b5a",
                     "sha256": "fe6e85abc1f3a48c9be9978ff2251e48473c51a2cd288c4dba6560fe5a28d4f9"},
    }
    for start, item in ranges.items():
        address, end = int(start, 16), int(item["end"], 16)
        if hashlib.sha256(pe.at(address, end-address)).hexdigest() != item["sha256"]:
            raise ValueError("Unexpected basic-settings refresh function bytes")
    virtuals = {0x230: 0x4F9C10, 0x34C: 0x504130, 0x3D0: 0x508000,
                0x3C8: 0x507E40, 0x370: 0x5051E0, 0x37C: 0x505650,
                0x3A4: 0x506190, 0x388: 0x505900}
    for offset, target in virtuals.items():
        if pe.pointer(0x77F604+offset) != target:
            raise ValueError("Unexpected basic-settings refresh virtual target")
    return {"instructionChecks": len(checks), "functionByteRanges": ranges,
            "dialogCall": "0x4b004b", "virtualOffset": "0x230", "method": "0x4f9c10",
            "lightStructureSource": "JSON getter 0x47ade0, 47 bytes to device+0x215c",
            "modeChangeBranch": "Compare previous and loaded device+0x3f71; only a changed lighting mode enters dispatch",
            "modeVirtualTargets": {hex(k): hex(v) for k,v in virtuals.items() if k != 0x230},
            "colorDefinitionSource": "LightList JSON getter 0x47c460 to device+0x2224",
            "colorRefreshHelpers": ["0x5092b0", "0x509570", "0x5098c0"],
            "colorRefreshDestination": "device+0x2150 vector; entries updated as four color bytes",
            "limits": "Classifies these refresh inputs and helper destinations. The mode methods and indirect or nested calls are not an exhaustive transport audit; this does not prove that no other setting command exists. No program execution, device write or polling-rate acceptance."}


def inspect_basic_apply_save(pe):
    """Resolve the save virtuals separately from the following USB sender."""
    checks = {
        0x4B002F: "8b8200030000", 0x4FB2FA: "81c100400000",
        0x4FB303: "8b9000400000", 0x4FB309: "8b4204",
        0x4FB30C: "ffd0", 0x47CAEB: "83c008",
        0x47CB13: "81c2a8030000", 0x47CB39: "8b4208",
        0x47CB3C: "ffd0", 0x47C9DA: "81c1d8030000",
        0x47C9E0: "e8ab8a0000", 0x47CA4F: "81c1d8030000",
        0x47CA55: "e8d6880000",
    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected basic-settings save instruction")
    for table, offset, target in [(0x77F604, 0x300, 0x4FB2F0),
                                  (0x77D174, 4, 0x47CAC0),
                                  (0x77D174, 8, 0x47C9A0)]:
        if pe.pointer(table+offset) != target:
            raise ValueError("Unexpected settings save virtual target")
    return {"instructionChecks": len(checks), "dialogCall": "0x4b0035",
            "deviceSaveMethod": "0x4fb2f0", "profileClass": "KeyboardProfiledata",
            "profileSaveMethods": ["0x47cac0", "0x47c9a0"],
            "profileObjectMember": "0x4000", "saveObjectMember": "0x3d8",
            "configurationGetter": "0x485490", "configurationSetter": "0x485330",
            "limits": "Resolves this save wrapper to profile configuration getter/setter calls, separately from the later +0x2bc parameter sender. Nested getter/setter storage internals are not exhaustively audited here; this does not establish firmware persistence or absence of alternate setting transports."}


def inspect_profile_file_storage(pe):
    """Identify the save wrapper's JSON serializer and disk output stream."""
    classes = {0x77A68C: ".?AV?$basic_ofstream@DU?$char_traits@D@std@@@std@@",
               0x77A648: ".?AVStyledWriter@Json@@"}
    for table, name in classes.items():
        if pe.class_name(table) != name:
            raise ValueError("Unexpected profile storage class")
    checks = {
        0x47C9E0: "e8ab8a0000", 0x47CA0A: "8b91a0040000",
        0x47CA11: "682c5e7400", 0x47CA20: "e81bac0c00",
        0x47CA2B: "e8109b0c00", 0x47CA55: "e8d6880000",
        0x485370: "e85b030000", 0x485379: "6a40", 0x48537B: "6a02",
        0x485380: "ff15c4b16e00", 0x48538D: "e8de020000",
        0x4853D4: "e8672e0c00", 0x4853EF: "68c0574800",
        0x485402: "e819050000", 0x48540C: "e88f030000",
        0x4856FF: "837d0800", 0x485708: "c70080a67700",
        0x48574E: "c704108ca67700", 0x48567E: "83c902",
        0x48568C: "e87f98fdff", 0x45EF4D: "e812432200",
        0x548279: "c745a448a67700", 0x5482B3: "e878830000",
        0x4857AB: "ff5508", 0x4857C3: "6a0a",
        0x4857DE: "e80d000000", 0x4857E6: "e82577f9ff",
        0x485142: "6828a97400", 0x485151: "e829fd2000",
        0x485527: "e8d4fbffff", 0x4855BA: "e8a1550c00",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected profile file-storage instruction")
    if pe.at(0x745E2C, 7) != b"Device\0" or pe.at(0x74A928, 6) != "rb\0".encode("utf-16-le"):
        raise ValueError("Unexpected profile file-storage field or read mode")
    string_import = "??BCDuiString@DuiLib@@QBEPB_WXZ"
    raw = (string_import + "\0").encode("ascii")
    if pe.at(pe.base + pe.pointer(0x6EB1C4) + 2, len(raw)) != raw:
        raise ValueError("Unexpected profile filename conversion import")
    bodies = {
        0x47C9A0: (0x47CAB1, "fad04f3e24f2cf2571c8209e9395c618b8b299bdc7616e3fb152684bbe3bf506"),
        0x485330: (0x485482, "184da6f592731469421d4c7b71d17cea446c8cc6e90b6306e76be58e2a11ceb3"),
        0x485490: (0x485666, "29543f0719250ea3589014bc2123f7beb7ae40c8607638774be7964c01d0af77"),
        0x485100: (0x48532F, "eabf976213f30f3c8e2c7095df351ab808ff7967c1af3fd18a2598c6fc4c924d"),
        0x548240: (0x5482DF, "43c27c73294fa05f7c637e24a627e797691f67e29a32363d98104e4f6df3fae5"),
        0x4856D0: (0x485797, "13c89cbe330f2cf5974640ee9025328f06c6378e1c63389e41d677c11d5074a6"),
        0x485670: (0x4856C9, "cc91dc173710377d7dc5ed4313fc10b23b21843574a10c4fda714859c954a9fa"),
        0x45EF10: (0x45EFC4, "0aa92271e9881d2fa8705336671200e5de8919b7b43fbedd36bf372048617cb6"),
        0x4857A0: (0x4857B7, "6bd18ce6da8eb22bef45992dcaa14de385714461016cdb2988495ee2298ec7f3"),
        0x4857C0: (0x4857F0, "b99c7aeca5f34ca4c06369c2bc906c5f3c63f572753bbb23ee4c9ff40b121e3a"),
    }
    for start, (end, digest) in bodies.items():
        if hashlib.sha256(pe.at(start, end - start)).hexdigest() != digest:
            raise ValueError("Unexpected profile file-storage function body")
    return {
        "instructionChecks": len(checks), "classes": {hex(k): v for k, v in classes.items()},
        "profileUpdate": {"method": "0x47c9a0", "deviceArrayField": "Device",
                          "selectedIndexMember": "0x4a0", "assignCall": "0x47ca2b"},
        "reader": {"method": "0x485490", "fileReader": "0x485100",
                   "wideMode": "rb", "parseCall": "0x4855ba"},
        "writer": {"method": "0x485330", "streamConstructor": "0x4856d0",
                   "filenameConversionImport": string_import, "openCall": "0x48538d",
                   "serializer": "0x548240", "serializerClass": "Json::StyledWriter",
                   "streamInsertion": "0x485920", "newlineAndFlush": "0x4857c0"},
        "functionBodies": {hex(a): {"endExclusive": hex(b), "sha256": h} for a, (b, h) in bodies.items()},
        "conclusion": "This named profile-save chain updates a Device JSON row, serializes JSON and writes a host file through basic_ofstream. File saving must be distinguished from the later device parameter send.",
        "hardwareWriteAuthorized": False,
        "limits": "Named save and file-stream paths only. Static RTTI and call arguments do not prove disk-write success, global absence of alternate transports or any firmware persistence. CRT internals, dynamic replacement and all stream virtual consumers are not exhaustively audited.",
    }


def inspect_system_device_paths(pe):
    for address, encoded in SYSTEM_DEVICE_CHECKS.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected system settings device instruction")
    return {"instructionChecks": len(SYSTEM_DEVICE_CHECKS),
            "deviceWordOffset": "0x3fe0", "profileObjectOffset": "0x4000",
            "selectedSetter": "0x4fb8c0", "selectedSetterBehavior": "Copy seven words then call JSON setter; no transport in this function",
            "selectedReadbackBranchProducts": [0x1DA, 0x1E6, 0x1EF, 0x1FB, 0x142, 0x14C],
            "selectedReadbackBranchIncludesTarget": False,
            "selectedReadbackBytes": {"ReportSelectItem": 53, "RFReportSelectItem": 54},
            "limits": "Only the named paths are audited; not proof that all settings are host-only, unsupported or writable on 01CE."}





def inspect_target_parameter_branch(pe):
    """Pin every PID comparison and conditional edge in this sender selector."""
    digest="f9518bb11f012a8c82509f1f185099a2bd3f045bafcf1f515ac4d037caf87dde"
    if hashlib.sha256(pe.at(0x500790,0x50118A-0x500790)).hexdigest()!=digest:
        raise ValueError("Unexpected target parameter sender body")
    checks = {
        0x500AE5: "83f977",
        0x500AE8: "0f84c2000000",
        0x500AFB: "3dc3000000",
        0x500B00: "0f84aa000000",
        0x500B13: "81facd000000",
        0x500B19: "0f8491000000",
        0x500B2C: "81f9cb000000",
        0x500B32: "747c",
        0x500B41: "3dd2000000",
        0x500B46: "7468",
        0x500B55: "81face000000",
        0x500B5B: "7453",
        0x500B6A: "81f9ab010000",
        0x500B70: "743e",
        0x500B7F: "3daf010000",
        0x500B84: "742a",
        0x500B93: "81fabb010000",
        0x500B99: "7415",
        0x500BA8: "81f9cec00000",
        0x500BAE: "750a",
        0x500BE7: "81f9b4000000",
        0x500BED: "752c",
        0x500C28: "81f9b2010000",
        0x500C2E: "0f84e2000000",
        0x500C41: "3db7010000",
        0x500C46: "0f84ca000000",
        0x500C59: "81fab1010000",
        0x500C5F: "0f84b1000000",
        0x500C72: "81f9b4010000",
        0x500C78: "0f8498000000",
        0x500C8B: "3de5000000",
        0x500C90: "0f8480000000",
        0x500CA3: "81faec000000",
        0x500CA9: "746b",
        0x500CB8: "81f9c2010000",
        0x500CBE: "7456",
        0x500CCD: "3dc3010000",
        0x500CD2: "7442",
        0x500CE1: "81fae3000000",
        0x500CE7: "742d",
        0x500CF6: "81f9ea000000",
        0x500CFC: "7418",
        0x500D0B: "3df3010000",
        0x500D10: "0f8580000000",
        0x500DA3: "81fad7010000",
        0x500DA9: "0f8580000000",
        0x500E3C: "81f9de010000",
        0x500E42: "0f84e2000000",
        0x500E55: "3de2010000",
        0x500E5A: "0f84ca000000",
        0x500E6D: "81fae4010000",
        0x500E73: "0f84b1000000",
        0x500E86: "81f9da010000",
        0x500E8C: "0f8498000000",
        0x500E9F: "3ddb010000",
        0x500EA4: "0f8480000000",
        0x500EB7: "81fae6010000",
        0x500EBD: "746b",
        0x500ECC: "81f9e8010000",
        0x500ED2: "7456",
        0x500EE1: "3df7010000",
        0x500EE6: "7442",
        0x500EF5: "81faf9010000",
        0x500EFB: "742d",
        0x500F0A: "81f9ef010000",
        0x500F10: "7418",
        0x500F1F: "3df1010000",
        0x500F24: "0f859e000000",
        0x500FD5: "81fafb010000",
        0x500FDB: "7442",
        0x500FEA: "81f942010000",
        0x500FF0: "742d",
        0x500FFF: "3d4c010000",
        0x501004: "7419",
        0x501013: "81fa4e010000",
        0x501019: "0f85b9000000",
    }
    for address,encoded in checks.items():
        raw=bytes.fromhex(encoded)
        if pe.at(address,len(raw))!=raw:
            raise ValueError("Unexpected parameter sender PID edge")
    groups = [
        {"entry":"0x500bb0","productIDs":[0x77,0xC3,0xCD,0xCB,0xD2,0xCE,0x1AB,0x1AF,0x1BB,0xC0CE],"behavior":"Return success before parameter transfer"},
        {"entry":"0x500bef","productIDs":[0xB4],"behavior":"Four-byte parameter write"},
        {"entry":"0x500d16","productIDs":[0x1B2,0x1B7,0x1B1,0x1B4,0xE5,0xEC,0x1C2,0x1C3,0xE3,0xEA,0x1F3],"behavior":"Parameter spans 0/9, 21/1, 25/15"},
        {"entry":"0x500daf","productIDs":[0x1D7],"behavior":"Parameter spans 0/9, 21/1, 25/28"},
        {"entry":"0x500f2a","productIDs":[0x1DE,0x1E2,0x1E4,0x1DA,0x1DB,0x1E6,0x1E8,0x1F7,0x1F9,0x1EF,0x1F1],"behavior":"Different parameter preparation/write path"},
        {"entry":"0x50101f","productIDs":[0x1FB,0x142,0x14C,0x14E],"behavior":"Different parameter preparation/write path"},
    ]
    if any(0x1CE in item["productIDs"] for item in groups):
        raise ValueError("Target unexpectedly classified in an alternate sender path")
    return {"sender":"0x500790","functionEndExclusive":"0x50118a","functionSHA256":digest,
            "instructionChecks":len(checks),"productComparisonCount":len(checks)//2,
            "selectorSource":"word device+0x1e1a", "alternateBranches":groups,
            "targetProductID":0x1CE,"targetFallback":"0x5010d8",
            "targetParameterSpans":[{"relativeOffset":0,"length":9},{"relativeOffset":21,"length":1},{"relativeOffset":24,"length":1}],
            "profileOffset":"profileIndex << 6 added to each relative offset",
            "omittedWorkBufferBytes":[53,54],
            "distinction":"0x00ce and 0xc0ce in early-return comparisons are not target 0x01ce",
            "limits":"Proves only this sender's selector and its named target parameter spans. The separately audited dialog calls this virtual +0x2bc, but other setting senders and later/asynchronous consumers are not exhaustively covered. No live write or fresh rate readback."}


def inspect_refresh_mode_memory(pe):
    """Audit the closed direct-call paths of the named mode initializers."""
    bodies = {
        0x504130:(0x5041D5,"040f1c987ab09f76637c52dfcb40761a5bc38e20f44e13bf79e6a09fba21f92c"),
        0x508000:(0x5080AB,"e130e242fd57ec047a26ca3d37d4043c3071c4f753c60e48cfa603a40fb3c7bc"),
        0x507E40:(0x507EA4,"95ad33f67c873be2727d3f8eb4375412502af164a167a727d6e806fb09d82cd4"),
        0x5051E0:(0x5052A4,"c4a0cfb8788c669fa298949ac50622684aac4b0bbf2b223d4d8f3370035c6924"),
        0x505650:(0x5056ED,"44677951daaea7c002d949759dbc2e9830f199cae5b593f741350bfbc9cfdba7"),
        0x506190:(0x50623B,"31f8e1d5e4b05e5dd84a5b07bd3f70bc677bed00419493c3fb371be5b4642177"),
        0x519D70:(0x519DD1,"0a595140070a782056f274e01e6217871d24db4f9640858713d16a8d1da96968"),
        0x483DD0:(0x483DFD,"76c3eb638ea1373e6f79c2e834083f56321c255589401aea495208253dc116ee"),
        0x6872A0:(0x6873FA,"08e8653de0c12b3ce71849640f88fc12cb0a4fb4910a518c1082b63790c75bea"),
    }
    for start,(end,digest) in bodies.items():
        if hashlib.sha256(pe.at(start,end-start)).hexdigest()!=digest:
            raise ValueError("Unexpected refresh-mode function body")
    checks = {
        0x504157:"e874fcf7ff",0x50416A:"e861fcf7ff",0x50417E:"e84dfcf7ff",
        0x504192:"e839fcf7ff",0x5041A5:"e826fcf7ff",0x5041B9:"e812fcf7ff",
        0x5041C9:"8b90e4030000",0x5041CF:"ffd2",
        0x483DF4:"c60200",0x483DE9:"3b4d0c",
        0x519D84:"e817d51600",0x519D9A:"e801d51600",
        0x519DB0:"e8ebd41600",0x519DC5:"e8d6d41600",
        0x6872A0:"8b4c240c",0x6872A4:"0fb6442408",0x6872AB:"8b7c2404",
        0x6872DC:"f3aa",0x6873E0:"8907894704",
        0x50801A:"83c840",0x507E5F:"83f97e",0x5051FB:"837df817",
        0x50526D:"3dff000000",0x505680:"0fb645fe",0x5061AA:"83ca01",
    }
    for address,encoded in checks.items():
        raw=bytes.fromhex(encoded)
        if pe.at(address,len(raw))!=raw:
            raise ValueError("Unexpected refresh-mode memory instruction")
    virtuals={0x34C:0x504130,0x3D0:0x508000,0x3C8:0x507E40,0x370:0x5051E0,
              0x37C:0x505650,0x3A4:0x506190,0x3E4:0x519D70}
    for offset,target in virtuals.items():
        if pe.pointer(0x77F604+offset)!=target:
            raise ValueError("Unexpected refresh-mode virtual target")
    return {"instructionChecks":len(checks),"virtualTargetChecks":len(virtuals),
            "functionBodies":{hex(a):{"endExclusive":hex(b),"sha256":h} for a,(b,h) in bodies.items()},
            "modeInitializer":"0x504130 clears two flags, calls 0x483dd0 six times to zero 126/23-byte arrays, then target virtual +0x3e4",
            "nestedVirtual":"+0x3e4 -> 0x519d70 fills four 100-byte host buffers using the memory fill routine 0x6872a0; final buffer receives byte 1, others zero",
            "otherModeMethods":{
                "0x508000":"OR 0x40 into four host mode-array entries",
                "0x507e40":"Initialize 126 host phase entries at +0x22ca",
                "0x5051e0":"23x7 table traversal; skip 0xff and initialize host phase arrays",
                "0x505650":"23x7 table traversal; skip 0xff and copy host lookup-table bytes",
                "0x506190":"OR 1 into four host mode-array entries"},
            "transportClassification":"These six mode methods and their resolved nested callees only modify host memory; no direct HID exchange in this closed set",
            "limits":"Only the named post-settings mode-refresh paths; not an exhaustive settings/whole-program audit. Later animation consumers, other virtual calls and the separate 0x500790 sender are not reclassified. No runtime, hardware setting or persistence proof."}


def inspect_custom_lighting_json(pe):
    # Fixed-byte provenance for the actual RGBA reader and writer, not a
    # guessed schema generated from a similarly named device's defaults.
    checks = {
        0x48349E: "68108d7400", 0x4834AB: "68148d7400", 0x4834B0: "68ec8c7400",
        0x483480: "0fb600", 0x4834F6: "0fb65001", 0x48356D: "0fb64802", 0x4835E6: "0fb64803",
        0x483614: "68748d740068848d7400" ,
        0x4836C5: "68bc8d740068948d7400", 0x4836ED: "e8ae480c00",
        0x4836F7: "0f84e4010000", 0x483712: "3b4510", 0x483715: "0f8dc1010000",
        0x4838BB: "c645e000c645e100c645e200c645e300",
        0x4838D2: "e879edffff", 0x4838D7: "e92afeffff",
        0x483C51: "e86aebffff", 0x483C63: "e8f8edffff",
        0x505948: "e8c3cbf1ff", 0x50594D: "50", 0x505951: "52", 0x50595F: "e81cddf7ff",
    }
    for address, encoded in checks.items():
        raw=bytes.fromhex(encoded)
        if pe.at(address,len(raw)) != raw:
            raise ValueError("Unexpected custom-light JSON instruction")
    strings={0x748CEC:"CustomLightMode",0x748D14:"LightColorInfo",0x748D10:"Red",
             0x748D54:"Green",0x748D5C:"Blue",0x748DA4:"Alpha"}
    for address, value in strings.items():
        if pe.at(address,len(value)+1) != value.encode("ascii")+b"\0":
            raise ValueError("Unexpected custom-light JSON field")
    hashes={"setter":(0x483410,0x483678,"ab32e966c387929315e3e923c1cace83db9df24f9224f2b370f67377cb1adc12"),
            "getter":(0x483680,0x483C96,"b844424081910efd7655865852b7b220b7915fb6f0b76c9d647690de947c01a7")}
    for start,end,digest in hashes.values():
        if hashlib.sha256(pe.at(start,end-start)).hexdigest()!=digest:
            raise ValueError("Unexpected custom-light JSON function body")
    return {"instructionChecks":len(checks),"fieldChecks":len(strings),
            "functionBodies":{name:{"start":hex(a),"endExclusive":hex(b),"sha256":h} for name,(a,b,h) in hashes.items()},
            "path":["CustomLightMode","LightColorInfo","group","logicalIndex"],
            "recordByteOrder":["Red","Green","Blue","Alpha"],
            "missingGroupFallback":"0x4836f7 -> 0x4838e1 branches around the zero-initialization loop; the other branch creates RGBA-zero entries up to the supplied count before reading the list",
            "setterBehavior":"0x483410 writes four byte-valued fields at the supplied group and logical index; it does not require CustomLightModeGroupIndex",
            "loaderCount":"0x505948 takes existing +0x2150 list size, pushed at 0x50594d; not a hard-coded 126 in this function",
            "limits":"Static JSON construction/read paths only; no Windows runtime import, USB writes, visible lighting or persistence acceptance. Model47's separate logical layout establishes 126 entries."}


def inspect_settings_resources(skin):
    path = Path(skin) / "XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
    data = path.read_bytes()
    if len(data) > 500_000:
        raise ValueError("Settings resource exceeds audit bounds")
    root = ET.fromstring(data.lstrip())
    if len(list(root.iter("EevisionKeyboardDevice"))) != 1:
        raise ValueError("Settings resource does not select target device class")
    controls = {}
    for node in root.iter():
        name = node.get("name")
        if name:
            controls.setdefault(name, []).append(node)
    required = ["winlockflag_option", "wflag_option", "6flag_option", "repeat_delay_check_"]
    required += ["polling_rate_option_" + str(i) for i in range(4)]
    required += ["repeat_delay_check_" + str(i) for i in range(4)]
    if any(len(controls.get(name, [])) != 1 for name in required):
        raise ValueError("Settings controls are missing or ambiguous")
    slider = controls["repeat_delay_check_"][0]
    if slider.tag != "Slider" or [slider.get(k) for k in ["min", "max"]] != ["0", "31"]:
        raise ValueError("Unexpected repeat slider range")
    for index, hz in enumerate([1000, 500, 250, 125]):
        node = controls["polling_rate_option_" + str(index)][0]
        if node.tag != "Option" or str(hz) + "HZ" not in node.get("normalimage", ""):
            raise ValueError("Unexpected polling-rate resource")
    return {"resourceSHA256": hashlib.sha256(data).hexdigest(), "controls": required,
            "repeatSliderRange": [0, 31], "pollingControlLabelsHz": [1000, 500, 250, 125],
            "limits": "Static resource declarations only; runtime visibility, JSON bindings and hardware write path require separate evidence."}


def inspect_basic_settings_dialog(skin):
    path = Path(skin) / "KbBasicSetWnd.xml";data = path.read_bytes()
    if len(data) > 500_000:
        raise ValueError("Basic settings resource exceeds audit bounds")
    text = re.sub(r"<!--.*?-->", "", data.decode("utf-8"), flags=re.S)
    controls = {}
    for tag in re.finditer(r"<([A-Za-z_][A-Za-z_0-9:]*)\b([^<>]*)>", text):
        attrs = dict(re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*)="([^"<>]*)"', tag[2]))
        if "name" in attrs:controls.setdefault(attrs["name"], []).append((tag[1],attrs))
    labels = []
    for index,hz in enumerate([125,250,500,1000,2000,4000,8000]):
        nodes = controls.get("polling_rate_option_" + str(index), [])
        if len(nodes) != 1 or nodes[0][0] != "Option" or nodes[0][1].get("text") != str(hz)+"Hz":
            raise ValueError("Unexpected basic polling control")
        labels.append({"index": index, "labelHz": hz, "declaredVisible": nodes[0][1].get("visible", "true") != "false"})
    legacy = [name for name in controls if name in ["winlockflag_option", "wflag_option", "6flag_option"] or name.startswith("repeat_delay_check_")]
    if legacy:raise ValueError("Unexpected legacy settings controls in selected dialog")
    return {"resourceSHA256": hashlib.sha256(data).hexdigest(), "resource": "KbBasicSetWnd.xml", "pollingControls": labels,
            "legacyControlNamesPresent": legacy, "limits": "Declared visibility only; later UI changes and firmware setting support are not inferred."}


def inspect_macro_resources(skin):
    root = Path(skin)
    device_path = root / "XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
    control_path = root / "XML/CustomControlXML/MacroControl.xml"
    menu_path = root / "XML/Menus/macro_action_menu.xml"
    device_data, control_data, menu_data = (path.read_bytes() for path in [device_path, control_path, menu_path])
    if any(len(data) > 500_000 for data in [device_data, control_data, menu_data]):
        raise ValueError("Macro resource exceeds audit bounds")
    device = ET.fromstring(device_data.lstrip())
    if len(list(device.iter("MacroSetControlUI"))) != 1:
        raise ValueError("Target model must select one MacroSetControlUI")
    # DuiLib's resource has duplicate style attributes; it is not strict XML.
    # Scan only opening tags/control names, after removing comments. No eval,
    # external resources, entity expansion, or interpretation of style values.
    text = re.sub(r"<!--.*?-->", "", control_data.decode("utf-8"), flags=re.S)
    tags = list(re.finditer(r"<([A-Za-z_][A-Za-z_0-9:]*)\b([^<>]*)>", text))
    if not any(tag[1] == "MacroControl" for tag in tags):
        raise ValueError("Macro resource does not select MacroControl")
    names = [match[1] for tag in tags for match in re.finditer(r'\bname="([^"]+)"', tag[2])]
    required = ["macro_action_list", "macro_fixed_time_edit", "macro_check_mouse", "action_text_richedit"]
    if any(names.count(name) != 1 for name in required):
        raise ValueError("Macro controls are missing or ambiguous")
    menu = ET.fromstring(menu_data.lstrip())
    mouse = [element for element in menu.iter("MenuElement") if element.get("text") == "macro_btn_shubiao"]
    expected = ["left", "middle", "right", "forward", "back"]
    if len(mouse) != 1 or [element.get("text") for element in mouse[0]] != ["mouse_key_" + name for name in expected]:
        raise ValueError("Unexpected manual mouse macro menu")
    for element, name in zip(mouse[0], expected):
        if [child.get("name") for child in element] != [name + suffix for suffix in ["_down", "_up", "_click"]]:
            raise ValueError("Unexpected mouse macro operations")
    return {"modelMacroControl": "MacroSetControlUI", "factoryResource": "MacroControl.xml",
            "manualMouseButtons": expected, "manualOperations": ["down", "up", "click"],
            "requiredControls": required,
            "resourceSHA256": {path.name: hashlib.sha256(data).hexdigest()
                               for path, data in zip([device_path, control_path, menu_path], [device_data, control_data, menu_data])}}


def inspect_macro_capacity_sender(pe):
    """Audit byte-capacity accounting, count widths and the empty-bindings exit."""
    if pe.pointer(0x77F604 + 0x2B4) != 0x4FF710:
        raise ValueError("Unexpected target macro serializer dispatch")
    checks = {
        0x4FF925: "833800", 0x4FF928: "0f84b3000000",
        0x4FFA28: "83bdc8fcffff00", 0x4FFA2F: "0f85b3000000",
        0x4FFA35: "c78594fcffff00000000", 0x4FFAE3: "e956080000",
        0x4FFAF4: "8d044a", 0x4FFB09: "8d048a",
        0x4FFBDC: "e84f750400", 0x4FFBF3: "8d1481",
        0x4FFC16: "83c010", 0x4FFC25: "0fb691fa1d0000",
        0x4FFC2C: "c1e207", 0x4FFC2F: "3995d4fcffff",
        0x4FFC35: "0f86fd000000", 0x4FFD3F: "e8a34f1900",
        0x4FFE58: "66894202", 0x4FFE69: "66895104",
        0x4FFF96: "e895710400", 0x4FFF9B: "668985ccfcffff",
        0x4FFFB5: "881401", 0x4FFFCF: "88440a01",
        0x500008: "0fb78dccfcffff", 0x50000F: "3bc1",
        0x500011: "0f8dc1000000", 0x500054: "e8270bf8ff",
        0x5000E6: "8d048a", 0x500240: "0fb688fa1d0000",
        0x500247: "c1e107", 0x50024A: "0faf4d08",
        0x500269: "e822bbfdff",
        0x50024F: "8b95d4fcffff", 0x500255: "52",
        0x4DBE59: "3b450c", 0x4DBE5C: "0f83c0010000",
        0x4DBE75: "3b550c", 0x4DBE8F: "8b550c",
        0x4DBE92: "2b9578ffffff", 0x4DBEAC: "884c05bc",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected macro capacity/count instruction")
    digest = hashlib.sha256(pe.at(0x4FF710, 0x50035A - 0x4FF710)).hexdigest()
    if digest != "b5173c2681529d65765d444cee70165257fdc75da27801063223b6f78bbd7967":
        raise ValueError("Unexpected target macro serializer body")
    helper_digest = hashlib.sha256(pe.at(0x4DBD90, 0x4DC037-0x4DBD90)).hexdigest()
    if helper_digest != "87c7314f69901a0b49924d9725d920dfdee7405becdf00c2a0b0bba82afb2309":
        raise ValueError("Unexpected bounded macro transport helper body")
    return {"instructionChecks": len(checks), "virtualOffset": "0x2b4", "method": "0x4ff710",
            "functionEndExclusive": "0x50035a", "functionSHA256": digest,
            "capacityCheck": {"member": "byte(device+0x1dfa)", "multiplier": 128,
                              "formula": "16 + 6 * collectedBindingCount + 4 * totalEventCount",
                              "acceptsEqualNominalCapacity": True, "comparison": "0x4ffc2f"},
            "countEncoding": {"bankMacroCountBits": 16, "macroEventCountBits": 16, "eventBytes": 4,
                              "eventEncoder": "0x480b80", "eventLoopComparison": "0x50000f"},
            "emptyCollectedBindings": {"branch": "0x4ffa2f", "returnJump": "0x4ffae3",
                                       "result": 0, "sendsMacroBankFromThisMethod": False},
            "transport": {"targetCall": "0x500269", "helper": "0x4dbd90",
                          "profileBase": "byte(device+0x1dfa) * 128 * profileIndex",
                          "transferLength": "serialized total byte count, not nominal bank capacity",
                          "lastChunk": "minimum of chunk capacity and transferLength - cursor",
                          "helperEndExclusive": "0x4dc037", "helperSHA256": helper_digest},
            "productPolicyDistinction": "The named sender counts bytes and encodes word-sized counts; CherryMac's current 32-macro/256-event guards are not established as official UI or firmware limits by this evidence.",
            "hardwareWriteAuthorized": False,
            "limits": "Sender structure only. Does not establish official UI limits, firmware acceptance of larger counts, or readable/writable final capacity byte. Zero collected bindings means no bank send in this method, not whole-program or firmware erasure/retention proof."}


def inspect_macro_binding_collection_and_editor_limit(pe):
    """Audit per-binding append, ordinal key references and dynamic editor limit."""
    if pe.pointer(0x77F604 + 0x260) != 0x4F7D20:
        raise ValueError("Unexpected target macro editor setup dispatch")
    checks = {
        0x41D963: "8b4508", 0x41C527: "8b45fc",
        0x41EE9A: "e881d6ffff", 0x41F2CA: "e8c1fbffff",
        0x4211AA: "e8e1dcffff", 0x4211AF: "83c004",
        0x4F8399: "0fb681fa1d0000",
        0x4F83A0: "c1e007",
        0x4F83A3: "83e816",
        0x4F83A6: "99",
        0x4F83A7: "83e203",
        0x4F83AA: "03c2",
        0x4F83AC: "c1f802",
        0x4F83BC: "e8af5ff6ff",
        0x45E37D: "8988dc090000",
        0x453C34: "688cab7300",
        0x453C78: "3981dc090000",
        0x453C7E: "0f8fad000000",
        0x453CB1: "6a00",
        0x453CB3: "6a00",
        0x453CB5: "681b0c0000",
        0x453CC7: "ff15a0be6e00",
        0x4940B3: "817d081b0c0000",
        0x4940CA: "e8c10e0200",
        0x4B4FFA: "83bddcfeffff00",
        0x4B5001: "7533",
        0x4B5013: "68e4ac7400",
        0x4FF990: "83bd98fcffff02",
        0x4FF997: "7402",
        0x4FF9B4: "83c004",
        0x4FF9BE: "e88d31f8ff",
        0x4FF9C9: "83c001",
        0x482B6A: "e8e1fbf9ff",
        0x482B74: "0f84b7000000",
        0x42276C: "394508",
        0x42276F: "7321",
        0x422784: "3b4508",
        0x422787: "7709",
        0x482C27: "83c004",
        0x482CA8: "83c204",
        0x4FF00F: "c78548fdffff00000000",
        0x4FF2D0: "888de7fdffff",
        0x4FF2FA: "8885e7fdffff",
        0x4FF31B: "8895e7fdffff",
        0x4FF333: "83c101",
        0x4FF336: "898d48fdffff",
        0x4FFF08: "e8e325f2ff",
        0x4FFF0D: "8b00",
        0x4FFF23: "e878e3f7ff",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected macro binding/editor-limit instruction")
    bodies = [
        (0x482B50, 0x482CB7, "a500c60fdadb7cd3597d3c340163afa59f717d453bb4ef9575b8dc2166b94fe3"),
        (0x422750, 0x4227A2, "d5a8fc88c24cd429e7410ca9c8123942923348f892ad34841b5e0166b73aab57"),
        (0x45E370, 0x45E389, "364eca2d7f007a6a7a24fde5637c6b38bb192aba1112b5e05c34db9df953a523"),
        (0x4B4F90, 0x4B51F2, "d7720114989e85701cd580690be6a873803b6ff2d78ff3f3387983a2052a71ab"),
    ]
    for start, end, expected in bodies:
        if hashlib.sha256(pe.at(start, end-start)).hexdigest() != expected:
            raise ValueError("Unexpected macro append, alias-check or UI callback body")
    for address, value in [(0x73AB8C, "macro_action_list"), (0x74ACE4, "message_text_27")]:
        raw = (value + "\0").encode("utf-16le")
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected macro list/error resource string")
    return {"instructionChecks": len(checks),
            "functionBodies": [{"method": hex(a), "endExclusive": hex(b), "SHA256": h} for a,b,h in bodies],
            "bindingCollection": {"sender": "0x4ff710", "append": "0x482b50",
                                  "value": "ActionLinkIndex", "deduplicatesEqualActionIndices": False,
                                  "aliasCheck": "0x422750 compares source pointer to vector begin/end, not index values",
                                  "serializationLookup": "0x4fff08 -> 0x4fff23",
                                  "keyReference": "0x4fefb0 key sender uses a separate ordinal, increments once per macro binding",
                                  "sameActionOnTwoKeys": "Two collected entries and two serialized records; unbound ActionInfo macros are not collected."},
            "editorEventLimit": {"setup": "0x4f8399..0x4f83bc", "setter": "0x45e370",
                                 "setupVirtualOffset": "0x260", "setupMethod": "0x4f7d20",
                                 "member": "macroControl+0x9dc",
                                 "formula": "trunc((byte(device+0x1dfa)*128 - 22) / 4)",
                                 "knownCapacityByte": 24, "knownCapacityEventLimit": 762,
                                 "oneRecorderCheck": "0x453c78 compares the configured limit to macro_action_list count",
                                 "exhaustionMessage": "0x0c1b with wParam=0,lParam=0 -> 0x4b4f90 -> message_text_27"},
            "hardwareWriteAuthorized": False,
            "limits": "Static named official paths. Editor per-macro limit is separate from total bound-record byte capacity. Does not establish firmware execution of 762 events or authorize expanded writes. CherryMac currently uses a shared library and 32/256 policy; migration of existing profiles requires explicit compatibility handling."}


def inspect_macro_mouse_search_bounds(pe):
    """Check named mouse-table search bounds and separate toolbar forwarding."""
    checks = {
        0x457C3A: "83bd8cf7ffff06", 0x457C41: "0f8d13010000",
        0x457C4E: "0fb78230df7b00",
        0x459194: "83bd8cf7ffff06", 0x45919B: "0f8d13010000",
        0x4591A8: "0fb78230df7b00",
        0x45A774: "83bd8cf7ffff06", 0x45A77B: "0f8d13010000",
        0x45A788: "0fb78230df7b00",
        0x45BF86: "83bd9cf9ffff06", 0x45BF9A: "0fb79130df7b00",
        0x45C902: "8b0d28df7b00", 0x45C908: "83e909",
        0x45C90B: "398d04f8ffff", 0x45C911: "0f8dc5040000",
        0x5C64CC: "817b040a020000", 0x5C64D3: "754a",
        0x5C64EF: "ff15a0be6e00", 0x5C64FF: "ff730c",
        0x5C6508: "ff7308", 0x5C650B: "ff7304",
        0x5C6511: "ff15a0be6e00",
    }
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if pe.at(address, len(raw)) != raw:
            raise ValueError("Unexpected macro mouse-table or toolbar instruction")
    if pe.pointer(0x7BDF28) != 15 or pe.at(0x7BDF30 + 14 * 6, 6) != bytes.fromhex("0a0212000000"):
        raise ValueError("Unexpected mouse-table count or wheel row")
    table, target = 0x6FD11C, 0x5C64BF
    if pe.class_name(table) != ".?AVCMFCToolBarComboBoxEdit@@" or pe.pointer(table + 0x10C) != target:
        raise ValueError("Unexpected toolbar wheel-forwarding class")
    digest = hashlib.sha256(pe.at(target, 0x5C6784 - target)).hexdigest()
    if digest != "41f6151bc83fc259a3c20aea8c6fcbee3ee921f8bc4523da6572fc3cb8c6d0f3":
        raise ValueError("Unexpected toolbar wheel-forwarding body")
    name = b"SendMessageW\0"
    if pe.at(pe.base + pe.pointer(0x6EBEA0) + 2, len(name)) != name:
        raise ValueError("Unexpected toolbar forwarding import")
    return {"instructionChecks": len(checks), "tableCount": 15,
            "wheelRow": {"index": 14, "message": "0x020a", "type": 0, "button": 0},
            "recorderSearchLimits": {hex(a): 6 for a in [0x457C3A, 0x459194, 0x45A774, 0x45BF86]},
            "manualSearchLimit": {"method": "0x45c840", "comparison": "0x45c90b", "countExpression": "15 - 9", "count": 6},
            "toolbarForwarding": {"class": "CMFCToolBarComboBoxEdit", "vtable": hex(table),
                                  "virtualOffset": "0x10c", "method": hex(target),
                                  "endExclusive": "0x5c6784", "functionSHA256": digest,
                                  "message": "0x020a", "import": "SendMessageW",
                                  "conclusion": "The named wheel handler forwards window messages; its class is a Windows toolbar edit control, not the target macro control or keyboard device."},
            "hardwareWriteAuthorized": False,
            "limits": "These named basic-button table loops do not select row 14; X-button and other branches remain separate. Classifies one wheel forwarding handler, not all indirect paths or firmware capability. No wheel event encoding or new write permission inferred."}


def inspect_macro_ui(pe, skin):
    checks = {
        0x4893BF: "6814a57500",  # MacroSetControlUI class comparison
        0x4893D0: "7513",        # skip when class does not match
        0x4893D2: "68b0a67500",  # MacroControl.xml path
        0x4893DD: "ff15f8b06e00",
        0x4921EF: "6810c67500",  # macro_action_menu.xml path
        0x45BF86: "83bd9cf9ffff06",  # search first six mouse rows
        0x45C0A2: "83bd9cf9ffff06",
        0x45C0AF: "817d080b020000",  # X button down
        0x45C0B8: "817d080c020000",  # X button up
        0x45C0BF: "0f8589020000",    # other messages -> cleanup 0x45c34e
    }
    for address, encoded in checks.items():
        if pe.at(address, len(bytes.fromhex(encoded))) != bytes.fromhex(encoded):
            raise ValueError("Unexpected macro UI/recording instruction")
    for address, value in [(0x75A514, "MacroSetControlUI"),
                           (0x75A6B0, r"XML\CustomControlXML\MacroControl.xml"),
                           (0x75C610, r"XML\Menus\macro_action_menu.xml")]:
        expected = (value + "\0").encode("utf-16le")
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected macro class/resource string")
    table = pe.at(0x7BDF30, 15 * 6)
    rows = [list(struct.unpack("<HBBBB", table[index:index + 6])) for index in range(0, len(table), 6)]
    if [row[0] for row in rows[:10]] != [0x201, 0x202, 0x204, 0x205, 0x207, 0x208, 0x20B, 0x20C, 0x20B, 0x20C] or rows[14] != [0x20A, 0x12, 0, 0, 0]:
        raise ValueError("Unexpected common mouse action table")
    resources = inspect_macro_resources(skin)
    return {**resources, "factoryBranch": "0x4893bf", "menuResourceUse": "0x4921ef",
            "recorderEntry": "0x45bc40", "instructionChecks": len(checks),
            "commonTableRows": rows, "wheelAcceptedByTrackedRecorder": False,
            "limits": "Static selected resource and one recorder branch; not proof against all indirect/hidden paths or firmware wheel capability"}


def inspect(path, skin=None, macro_ui=False, ui_dll=None, osconf_dll=None, defaults_dir=None):
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
        0x50C49A: "8a4908",
        0x4DC340: "c64405bc07",       # default keymap read command
        0x4FC2F4: "e8f76e0000",       # builds logical matching table
        0x50325F: "837df87e",         # 126 logical entries
        0x5033CE: "390c85c8c67600",   # match against reference dword triple
        0x5033EA: "390495ccc67600",
        0x503406: "39148dd0c67600",
        0x503424: "8908",             # logical entry stores physical slot
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
    logical_bytes = pe.at(0x76C6C8, 126 * 3 * 4)
    logical_words = struct.unpack("<378I", logical_bytes)
    if any(word > 255 for word in logical_words):
        raise ValueError("Logical matching table has non-byte fields")
    logical_records = [list(logical_words[i:i + 3]) for i in range(0, 378, 3)]
    if len({tuple(row) for row in logical_records}) != 126 or logical_records[17] != [48, 146, 1]:
        raise ValueError("Unexpected logical matching table")
    interface_rows = []
    for start, end, destination, collection, secondary, ordinal, page, usage in [
        (0x4120B1, 0x412128, 0x83B148, 4, 0, 0x81, 0xFF1C, 0x92),
        (0x412147, 0x4121C1, 0x83B1E8, 3, 0xFF, 0x82, 0x0C, 1),
        (0x4121E0, 0x41225A, 0x83B288, 5, 0xFE, 0x83, 0xFF1C, 0x92),
    ]:
        words = initialized_words(pe, start, end, destination)
        if words != [0x046A, 0x01CE, 0, collection, 1, secondary, 0, page, usage, 1, ordinal]:
            raise ValueError("Unexpected target interface registration")
        interface_rows.append({"initializer": hex(start), "destination": hex(destination),
                               "words": words, "interfaceNumber": words[2], "collectionNumber": words[3],
                               "connectionSelector": words[4], "secondarySelector": words[5],
                               "usagePage": words[7], "usage": words[8]})
    interface_checks = {
        0x485CDD: "6818eb7700",  # path parser: &mi_
        0x485D2D: "6824eb7700",  # path parser: &col
        0x496BE3: "e838f1feff",  # collection parser to enumeration row +6
        0x496BF9: "e8d2f0feff",  # interface parser to enumeration row +4
        0x5447EC: "8d872c020000",  # HIDP_CAPS destination
        0x5447F5: "ff156cba6e00",  # HidP_GetCaps import
        0x496C74: "668b0dde358400",  # CAPS UsagePage -> row +0xe
        0x496C82: "668b15dc358400",  # CAPS Usage -> row +0x10
        0x4978BA: "668b8a90628300",  # registry +8 is connection selector
        0x4978C1: "66894808",       # copied into enumeration row +8
        0x4A05DB: "0fb75008",       # match selector, not Usage or Report ID
        0x4A05EA: "6a01",           # connection kind argument
        0x4A064D: "e8fea90600",     # raw connection entry
        0x50C45E: "0fb782e4190000", # reads CAPS max input report length
        0x49878D: "0fb74808",       # connection selector to dispatcher argument
        0x4987AC: "0fb7400a",       # secondary selector
        0x4987CB: "81bdd0fdfffffe000000",
        0x4987D5: "0f8460060000",   # FE -> 0x498e3b
        0x498E4C: "e84f6d0000",     # FE branch -> 0x49fba0
        0x49FBE1: "83e901",         # connection kind - 1 indexes switch
        0x49FBFD: "ff2495100a4a00", # dispatch table
    }
    for address, encoded in interface_checks.items():
        expected_bytes = bytes.fromhex(encoded)
        if pe.at(address, len(expected_bytes)) != expected_bytes:
            raise ValueError("Unexpected interface selection instruction")
    if wide_string(0x77EB18, 10) != "&mi_" or wide_string(0x77EB24, 10) != "&col":
        raise ValueError("Unexpected HID path parser tokens")
    if pe.pointer(0x4A0A10) != 0x4A04C6:
        raise ValueError("Unexpected raw connection dispatch table")
    result = {
        "format": "CherryMacOfficialSettingsStaticAudit", "version": 46,
        "executableSHA256": digest, "method": "PE32 pointer and RTTI inspection; no execution or HID",
        "deviceClass": pe.class_name(device), "profileClass": pe.class_name(profile),
        "deviceVirtualTargets": {hex(k): hex(v) for k, v in expected.items()},
        "profileVirtualTargets": {"0x4": "0x47cac0", "0x8": "0x47c9a0"},
        "settingsStructureLayouts": inspect_settings_layouts(pe),
        "defaultConfigurationPath": inspect_default_configuration_path(pe, defaults_dir),
        "defaultMacroSemantics": inspect_default_macro_semantics(pe),
        "defaultFinalRefresh": inspect_default_final_refresh(pe),
        "defaultControlRefresh": inspect_default_control_refresh(pe),
        "defaultLightingControlUpdates": inspect_default_lighting_control_updates(pe, skin),
        "defaultModeVisibility": inspect_default_mode_visibility(pe),
        "defaultModeOptions": inspect_default_mode_options(pe, defaults_dir),
        "defaultKeyActionBranch": inspect_default_key_action_branch(pe),
        "settingsExternalPropertyBinding": inspect_external_property_binding(pe, osconf_dll),
        "settingsWindowNotifications": inspect_settings_window_messages(pe),
        "settingsChildPollingUpdate": inspect_settings_child_polling_message(pe),
        "settingsStatusPredicate": inspect_settings_status_predicate(pe),
        "systemDevicePaths": inspect_system_device_paths(pe),
        "settingsPostApplyDeviceList": inspect_settings_post_apply(pe),
        "parameterSenderLengths": inspect_parameter_sender_lengths(pe),
        "profileSelectionSend": inspect_profile_selection_send(pe),
        "otherParameterSenderClasses": inspect_other_parameter_sender_classes(pe),
        "pollingReloadAllowlist": inspect_polling_reload_allowlist(pe),
        "basicApplyRefresh": inspect_basic_apply_refresh(pe),
        "basicApplySave": inspect_basic_apply_save(pe),
        "profileFileStorage": inspect_profile_file_storage(pe),
        "macroMouseSearchBounds": inspect_macro_mouse_search_bounds(pe),
        "macroCapacitySender": inspect_macro_capacity_sender(pe),
        "macroBindingCollectionAndEditorLimit": inspect_macro_binding_collection_and_editor_limit(pe),
        "customLightingJSON": inspect_custom_lighting_json(pe),
        "modeRefreshMemoryPaths": inspect_refresh_mode_memory(pe),
        "targetParameterSelector": inspect_target_parameter_branch(pe),
        "profileSettingsReload": inspect_profile_settings_reload(pe),
        "currentDialogPollingDispatch": inspect_dialog_polling_dispatch(pe),
        "systemJSONGetter": "0x483100", "systemJSONSetter": "0x482e70",
        "systemWordOrder": ["Repeat", "RepeatDelay", "Key6Flag", "ReportSelectItem", "RFReportSelectItem", "WFlag", "WinFlag"],
        "textDispatch": {"eventRange": [0x700, 0x800], "upperBoundExclusive": True, "indexSubtract": 0x700, "deviceVirtualOffset": "0x32c", "target": "0x512de0", "instructionChecks": len(text_checks), "nonemptyKeyRecord": [161, 0, 0], "exportedActionTextFlag": 1},
        "modelFactory": {"xmlClass": "EevisionKeyboardDevice", "constructor": "0x4f6060", "vtable": "0x77f604", "model": 47, "vendorID": 0x046A, "productID": 0x01CE, "instructionChecks": len(model_checks)},
        "logicalMatchingTable": {"address": "0x76c6c8", "count": 126, "defaultKeymapReadCommand": 7, "rawSHA256": hashlib.sha256(logical_bytes).hexdigest(), "records": logical_records, "limits": "Requires actual factory keymap to map event values; not the JSON DefaultAssignment array"},
        "rawEventReader": {"connect": "0x50b050", "start": "0x50b5c0", "worker": "0x50c3d0", "connectionObjectOffset": "0x17b4", "copiedReportBytes": 9, "eventValueBytes": [1, 2], "registeredWindowsCollection": 5, "secondarySelector": 254, "reportID": "Requires descriptor correlation; not encoded in receiver"},
        "registeredInterfaces": {"rows": interface_rows, "instructionChecks": len(interface_checks),
                                 "rowOffsets": {"interfaceNumber": 4, "collectionNumber": 6,
                                                "connectionSelector": 8, "secondarySelector": 10,
                                                "usagePage": 14, "usage": 16},
                                 "limits": "Windows path collection numbers and registry selectors are not report IDs. Both vendor rows have the same usage pair; nine-byte copying is not a report-length assertion."},
        "limits": "Static factory and reader paths only; does not prove actual interface or report ID, USB setting writes, text trigger execution or persistence",
    }
    if skin is not None:
        result["modelResource"] = inspect_model_resources(skin)
        result["settingsResource"] = inspect_settings_resources(skin)
        result["basicSettingsDialog"] = inspect_basic_settings_dialog(skin)
    if ui_dll is not None:
        result["settingsUIControlActions"] = inspect_settings_ui_control_actions(ui_dll)
    if macro_ui:
        if skin is None:
            raise ValueError("Macro UI audit requires --skin")
        result["macroUI"] = inspect_macro_ui(pe, skin)
    return result



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", help="Local CHERRY-Utility-Software.exe; it will only be read")
    parser.add_argument("--skin", help="Optional extracted Skin directory; verifies target model resource without copying it")
    parser.add_argument("--macro-ui", action="store_true", help="Also audit the target macro resource, menu and recorder branch; requires --skin")
    parser.add_argument("--ui-dll", help="Optional extracted DuiLib.dll; read-only control action audit")
    parser.add_argument("--osconf-dll", help="Optional extracted x86/vista/osConfLib.dll; read-only request table audit")
    parser.add_argument("--defaults-dir", help="Optional extracted DefaultData directory; inspect five model47 template rows without writing them")
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.executable, args.skin, args.macro_ui, args.ui_dll, args.osconf_dll, args.defaults_dir), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error, ET.ParseError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
