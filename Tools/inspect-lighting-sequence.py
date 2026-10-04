#!/usr/bin/env python3
"""Audit supplied Utility lighting parameter/color paths; no execution or HID."""
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


# Exact word-load, compare and conditional-jump bytes; no general x86 emulator.
PREDICATES = [
    (0x500AE5, "0fb7881a1e0000", "83f977", "0f84c2000000"),
    (0x500AFB, "0fb7821a1e0000", "3dc3000000", "0f84aa000000"),
    (0x500B13, "0fb7911a1e0000", "81facd000000", "0f8491000000"),
    (0x500B2C, "0fb7881a1e0000", "81f9cb000000", "747c"),
    (0x500B41, "0fb7821a1e0000", "3dd2000000", "7468"),
    (0x500B55, "0fb7911a1e0000", "81face000000", "7453"),
    (0x500B6A, "0fb7881a1e0000", "81f9ab010000", "743e"),
    (0x500B7F, "0fb7821a1e0000", "3daf010000", "742a"),
    (0x500B93, "0fb7911a1e0000", "81fabb010000", "7415"),
    (0x500BA8, "0fb7881a1e0000", "81f9cec00000", "750a"),
    (0x500BE7, "0fb7881a1e0000", "81f9b4000000", "752c"),
    (0x500C28, "0fb7881a1e0000", "81f9b2010000", "0f84e2000000"),
    (0x500C41, "0fb7821a1e0000", "3db7010000", "0f84ca000000"),
    (0x500C59, "0fb7911a1e0000", "81fab1010000", "0f84b1000000"),
    (0x500C72, "0fb7881a1e0000", "81f9b4010000", "0f8498000000"),
    (0x500C8B, "0fb7821a1e0000", "3de5000000", "0f8480000000"),
    (0x500CA3, "0fb7911a1e0000", "81faec000000", "746b"),
    (0x500CB8, "0fb7881a1e0000", "81f9c2010000", "7456"),
    (0x500CCD, "0fb7821a1e0000", "3dc3010000", "7442"),
    (0x500CE1, "0fb7911a1e0000", "81fae3000000", "742d"),
    (0x500CF6, "0fb7881a1e0000", "81f9ea000000", "7418"),
    (0x500D0B, "0fb7821a1e0000", "3df3010000", "0f8580000000"),
    (0x500DA3, "0fb7911a1e0000", "81fad7010000", "0f8580000000"),
    (0x500E3C, "0fb7881a1e0000", "81f9de010000", "0f84e2000000"),
    (0x500E55, "0fb7821a1e0000", "3de2010000", "0f84ca000000"),
    (0x500E6D, "0fb7911a1e0000", "81fae4010000", "0f84b1000000"),
    (0x500E86, "0fb7881a1e0000", "81f9da010000", "0f8498000000"),
    (0x500E9F, "0fb7821a1e0000", "3ddb010000", "0f8480000000"),
    (0x500EB7, "0fb7911a1e0000", "81fae6010000", "746b"),
    (0x500ECC, "0fb7881a1e0000", "81f9e8010000", "7456"),
    (0x500EE1, "0fb7821a1e0000", "3df7010000", "7442"),
    (0x500EF5, "0fb7911a1e0000", "81faf9010000", "742d"),
    (0x500F0A, "0fb7881a1e0000", "81f9ef010000", "7418"),
    (0x500F1F, "0fb7821a1e0000", "3df1010000", "0f859e000000"),
    (0x500FD5, "0fb7911a1e0000", "81fafb010000", "7442"),
    (0x500FEA, "0fb7881a1e0000", "81f942010000", "742d"),
    (0x500FFF, "0fb7821a1e0000", "3d4c010000", "7419"),
    (0x501013, "0fb7911a1e0000", "81fa4e010000", "0f85b9000000"),
]
BRANCH_GROUPS = [(0, 10, 0x500BB0), (10, 11, 0x500BEF),
                 (11, 22, 0x500D16), (22, 23, 0x500DAF),
                 (23, 34, 0x500F2A), (34, 38, 0x50101F)]


def audit_selector(pe, selector=0x1CE):
    if type(selector) is not int or not 0 <= selector <= 0xFFFF:
        raise ValueError('Selector must be an unsigned word')
    decoded = []
    for address, load_hex, compare_hex, jump_hex in PREDICATES:
        load, compare, jump = map(bytes.fromhex, (load_hex, compare_hex, jump_hex))
        for start, value in ((address - 7, load), (address, compare), (address + len(compare), jump)):
            if pe.at(start, len(value)) != value:
                raise ValueError(f'Unexpected selector instruction at {start:#x}')
        # CMP r32, imm8 uses sign extension; the other encodings use imm32.
        value = struct.unpack('<b', compare[-1:])[0] if compare[0] == 0x83 else struct.unpack('<I', compare[-4:])[0]
        near = jump[0] == 0x0F
        opcode = jump[1] if near else jump[0]
        equal_jump = opcode in (0x74, 0x84)
        displacement = struct.unpack('<i' if near else '<b', jump[2:] if near else jump[1:])[0]
        fallthrough = address + len(compare) + len(jump)
        decoded.append((value, equal_jump, fallthrough + displacement, fallthrough))
    groups = []
    selected = 0x5010D8
    for first, end, destination in BRANCH_GROUPS:
        entries = decoded[first:end]
        for value, equal_jump, target, fallthrough in entries:
            if (target if equal_jump else fallthrough) != destination:
                raise ValueError('Selector equality destination differs')
        values = [entry[0] for entry in entries]
        groups.append({'values': [f'0x{x:04x}' for x in values], 'equalBranch': hex(destination)})
        if selector in values:
            selected = destination
    return {'objectField': 'word at object+0x1e1a', 'assumedValue': f'0x{selector:04x}',
            'predicateCount': len(decoded), 'groups': groups, 'selectedBranch': hex(selected),
            'limits': 'Conditional decision-table audit only. The source of the live object field and its equivalence to USB PID remain unproven; this is not a trace of device execution.'}


COLOR_CHECKS = {
    0x501210: "83b84022000000",
    0x501217: "0f842c070000",
    0x501288: "81c138210000",
    0x50128E: "e85da6fbff",
    0x5012B1: "6bc203",
    0x5012F5: "0fb64003",
    0x5012F9: "0faff0",
    0x50130A: "c1f908",
    0x501317: "888c05d0fdffff",
    0x501354: "0fb64003",
    0x501358: "0faff0",
    0x501369: "c1f908",
    0x501376: "888c05d1fdffff",
    0x5013B3: "0fb64003",
    0x5013B7: "0faff0",
    0x5013C8: "c1f908",
    0x5013D5: "888c05d2fdffff",
    0x50184D: "83ba840a000000",
    0x501854: "7411",
    0x501862: "e84986fdff",
    0x50186D: "0fb7881a1e0000",
    0x501874: "81f9da010000",
    0x50187A: "743e",
    0x501889: "3de6010000",
    0x50188E: "742a",
    0x50189D: "81faef010000",
    0x5018A3: "7415",
    0x5018B2: "81f94c010000",
    0x5018B8: "753d",
    0x5018F7: "8b5508",
    0x5018FA: "c1e209",
    0x50190A: "e8c1a7fbff",
    0x50190F: "6bc003",
    0x501926: "e8b5b4fdff",
    0x50192B: "8985b4fdffff",
    0x501931: "6a01",
    0x50193F: "e89c87fdff",
    0x501944: "e9f4030000",
    0x501D3D: "83bdb4fdffff01",
    0x501D44: "740b",
    0x501D46: "68c8000000",
    0x501D4B: "ff15f4bc6e00",
    0x4DCE25: "c64405bc04",
    0x4DCE34: "83fa01",
    0x4DCE37: "750f",
    0x4DCE41: "c6440dbc8b",
    0x4DCE50: "c64405bc0b",
    0x4DCE79: "c64405bc00",
    0x4DCE90: "0fb69190060000",
    0x4DCEFC: "884c05bc",
    0x4DCF06: "034510",
    0x4DCF1A: "88540dbc",
    0x4DCF24: "035510",
    0x4DCF27: "c1ea08",
    0x4DCF32: "88540dbc",
    0x4DCF54: "e8c79d1a00",
    0x4DCF81: "83bd70ffffff40",
    0x4DCF95: "03956cffffff",
    0x4DD000: "e87bc3ffff",
    0x4DD028: "83bd64ffffff01",
    0x4DD049: "81faff000000",
    0x4DD068: "81fafe000000",
    0x4B198D: "8b82bc020000",
    0x4B1993: "ffd0",
    0x4B199C: "e88fad0300",
    0x4B19A5: "83fa15",
    0x4B19A8: "751f",
    0x4B19C1: "8b82c4020000",
    0x4B19C7: "ffd0",
}


def audit_colors(pe):
    if pe.pointer(0x77F604 + 0x2C4) != 0x501190:
        raise ValueError('Unexpected color virtual method')
    for address, encoded in COLOR_CHECKS.items():
        value = bytes.fromhex(encoded)
        if pe.at(address, len(value)) != value:
            raise ValueError(f'Unexpected color instruction at {address:#x}')
    return {
        'method': '0x501190', 'helper': '0x4dcde0', 'instructionChecks': len(COLOR_CHECKS),
        'scope': 'Main RGB-table path requires object+0x2240 != 0. Alternate path and live field initialization remain unverified.',
        'buffer': {'mappingLookup': 'object+0x2138; lookup helper 0x4bb8f0',
                   'rgb': 'buffer[mappedIndex*3+channel] = (component*fourthColorByte) >> 8',
                   'limits': 'Fourth in-memory color byte; JSON Alpha linkage not yet established. Do not use this as a profile conversion rule.'},
        'conditionalBank': {'objectField': 'word at object+0x1e1a',
                            'specialValues': ['0x01da', '0x01e6', '0x01ef', '0x014c'],
                            'otherBankBase': 'caller argument << 9',
                            'length': 'mapping container size returned by 0x4bc0d0 multiplied by 3'},
        'sequence': ['optional begin 0x4d9eb0 when object+0xa84 != 0',
                     'color helper 0x4dcde0', 'finish 0x4da0e0 with argument 1'],
        'helperReport': {'reportID': 4, 'command': '0x8b for transport selector 1; 0x0b otherwise',
                         'flagByte7': 0, 'lengthByte': 4, 'offsetBytesLittleEndian': [5, 6],
                         'payloadStart': 8, 'chunkCapacity': 'object+0x690',
                         'checksum': 'sum report bytes 3 through 63 into bytes 1 and 2'},
        'helperFailure': 'Returns exchange failure or FF/FE reply status failure before continuing the next chunk.',
        'callerFailure': 'Stores color result, still calls finish, waits 200 ms on color failure, then returns zero; finish result is not checked here.',
        'observedStaticCaller': {'method': '0x4b1930',
                                'order': ['parameter virtual +0x2bc', 'color virtual +0x2c4 only when getter first byte equals 21'],
                                'limits': 'One static call site, not proof of every UI path or actual execution. Its parameter getter field identity is not fully traced.'},
        'limits': 'Static evidence only. No actual mapping, bank argument, timing, packets or incident cause established. No device accessed.'}


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
        'selectorAudit': audit_selector(pe),
        'colorAudit': audit_colors(pe),
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
        'limits': 'Only the fixed executable fallback branch. Does not establish the live object selector, caller bank argument, actual USB packets/timing, all UI write ordering, firmware semantics or incident cause. No packets generated or sent.',
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
