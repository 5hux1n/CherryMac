#!/usr/bin/env python3
"""Read-only PE/RTTI audit for the analyzed Utility executable; never runs it."""
import argparse
import hashlib
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


    }
    for address, encoded in checks.items():
        expected = bytes.fromhex(encoded)
        if pe.at(address, len(expected)) != expected:
            raise ValueError("Unexpected default configuration instruction")
    methods = {0x2A0: 0x4FEFB0, 0x290: 0x4F9320, 0x2A4: 0x4FE970, 0x2BC: 0x500790, 0x2C4: 0x501190}
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
            selected = row.get("LightInfo", {}).get("SelectItem")
            if type(selected) is not int or not 0 <= selected < len(modes):
                raise ValueError("Invalid default lighting index")
            canonical = json.dumps(row, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
            rows.append({"file": path.name, "fileSHA256": hashlib.sha256(data).hexdigest(),
                         "modelArrayIndex": position, "modelRowSHA256": hashlib.sha256(canonical).hexdigest(),
                         "keyCount": len(keys), "templateIdentity": row.get("DeviceBasicInfo"),
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
    checks = {
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
        "format": "CherryMacOfficialSettingsStaticAudit", "version": 18,
        "executableSHA256": digest, "method": "PE32 pointer and RTTI inspection; no execution or HID",
        "deviceClass": pe.class_name(device), "profileClass": pe.class_name(profile),
        "deviceVirtualTargets": {hex(k): hex(v) for k, v in expected.items()},
        "profileVirtualTargets": {"0x4": "0x47cac0", "0x8": "0x47c9a0"},
        "settingsStructureLayouts": inspect_settings_layouts(pe),
        "defaultConfigurationPath": inspect_default_configuration_path(pe, defaults_dir),
        "settingsExternalPropertyBinding": inspect_external_property_binding(pe, osconf_dll),
        "settingsWindowNotifications": inspect_settings_window_messages(pe),
        "settingsChildPollingUpdate": inspect_settings_child_polling_message(pe),
        "settingsStatusPredicate": inspect_settings_status_predicate(pe),
        "systemDevicePaths": inspect_system_device_paths(pe),
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
