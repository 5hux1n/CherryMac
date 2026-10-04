import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('lighting_audit', Path(__file__).with_name('inspect-lighting-sequence.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MemoryPE:
    base = 0x400000

    def __init__(self):
        self.memory = {}
        self.put(0x3C, struct.pack('<I', 0x80))
        self.put(0x94, struct.pack('<H', 112))
        self.put(0x100, struct.pack('<II', 0x1000, 100))
        self.put(0x401000, struct.pack('<5I', 0x1200, 0, 0, 0x1300, 0x2EBCF4))
        self.put(0x401200, struct.pack('<II', 0x1320, 0))
        self.put(0x401300, b'KERNEL32.dll\0')
        self.put(0x401320, b'\0\0Sleep\0')
        self.put(0x401014, struct.pack('<5I', 0x1400, 0, 0, 0x1500, 0x2EBA68))
        self.put(0x401400, struct.pack('<II', 0x1520, 0))
        self.put(0x401500, b'HID.DLL\0')
        self.put(0x401520, b'\0\0HidD_GetAttributes\0')
        self.put(0x401028, struct.pack('<5I', 0x1600, 0, 0, 0x1300, 0x2EBC90))
        self.put(0x40103C, struct.pack('<5I', 0x1610, 0, 0, 0x1300, 0x2EBD04))
        self.put(0x401600, struct.pack('<II', 0x1620, 0))
        self.put(0x401610, struct.pack('<II', 0x1640, 0))
        self.put(0x401620, b'\0\0CreateFileW\0')
        self.put(0x401640, b'\0\0CloseHandle\0')
        for address, encoded in audit.IDENTITY_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, encoded in audit.TRANSPORT_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        self.put(0x76D8B0, 'DeviceProfileItem\0'.encode('utf-16le'))
        self.put(0x745750, b'LightOpenFlag\0')
        self.put(0x77F604 + 0x2BC, struct.pack('<I', 0x500790))
        for address, encoded in audit.CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, encoded in audit.SETTINGS_COVERAGE_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, encoded in audit.BEGIN_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, encoded in audit.BEGIN_STATE_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))

        self.put(0x77F604 + 0x2C4, struct.pack('<I', 0x501190))
        for address, encoded in audit.COLOR_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, encoded in audit.BRIGHTNESS_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, key in audit.COLOR_JSON_KEYS.items():
            self.put(address, key.encode() + b'\0')
        self.put(0x74A350, bytes([0, 65, 135, 195, 255]))
        for address, encoded in audit.MAPPING_CHECKS.items():
            self.put(address, bytes.fromhex(encoded))
        for address, load, compare, jump in audit.PREDICATES:
            self.put(address - 7, bytes.fromhex(load))
            self.put(address, bytes.fromhex(compare))
            self.put(address + len(bytes.fromhex(compare)), bytes.fromhex(jump))

    def put(self, address, data):
        for i, byte in enumerate(data):
            self.memory[address + i] = byte

    def at(self, address, size):
        return bytes(self.memory.get(address + i, 0) for i in range(size))

    take = at

    def u32(self, address):
        return struct.unpack('<I', self.at(address, 4))[0]

    pointer = u32


class LightingAuditTests(unittest.TestCase):
    def test_settings_fields_built_but_not_in_target_parameter_writes(self):
        result = audit.audit_settings_coverage(MemoryPE())
        self.assertEqual(result['workingBufferFields'], [
            {'field':'ReportSelectItem','structByteOffset':6,'parameterByte':53},
            {'field':'RFReportSelectItem','structByteOffset':8,'parameterByte':54}])
        self.assertEqual(result['fieldsOutsideSelectedWrites'], ['ReportSelectItem','RFReportSelectItem'])
        self.assertEqual(result['sentParameterBytes'], list(range(9))+[21,24])
        for address in audit.SETTINGS_COVERAGE_CHECKS:
            pe = MemoryPE();pe.put(address, bytes([pe.at(address,1)[0]^1]))
            with self.assertRaises(ValueError):audit.audit_settings_coverage(pe)

    def test_begin_guard_is_selected_communication_open_state(self):
        result = audit.audit_begin_state(MemoryPE())
        self.assertEqual(result['communicationOffset'] + result['fieldInCommunication'], result['fieldInDevice'])
        self.assertEqual(result['communicationOffset'] + result['openWrapperOffset'], result['openWrapperInDevice'])
        self.assertEqual(result['initialValue'], 0)
        for address in (0x53F685, 0x4D9269, 0x498AFB, 0x498B07, 0x545290, 0x5452BD, 0x499277):
            pe = MemoryPE();pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'begin state instruction'):
                audit.audit_begin_state(pe)
        for address in (0x401622, 0x401642):
            pe = MemoryPE();pe.put(address, b'WrongName\0')
            with self.assertRaisesRegex(ValueError, 'Begin state import'):
                audit.audit_begin_state(pe)

    def test_begin_report_and_status_checks(self):
        result = audit.audit_begin(MemoryPE())
        self.assertEqual(result['headerBytes4Through7'], [0, 0, 0, 0])
        for address in (0x4D9F01, 0x4D9F39, 0x4DA053, 0x4DA09C):
            pe = MemoryPE();pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'begin instruction'):
                audit.audit_begin(pe)

    def test_separate_transport_word_and_selected_bank_caller(self):
        result = audit.audit_transport_and_bank(MemoryPE())
        self.assertEqual(result['registryTrailingWord']['initialValue'], 0)
        self.assertEqual(result['registryTrailingWord']['rowOffset'], 156)
        self.assertEqual(result['zeroSelectorReports']['parameterFlag'], 85)
        self.assertEqual(result['zeroSelectorReports']['finishCommand'], 2)
        self.assertEqual(result['oneSelectorReports']['colorCommand'], 139)
        for address in (0x41213C, 0x49832F, 0x4DE67A, 0x4B197F, 0x42B4BA, 0x500800, 0x433AB9):
            pe = MemoryPE()
            pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'transport/bank instruction'):
                audit.audit_transport_and_bank(pe)

    def test_product_id_structure_copy_and_branch(self):
        result = audit.audit_device_identity(MemoryPE())
        self.assertEqual(result['attributeImport'], 'HID.DLL!HidD_GetAttributes')
        self.assertEqual(result['targetProductID'], 462)
        self.assertEqual(result['targetParameterBranch'], '0x5010d8')
        for address in (0x496C6D, 0x49828D, 0x5435D4, 0x42911D):
            pe = MemoryPE()
            pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'device identity instruction'):
                audit.audit_device_identity(pe)
        pe = MemoryPE()
        pe.put(0x401522, b'WrongAttributeName\0')
        with self.assertRaisesRegex(ValueError, 'HidD_GetAttributes'):
            audit.audit_device_identity(pe)

    def test_fallback_sequence_and_delay_import(self):
        result = audit.audit_sequence(MemoryPE())
        self.assertEqual([r['relativeOffset'] for r in result['parameterWrites']], [0, 21, 24])
        self.assertEqual([r['length'] for r in result['parameterWrites']], [9, 1, 1])
        self.assertEqual(result['finish']['delayBeforeExchangeMilliseconds'], 10)
        self.assertEqual(result['finish']['delayImport'], 'KERNEL32.dll!Sleep')
        self.assertEqual(result['tailField']['jsonKey'], 'LightOpenFlag')
        self.assertEqual(result['tailField']['getterStructByte'], 11)

    def test_selector_groups_and_distinct_ce_values(self):
        pe = MemoryPE()
        expected = {0x1CE: '0x5010d8', 0xCE: '0x500bb0', 0xB4: '0x500bef',
                    0x1B2: '0x500d16', 0x1D7: '0x500daf',
                    0x1DE: '0x500f2a', 0x1FB: '0x50101f'}
        for selector, branch in expected.items():
            with self.subTest(selector=selector):
                self.assertEqual(audit.audit_selector(pe, selector)['selectedBranch'], branch)
        self.assertEqual(audit.audit_selector(pe)['predicateCount'], 38)
        for selector in (-1, 65536, True):
            with self.assertRaisesRegex(ValueError, 'unsigned word'):
                audit.audit_selector(pe, selector)

    def test_changed_selector_load_and_jump_rejected(self):
        for address in (0x500ADE, 0x501019):
            pe = MemoryPE()
            pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'selector instruction'):
                audit.audit_sequence(pe)

    def test_color_layout_and_static_call_order(self):
        result = audit.audit_colors(MemoryPE())
        self.assertEqual(result['method'], '0x501190')
        self.assertEqual(result['helperReport']['flagByte7'], 0)
        self.assertEqual(result['helperReport']['offsetBytesLittleEndian'], [5, 6])
        self.assertEqual(result['conditionalBank']['otherBankBase'], 'caller argument << 9')
        self.assertEqual(result['observedStaticCaller']['order'][0], 'parameter virtual +0x2bc')
        self.assertIn('fourthColorByte', result['buffer']['rgb'])

    def test_changed_color_bank_checksum_and_caller_rejected(self):
        for address in (0x5011B7, 0x5018FA, 0x4DCF95, 0x4B19C1):
            pe = MemoryPE()
            pe.put(address, b'\x90')
            with self.assertRaisesRegex(ValueError, 'color instruction'):
                audit.audit_sequence(pe)
        pe = MemoryPE()
        pe.put(0x77F604 + 0x2C4, struct.pack('<I', 0x500790))
        with self.assertRaisesRegex(ValueError, 'color virtual'):
            audit.audit_colors(pe)

    def test_brightness_conversion_chain(self):
        result = audit.audit_brightness(MemoryPE())
        self.assertEqual(result['colorByteOrder'], ['Red', 'Green', 'Blue', 'Alpha'])
        self.assertEqual(result['coefficientsForLevels0Through4'], [0, 65, 135, 195, 255])
        self.assertEqual(result['loadingPaths'], ['0x505900', '0x5059f0'])

    def test_changed_brightness_table_field_and_json_key_rejected(self):
        for address in (0x74A352, 0x505A7C, 0x748FB8):
            pe = MemoryPE()
            pe.put(address, bytes([pe.at(address, 1)[0] ^ 1]))
            with self.assertRaises(ValueError):
                audit.audit_sequence(pe)

    def test_separate_led_mapping_source_and_disabled_positions(self):
        result = audit.audit_mapping(MemoryPE())
        self.assertEqual(result['ledIndices']['command'], '1b / 9b')
        self.assertEqual(result['disabledLogicalColors'], [122, 123, 124])
        self.assertIn('ledIndices[keyMapping]', result['colorMapping'])
        for address in (0x4DC8D7, 0x50348C, 0x503508):
            pe = MemoryPE()
            pe.put(address, bytes([pe.at(address, 1)[0] ^ 1]))
            with self.assertRaisesRegex(ValueError, 'LED mapping instruction'):
                audit.audit_sequence(pe)

    def test_changed_instruction_rejected(self):
        pe = MemoryPE()
        pe.put(0x50113C, bytes.fromhex('83c019'))
        with self.assertRaisesRegex(ValueError, 'instruction'):
            audit.audit_sequence(pe)

    def test_wrong_import_and_invalid_bounds_rejected(self):
        pe = MemoryPE()
        pe.put(0x401322, b'Other\0')
        with self.assertRaisesRegex(ValueError, 'Sleep'):
            audit.audit_sequence(pe)
        pe = MemoryPE()
        pe.put(0x100, struct.pack('<II', 0x1000, 1))
        with self.assertRaisesRegex(ValueError, 'bounds'):
            audit.import_at(pe, 0x6EBCF4)
        pe = MemoryPE()
        pe.put(0x401200, struct.pack('<I', 0x80000001))
        with self.assertRaisesRegex(ValueError, 'named'):
            audit.import_at(pe, 0x6EBCF4)

    def test_unrecognized_executable_rejected_before_address_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'unknown.exe'
            path.write_bytes(b'MZ synthetic')
            with self.assertRaisesRegex(ValueError, 'hash differs'):
                audit.inspect(path)


if __name__ == '__main__':
    unittest.main()
