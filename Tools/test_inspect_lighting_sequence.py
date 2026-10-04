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
        self.put(0x100, struct.pack('<II', 0x1000, 40))
        self.put(0x401000, struct.pack('<5I', 0x1200, 0, 0, 0x1300, 0x2EBCF4))
        self.put(0x401200, struct.pack('<II', 0x1320, 0))
        self.put(0x401300, b'KERNEL32.dll\0')
        self.put(0x401320, b'\0\0Sleep\0')
        self.put(0x745750, b'LightOpenFlag\0')
        self.put(0x77F604 + 0x2BC, struct.pack('<I', 0x500790))
        for address, encoded in audit.CHECKS.items():
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
        for address in (0x5018FA, 0x4DCF95, 0x4B19C1):
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
