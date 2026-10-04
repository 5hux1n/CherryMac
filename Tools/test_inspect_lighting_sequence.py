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
