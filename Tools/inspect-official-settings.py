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


def inspect(path, skin=None, macro_ui=False):
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
        "format": "CherryMacOfficialSettingsStaticAudit", "version": 7,
        "executableSHA256": digest, "method": "PE32 pointer and RTTI inspection; no execution or HID",
        "deviceClass": pe.class_name(device), "profileClass": pe.class_name(profile),
        "deviceVirtualTargets": {hex(k): hex(v) for k, v in expected.items()},
        "profileVirtualTargets": {"0x4": "0x47cac0", "0x8": "0x47c9a0"},
        "systemDevicePaths": inspect_system_device_paths(pe),
        "profileSettingsReload": inspect_profile_settings_reload(pe),
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
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.executable, args.skin, args.macro_ui), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error, ET.ParseError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
