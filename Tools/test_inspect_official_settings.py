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

    def test_reject_unmatched_executable_before_version_specific_addresses(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.exe"
            path.write_bytes(fixture())
            with self.assertRaisesRegex(ValueError, "hash differs"):
                audit.inspect(path)


if __name__ == "__main__":
    unittest.main()
