import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("settings_audit", Path(__file__).with_name("inspect-official-settings.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def fixture():
    data = bytearray(0x400)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, 0x14C, 1)
    struct.pack_into("<H", data, 0x94, 96)
    struct.pack_into("<H", data, 0x98, 0x10B)
    struct.pack_into("<I", data, 0xB4, 0x400000)
    struct.pack_into("<4I", data, 0x100, 0x200, 0x1000, 0x200, 0x200)
    struct.pack_into("<I", data, 0x220, 0x401060)
    struct.pack_into("<I", data, 0x224, 0x12345678)
    struct.pack_into("<I", data, 0x26C, 0x4010A0)
    name = b".?AVSynthetic@@\0"
    data[0x2A8:0x2A8 + len(name)] = name
    return bytes(data)


class AuditTests(unittest.TestCase):
    def test_settings_notifications_verify_api_and_window_arguments(self):
        class MemoryPE:
            base = 0x400000
            def __init__(self):
                self.code = {a: bytes.fromhex(v) for a,v in audit.SETTINGS_WINDOW_MESSAGE_CHECKS.items()}
                self.code[0x401002] = b"SendMessageW\0"
            def at(self,address,size):
                return self.code[address][:size]
            def pointer(self,address):
                assert address == 0x6EBEA0
                return 0x1000
        result = audit.inspect_settings_window_messages(MemoryPE())
        self.assertEqual(result['apiImport'], 'SendMessageW')
        self.assertEqual(result['relay']['argumentsPreserved'], ['wParam', 'lParam'])
        for address in [0x4FDD94,0x4FDDD8,0x493B9D,0x493BA1,0x401002]:
            bad=MemoryPE();value=bytearray(bad.code[address]);value[0]^=1;bad.code[address]=bytes(value)
            with self.assertRaises(ValueError):audit.inspect_settings_window_messages(bad)

    def test_settings_layouts_reject_changed_copy_branch_and_namespace(self):
        class MemoryPE:
            def __init__(self):
                self.code = {a: bytes.fromhex(v) for a, v in audit.SETTINGS_LAYOUT_CHECKS.items()}
                self.code.update({a: (name + "\0").encode("ascii")
                                  for a, name in audit.SETTINGS_LAYOUT_NAMES.items()})
            def at(self, address, size):
                return self.code[address][:size]
        result = audit.inspect_settings_layouts(MemoryPE())
        self.assertEqual(result['keyboard']['structureBytes'], 14)
        self.assertEqual(result['otherSettings']['structureBytes'], 32)
        self.assertEqual(len(result['otherSettings']['fieldNames']), 8)
        for address in [0x483115, 0x48315C, 0x4832CA, 0x481BD5, 0x4EB7B6, 0x7465A0]:
            bad = MemoryPE(); value = bytearray(bad.code[address]); value[0] ^= 1
            bad.code[address] = bytes(value)
            with self.assertRaises(ValueError):
                audit.inspect_settings_layouts(bad)

    def test_current_dialog_dispatch_and_named_calls(self):
        class MemoryPE:
            def __init__(self):
                self.code = {a: bytes.fromhex(v) for a, v in audit.DIALOG_POLLING_CHECKS.items()}
                self.code.update({a: b"\xe8" + struct.pack("<i", target-a-5)
                                 for a, (target, _) in audit.SETTINGS_DIRECT_CALLS.items()})
                self.code.update({a: (name+"\0").encode("utf-16-le") for a, name in {
                    0x729B90: "polling_rate_option_4", 0x729BBC: "polling_rate_option_5",
                    0x729BE8: "polling_rate_option_6", 0x729C14: "report_layout"}.items()})
            def at(self, address, size):
                return self.code[address][:size]
        pe = MemoryPE();result = audit.inspect_dialog_polling_dispatch(pe)
        self.assertNotIn(result['targetProduct'], result['specialPollingSetupProducts'])
        self.assertEqual(result['targetSetupArguments'], [False, False])
        self.assertEqual(len(result['namedDirectCalls']), 11)
        for address in [0x4AEFBA, 0x4AF145, 0x42938F, 0x729B90, 0x4F888E]:
            bad = MemoryPE();value = bytearray(bad.code[address]);value[-1] ^= 1;bad.code[address] = bytes(value)
            with self.assertRaises(ValueError):audit.inspect_dialog_polling_dispatch(bad)

    def test_profile_reload_rejects_changed_call_and_virtual_target(self):
        class MemoryPE:
            def __init__(self):
                self.code = {a: bytes.fromhex(v) for a, v in audit.PROFILE_SETTINGS_RELOAD_CHECKS.items()}
                self.targets = {0x77F604 + 0x28C: 0x4FAA50, 0x77F604 + 0x2CC: 0x4FA240,
                                0x77F604 + 0x2E8: 0x501D70, 0x77F604 + 0x2EC: 0x540C60}
                self.code.update({0x7764F8: ('device_function_switch\0').encode('utf-16-le'),
                                  0x776528: ('device_key_function_switch\0').encode('utf-16-le')})
            def at(self, address, size):
                return self.code[address][:size]
            def pointer(self, address):
                return self.targets[address]
        pe = MemoryPE()
        result = audit.inspect_profile_settings_reload(pe)
        self.assertEqual(result['followingVirtualOffsets'], ['0x300', '0x28c'])
        self.assertEqual(result['uiSelection']['deviceOffset'], '0x2114')
        pe.code[0x4F93E9] = bytes.fromhex('e800000000')
        with self.assertRaisesRegex(ValueError, 'reload instruction'):
            audit.inspect_profile_settings_reload(pe)
        pe = MemoryPE();pe.targets[0x77F604 + 0x28C] = 0x500790
        with self.assertRaisesRegex(ValueError, 'reload virtual target'):
            audit.inspect_profile_settings_reload(pe)

    def test_selected_dialog_polling_order_and_legacy_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'KbBasicSetWnd.xml'
            body = ''.join('<Option style="a" style="b" name="polling_rate_option_' + str(i) + '" text="' + str(hz) + 'Hz" visible="' + ('true' if i<4 else 'false') + '"/>' for i,hz in enumerate([125,250,500,1000,2000,4000,8000]))
            source = '<Window><!--<Option name="polling_rate_option_0" text="1000Hz"/>-->' + body + '</Window>';path.write_text(source)
            result = audit.inspect_basic_settings_dialog(directory)
            self.assertEqual([p['labelHz'] for p in result['pollingControls'][:4]], [125,250,500,1000])
            for text in [source.replace('text="125Hz"', 'text="1000Hz"'),source.replace('</Window>', '<Option name="winlockflag_option"/></Window>')]:
                path.write_text(text)
                with self.assertRaises(ValueError):audit.inspect_basic_settings_dialog(directory)

    def test_selected_system_paths_reject_altered_fields_or_calls(self):
        class MemoryPE:
            def __init__(self):
                self.code = {a: bytes.fromhex(v) for a, v in audit.SYSTEM_DEVICE_CHECKS.items()}
            def at(self, address, size):
                return self.code[address][:size]
        pe = MemoryPE()
        result = audit.inspect_system_device_paths(pe)
        self.assertFalse(result['selectedReadbackBranchIncludesTarget'])
        self.assertNotIn(0x1CE, result['selectedReadbackBranchProducts'])
        for address in audit.SYSTEM_DEVICE_CHECKS:
            bad = MemoryPE();value = bytearray(bad.code[address]);value[-1] ^= 1;bad.code[address] = bytes(value)
            with self.assertRaisesRegex(ValueError, 'system settings device'):
                audit.inspect_system_device_paths(bad)

    def test_target_settings_resources_and_altered_ranges(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory);path = root / 'XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml'
            path.parent.mkdir(parents=True)
            content = '<Window><EevisionKeyboardDevice>'
            content += ''.join('<Option name="' + name + '"/>' for name in ['winlockflag_option', 'wflag_option', '6flag_option'])
            content += '<Slider name="repeat_delay_check_" min="0" max="31"/>'
            content += ''.join('<Option name="polling_rate_option_' + str(i) + '" normalimage="common/' + str(hz) + 'HZ.png"/>' for i,hz in enumerate([1000,500,250,125]))
            content += ''.join('<Option name="repeat_delay_check_' + str(i) + '"/>' for i in range(4))
            content += '</EevisionKeyboardDevice></Window>';path.write_text(content)
            self.assertEqual(audit.inspect_settings_resources(root)['repeatSliderRange'], [0,31])
            for text in [content.replace('max="31"', 'max="32"'),content.replace('1000HZ', '8000HZ'),content.replace('name="wflag_option"', 'name="6flag_option"')]:
                path.write_text(text)
                with self.assertRaises(ValueError):audit.inspect_settings_resources(root)

    def test_macro_resource_selection_and_unexpected_event_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
            control = root / "XML/CustomControlXML/MacroControl.xml"
            menu = root / "XML/Menus/macro_action_menu.xml"
            for path in [device, control, menu]:
                path.parent.mkdir(parents=True, exist_ok=True)
            device.write_text('<Window><EevisionKeyboardDevice><MacroSetControlUI/></EevisionKeyboardDevice></Window>')
            control.write_text('<Window><MacroControl style="a" style="b">' + ''.join(
                '<Edit name="' + name + '"/>' for name in
                ['macro_action_list', 'macro_fixed_time_edit', 'macro_check_mouse', 'action_text_richedit']) + '</MacroControl></Window>')
            body = ''.join('<MenuElement text="mouse_key_' + name + '">' + ''.join(
                '<MenuElement name="' + name + suffix + '"/>' for suffix in ['_down', '_up', '_click']) + '</MenuElement>'
                for name in ['left', 'middle', 'right', 'forward', 'back'])
            menu.write_text('<Window><MenuElement text="macro_btn_shubiao">' + body + '</MenuElement></Window>')
            result = audit.inspect_macro_resources(root)
            self.assertEqual(result['manualMouseButtons'], ['left', 'middle', 'right', 'forward', 'back'])
            self.assertEqual(len(result['resourceSHA256']), 3)
            menu.write_text(menu.read_text().replace('mouse_key_back', 'mouse_wheel'))
            with self.assertRaisesRegex(ValueError, 'mouse macro menu'):
                audit.inspect_macro_resources(root)
            device.write_text('<Window><EevisionKeyboardDevice/></Window>')
            with self.assertRaisesRegex(ValueError, 'MacroSetControlUI'):
                audit.inspect_macro_resources(root)

    def test_rtti_and_virtual_pointer(self):
        pe = audit.PE32(fixture())
        self.assertEqual(pe.class_name(0x401024), ".?AVSynthetic@@")
        self.assertEqual(pe.pointer(0x401024), 0x12345678)

    def test_file_and_section_boundaries(self):
        for data in [b"MZ", fixture()[:-1]]:
            with self.assertRaises(ValueError):
                audit.PE32(data)
        pe = audit.PE32(fixture())
        for address, size in [(0x4011FF, 2), (0x401200, 1), (0x3FFFFF, 4)]:
            with self.assertRaises(ValueError):
                pe.at(address, size)

    def test_reject_wrong_architecture_and_invalid_section_count(self):
        for offset, value in [(0x84, 0x8664), (0x86, 0), (0x86, 97)]:
            data = bytearray(fixture())
            struct.pack_into("<H", data, offset, value)
            with self.assertRaises(ValueError):
                audit.PE32(data)

    def test_model_resource_selection_and_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "XML/DeviceXml/keyboarddevice_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
            option = root / "XML/CustomControlXML/DeviceOption_MX_3_0S_FL_RGB_WIRELESS_POKEMON.xml"
            device.parent.mkdir(parents=True); option.parent.mkdir(parents=True)
            device.write_bytes(b' <?xml version="1.0"?><Window><EevisionKeyboardDevice/></Window>')
            option.write_bytes(b'<Window><Label name="device_select_name" text="MX 3.0S POKEMON WIRELESS"/></Window>')
            result = audit.inspect_model_resources(root)
            self.assertEqual((result["model"], result["productID"], result["resourceClass"]), (47, 462, "EevisionKeyboardDevice"))
            device.write_bytes(b'<Window><OtherKeyboardDevice/></Window>')
            with self.assertRaisesRegex(ValueError, "select"):
                audit.inspect_model_resources(root)
            device.write_bytes(b'<Window><EevisionKeyboardDevice/></Window>')
            option.write_bytes(b'<Window><Label name="device_select_name" text="another model"/></Window>')
            with self.assertRaisesRegex(ValueError, "display name"):
                audit.inspect_model_resources(root)

    def test_reject_unmatched_executable_before_version_specific_addresses(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.exe"
            path.write_bytes(fixture())
            with self.assertRaisesRegex(ValueError, "hash differs"):
                audit.inspect(path)

    def test_initializer_rejects_unknown_code_and_invalid_stores(self):
        destination = 0x830000
        constant = b"\xb8\x6a\x04\0\0"
        store = b"\x66\xa3" + struct.pack("<I", destination)
        cases = [b"\xb8", b"\xe8\0\0\0\0", store,
                 constant + b"\x66\xa3" + struct.pack("<I", destination + 22),
                 constant + store + store, constant + store]
        for code in cases:
            with self.subTest(code=code.hex()):
                data = bytearray(fixture())
                data[0x300:0x300 + len(code)] = code
                with self.assertRaises(ValueError):
                    audit.initialized_words(audit.PE32(bytes(data)), 0x401100,
                                            0x401100 + len(code), destination)


if __name__ == "__main__":
    unittest.main()
