#!/usr/bin/env python3
"""Audit the supplied Utility's fallback lighting parameter sequence; no execution or HID."""
import argparse
import hashlib
import importlib.util
import json
import struct
from pathlib import Path

spec = importlib.util.spec_from_file_location('settings_audit', Path(__file__).with_name('inspect-official-settings.py'))
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)

CHECKS = {
    0x500BC0: '83ba840a000000', 0x500BC7: '7411', 0x500BD5: 'e8d692fdff',
    0x5010D8: '8b5508', 0x5010DB: 'c1e206', 0x5010DF: '6a09', 0x5010FA: 'e841c5fdff',
    0x501102: 'c1e006', 0x501105: '83c015', 0x501109: '6a01', 0x501124: 'e817c5fdff',
    0x501131: 'c64415bc01', 0x501139: 'c1e006', 0x50113C: '83c018', 0x501140: '6a01',
    0x50115B: 'e8e0c4fdff', 0x501160: '6a01', 0x50116E: 'e86d8ffdff',
    0x4DD675: 'c64415bc04', 0x4DD682: 'c6440dbc06', 0x4DD6C9: 'c64415bc55',
    0x4DD756: '034510', 0x4DD825: 'e88696ffff', 0x4DD846: 'e835bbffff',
    0x4DD895: '7507', 0x4DD8B4: '7507', 0x4DA140: 'c64415bc02',
    0x4DA256: '6a0a', 0x4DA258: 'ff15f4bc6e00', 0x4DA28B: 'e8f0f0ffff',
    0x500806: '8d8d4cffffff', 0x500819: 'e8c2a5f7ff',
    0x47AF54: '6850577400', 0x47AF5C: 'e87fcc0c00', 0x47AF63: 'e8e8c00c00', 0x47AF68: '8845cb',
    0x47B2E5: 'b90b000000', 0x47B2EA: '8d75c0', 0x47B2ED: '8b7d08', 0x47B2F0: 'f3a5', 0x47B2F2: '66a5', 0x47B2F4: 'a4',
    0x500A94: '8a8d57ffffff', 0x500A9A: '888d05ffffff', 0x500AB8: 'c68508ffffff01',
}


def cstring(pe, address):
    result = bytearray()
    for offset in range(256):
        byte = pe.at(address + offset, 1)[0]
        if byte == 0:
            return result.decode('ascii')
        result.append(byte)
    raise ValueError('Import name exceeds audit bounds')


def import_at(pe, slot):
    header = pe.u32(0x3C)
    optional = header + 24
    if struct.unpack('<H', pe.take(header + 20, 2))[0] < 112:
        raise ValueError('Missing import directory')
    rva, size = struct.unpack('<II', pe.take(optional + 104, 8))
    if not rva or not 20 <= size <= 1_000_000:
        raise ValueError('Invalid import directory bounds')
    for i in range(min(size // 20, 512)):
        original, _, _, name, first = struct.unpack('<5I', pe.at(pe.base + rva + i * 20, 20))
        if not any([original, name, first]):
            break
        if not name or not first:
            raise ValueError('Malformed import descriptor')
        for index in range(4096):
            thunk = pe.pointer(pe.base + (original or first) + index * 4)
            if not thunk:
                break
            if pe.base + first + index * 4 == slot:
                if thunk & 0x80000000:
                    raise ValueError('Expected named Sleep import')
                return cstring(pe, pe.base + name), cstring(pe, pe.base + thunk + 2)
        else:
            raise ValueError('Import thunk table exceeds audit bounds')
    raise ValueError('Delay import slot not found')


def audit_sequence(pe):
    if pe.pointer(0x77F604 + 0x2BC) != 0x500790:
        raise ValueError('Unexpected lighting virtual method')
    for address, encoded in CHECKS.items():
        value = bytes.fromhex(encoded)
        if pe.at(address, len(value)) != value:
            raise ValueError(f'Unexpected lighting instruction at {address:#x}')
    if cstring(pe, 0x745750) != 'LightOpenFlag':
        raise ValueError('Unexpected tail parameter JSON key')
    dll, function = import_at(pe, 0x6EBCF4)
    if dll.lower() != 'kernel32.dll' or function != 'Sleep':
        raise ValueError('Delay slot does not import KERNEL32 Sleep')
    return {
        'format': 'CherryMacStaticLightingSequence', 'version': 1,
        'method': '0x500790', 'branchStart': '0x5010d8', 'instructionChecks': len(CHECKS),
        'bankBase': 'caller argument << 6',
        'tailField': {'jsonKey': 'LightOpenFlag', 'getter': '0x47ade0', 'getterStructByte': 11, 'parameterByte': 21, 'limits': 'Field origin only; physical on/off semantics and accepted values are not proven'},
        'optionalBegin': {'guard': 'object+0xa84 != 0', 'helper': '0x4d9eb0'},
        'parameterWrites': [
            {'command': 6, 'relativeOffset': 0, 'length': 9},
            {'command': 6, 'relativeOffset': 21, 'length': 1, 'value': 'LightInfo.LightOpenFlag; read into struct byte 11, then copied to parameter byte 21'},
            {'command': 6, 'relativeOffset': 24, 'length': 1, 'value': 1},
        ],
        'writeFlag': '0 for transport selector 1; 0x55 for other selector values',
        'finish': {'helper': '0x4da0e0', 'command': '0x82 for selector 1; 0x02 otherwise',
                   'delayBeforeExchangeMilliseconds': 10, 'delayImport': f'{dll}!{function}'},
        'failureObservation': '4dd640 checks exchange result and reply statuses FF/FE; the high-level fallback caller does not branch on each returned result',
        'limits': 'Only the fixed executable fallback branch. Does not establish the live object selector, caller bank argument, actual USB packets/timing, color-write ordering, firmware semantics or incident cause. No packets generated or sent.',
    }


def inspect(path):
    data = Path(path).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != settings.EXPECTED_SHA256:
        raise ValueError('Executable hash differs; version-specific addresses cannot be used')
    result = audit_sequence(settings.PE32(data))
    result['executableSHA256'] = digest
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.executable), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error, UnicodeError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
