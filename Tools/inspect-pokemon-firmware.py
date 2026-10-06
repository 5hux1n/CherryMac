#!/usr/bin/env python3
"""Read the fixed official updater's firmware resources; never run or flash it."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct

EXPECTED_SHA256 = "188836c15eb1560d0282ae3c2485b4a4d2edd5dfb69a91d4510b273c61047088"
IMAGE_SHA256 = "31d0a07361ad531fa16867412d46e496737b126efc90482f86baa7e6bd5051bd"


def inspect_report_dispatcher(image, banks):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Firmware address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2F094, 0x2F0F4): '437df5aeb884ae1c9e779ca7413291e14832580e875d318e6bda80afa4189257',
        (0x2F3A2, 0x2F412): 'd7a2c05ecc6a4ffa877267902a1700dd9ffad4ef26085828b397820d8e0624a0',
        (0x2F412, 0x2F496): '813a60eea970437a244e037df5aeb4b1389754e5a06118c9540806b2b97eec3b',
        (0x2F496, 0x2F4E0): '032a88a3879c3d63eb52fb9b6b4a49f8e75ab418d52c42b918a50dae665f5ee5',
        (0x3A084, 0x3A0EC): '540b4da145fefe200a6cc68d8b6b35341083fc0a74902e55d81b6845e334240a',
    }
    for (start, end), expected in bodies.items():
        if hashlib.sha256(at(start, end - start)).hexdigest() != expected:
            raise ValueError("Report dispatcher code differs")
    checks = {0x2F0A2:'ec782f79b5f80580', 0x2F0B8:'3378042b40f0f180',
              0x2F0D8:'b02c05f10809', 0x2F0E2:'022c40f2e880e31ead2b00f2e480dfe813f0',
              0x2F49A:'bff40daf', 0x2F4A6:'bff407af', 0x2F4B8:'bff4feae', 0x2F4C4:'bff4f8ae'}
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if at(address, len(raw)) != raw:
            raise ValueError("Report dispatcher instruction differs")
    table = at(0x2F0F4, 174 * 2)
    if hashlib.sha256(table).hexdigest() != 'eb517b3f7b43bdbc3872f6a0c5cf8fb25cd27e9d90ad0779faa6cb2bcdfbf36d':
        raise ValueError("Report dispatcher jump table differs")
    commands = {3:0x2F3A2, 5:0x2F3BA, 6:0x2F250, 7:0x2F3D6,
                8:0x2F3F4, 9:0x2F412, 10:0x2F43E, 11:0x2F45C,
                20:0x2F496, 21:0x2F4B4, 27:0x2F338, 29:0x2F4F4}
    for command, expected in commands.items():
        destination = 0x2F0F4 + struct.unpack_from('<H', table, (command - 3) * 2)[0] * 2
        if destination != expected:
            raise ValueError("Named report command target differs")
    storage = {}
    for prefix, ram in [('led_define_',0x20000D18), ('kb_matrix_',0x20000A98), ('macro_data_',0x200054EC)]:
        rows = []
        for entry in banks[prefix]:
            index = int(entry['name'][len(prefix):]) - 1
            pointer = struct.pack('<I', int(entry['offset'],16) + base)
            matches = [m.start() for m in re.finditer(re.escape(pointer), image)
                       if m.start() % 4 == 0 and m.start() + 8 <= len(image)
                       and struct.unpack_from('<I',image,m.start()+4)[0] == ram + index * 64]
            if len(matches) != 1:
                raise ValueError("Storage-name/RAM pointer pair differs")
            rows.append({'name':entry['name'], 'pointerPairAddress':hex(matches[0]+base),
                         'ramAddress':hex(ram+index*64)})
        storage[prefix] = {'stride':64, 'rows':rows, 'limits':'Adjacent name/RAM pointer pairs only; page loading callbacks and persistence are not fully traced'}
    return {'entry':'0x2f094', 'instructionChecks':len(checks),
            'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'reportFields':{'reportID':0,'command':3,'length':4,'offsetUInt16':5,'payload':8},
            'reportIDGuard':4, 'jumpTable':{'address':'0x2f0f4','entries':174,'firstCommand':3,'lastCommand':176},
            'namedCommandTargets':{hex(k):hex(v) for k,v in commands.items()},
            'macroBounds':{'readBranch':'0x2f496','writeBranch':'0x2f4b4',
                           'offsetMustBeLessThan':3072,'offsetPlusLengthMustBeLessThan':3072,
                           'maximumCoveredPrefixBytes':3071},
            'copyHelper':'0x3a084; byte/word source-to-destination copy with alignment handling',
            'storagePointerPairs':storage,
            'limits':'Fixed firmware report-dispatch entry and named branches only. USB callback routing, checksums upstream, all command side effects, save completion and installed firmware identity remain unproved. No new hardware authorization.'}


def inspect_storage_save_paths(image):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or offset + size > len(image):
            raise ValueError("Save-path address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2E9D0,0x2EA34):'a501d4e4e3d2c024aebdfdcfe4e7b7b50ed83dbdf0a9b25cbcc177f51872f992',
        (0x2EA48,0x2EBE8):'f6c92fccc934657658aafed40d4628d616e6de5be147315ec4c0aef2a99d5981',
        (0x2EC50,0x2EDBC):'69db63862d1312553707bbf38c617e1ae8ff616ae3a9fc7560d12cc27ca5a0d6',
        (0x2EE24,0x2EE54):'132098597e64eb9df1f61cd7f6a7cd5764567dfe2c6d1b59429958e9b2c525cc',
        (0x2EE64,0x2EEA4):'6561d35513cb2d824603a210c117d31eb2bcbf37bcfd279be0b3a707ed961c74',
        (0x33924,0x33960):'a9257d78973a3a3fe844a1c0f373e869b457b9e56aa046a795ee08e3231564b8',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Storage save-path body differs")

    def branch_link(address):
        first, second = struct.unpack('<HH', at(address,4))
        if first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000:
            raise ValueError("Expected a Thumb BL instruction")
        sign = (first >> 10) & 1
        i1 = 1 ^ ((second >> 13) & 1) ^ sign
        i2 = 1 ^ ((second >> 11) & 1) ^ sign
        displacement = (sign << 24) | (i1 << 23) | (i2 << 22) | ((first & 0x3FF) << 12) | ((second & 0x7FF) << 1)
        if sign:
            displacement -= 1 << 25
        return address + 4 + displacement

    calls = {'colors':[0x2EB0E,0x2EB2C,0x2EB4A,0x2EB68,0x2EB86,0x2EBA4,0x2EBC2,0x2EBE0],
             'keymap':[0x2ED0E,0x2ED26,0x2ED3E,0x2ED56,0x2ED6E,0x2ED86,0x2ED9E,0x2EDB6]}
    for addresses in calls.values():
        for address in addresses:
            if branch_link(address) != 0x33924 or struct.unpack('<H',at(address+4,2))[0] & 0xF800 != 0xE000:
                raise ValueError("Named save call/return-discard branch differs")
    if branch_link(0x2EE9A) != 0x33924 or at(0x2EE9E,4) != bytes.fromhex('06b070bd'):
        raise ValueError("Device-version save epilogue differs")
    if branch_link(0x2EA18) != 0x33924 or at(0x2EA1C,6) != bytes.fromhex('05460028e0d1'):
        raise ValueError("Parameter save return check differs")
    literals = {0x2EBE8:0x20009B2B,0x2EBEC:0x20009B25,
                0x2EDBC:0x20009B2B,0x2EDC0:0x20009B27,
                0x2EE54:0x20009B2B,0x2EE58:0x20009B26,
                0x2EEA4:0x20009B2B,0x2EEA8:0x20009B24,
                0x2EEAC:0x4F204,0x2EEB0:0x20000C98,0x33960:0x20007384,
                0x2EA34:0x20009B2B,0x2EA38:0x20009B28,0x2EA3C:0x20000CD8,
                0x2EA40:0x20006F2C,0x2EA44:0x4F0B4}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Save-path literal differs")
    if at(0x4F204,len(b'flash/device_version\0')) != b'flash/device_version\0':
        raise ValueError("Device-version storage name differs")
    if at(0x4F0B4,len(b'flash/func_ram\0')) != b'flash/func_ram\0':
        raise ValueError("Parameter storage name differs")
    return {'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'backendFacade':'0x33924; obtains backend from pointer at 0x20007384 and invokes its function-table offset 8; returns backend result or -2 when absent',
            'commonSkipCondition':'Named save helpers return without saving when byte 0x20009b2b equals 4; meaning of this state is not yet classified',
            'saveFlags':{'colors':'0x20009b25','keymap':'0x20009b27','macroData':'0x20009b26','parameters':'0x20009b28','deviceVersion':'0x20009b24'},
            'namedBackendCalls':{key:[hex(address) for address in addresses] for key,addresses in calls.items()},
            'returnHandling':'Each of the sixteen named color/keymap calls is followed immediately by an unconditional branch, without checking r0. The device-version helper clears its flag before the backend call and returns through its epilogue without checking r0. Parameter saving uses a separate return-checked helper',
            'macroGate':'0x2ee24 compares 3072 RAM bytes with its shadow; identical data clears the flag, differing data invokes 0x2dee8',
            'deviceVersionSave':{'helper':'0x2ee64','name':'flash/device_version','sourceRAM':'0x20000c98','length':64},
            'parameterSave':{'helper':'0x2e9d0','name':'flash/func_ram','sourceRAM':'0x20000cd8','shadowRAM':'0x20006f2c','length':64,
                             'returnHandling':'0x2ea18 calls the backend; a nonzero return skips shadow update/flag clearing. Zero updates the shadow and clears the flag; unchanged data also clears it',
                             'normalization':'When saving changed parameters, byte 16 equal to 4 is replaced with 2; purpose and live relevance remain unclassified'},
            'limits':'Named save helper/facade paths only. Actual backend selection, physical flash writes, polling schedule, failure propagation outside these calls and USB completion semantics remain unproved. RAM readback does not establish persistence; no automatic retry or added hardware authorization.'}


def download_resources(pe):
    optional = pe.u32(0x3C) + 24
    base = pe.base + pe.u32(optional + 96 + 2 * 8)

    def entries(offset):
        header = struct.unpack("<II4H", pe.at(base + offset, 16))
        count = header[-2] + header[-1]
        if count > 512:
            raise ValueError("Resource directory exceeds bounds")
        return [struct.unpack("<II", pe.at(base + offset + 16 + i * 8, 8)) for i in range(count)]

    def name(value):
        if not value & 0x80000000:
            return value
        address = base + (value & 0x7FFFFFFF)
        length = struct.unpack("<H", pe.at(address, 2))[0]
        if length > 128:
            raise ValueError("Resource name exceeds bounds")
        return pe.at(address + 2, length * 2).decode("utf-16-le")

    result = {}
    for kind, directory in entries(0):
        if name(kind) != "DOWNLOAD":
            continue
        if not directory & 0x80000000:
            raise ValueError("Invalid DOWNLOAD resource directory")
        for identifier, languages in entries(directory & 0x7FFFFFFF):
            if identifier not in (129, 141) or not languages & 0x80000000:
                raise ValueError("Unexpected DOWNLOAD resource identifier")
            for language, leaf in entries(languages & 0x7FFFFFFF):
                if language not in (0, 2052) or leaf & 0x80000000 or (identifier, language) in result:
                    raise ValueError("Unexpected or duplicate DOWNLOAD language")
                rva, size, _, _ = struct.unpack("<4I", pe.at(base + leaf, 16))
                if not 0 < size <= 1_000_000:
                    raise ValueError("DOWNLOAD resource size exceeds bounds")
                result[identifier, language] = pe.at(pe.base + rva, size)
    if set(result) != {(129, 0), (129, 2052), (141, 0), (141, 2052)}:
        raise ValueError("Missing expected DOWNLOAD resources")
    return result


def inspect(path):
    source = Path(path)
    if source.stat().st_size != 4_873_728:
        raise ValueError("Unexpected updater size")
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("Updater differs from the analyzed official download")
    spec = importlib.util.spec_from_file_location("settings_pe_reader", Path(__file__).with_name("inspect-official-settings.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    resources = download_resources(module.PE32(data))
    # The fixed neutral resource contains a literal newline in a UI string.
    # Preserve its bytes/hash; relax string control characters only for reading.
    configurations = {lang: json.loads(resources[141, lang], strict=False)['device'] for lang in (0, 2052)}
    target = configurations[0]
    if (target.get('device_VID'), target.get('device_PID'), target.get('device_REV')) != ('046A', '01CE', '0104'):
        raise ValueError("Target resource configuration identity differs")
    image = resources[129, 0]
    if len(image) != 272_876 or hashlib.sha256(image).hexdigest() != IMAGE_SHA256:
        raise ValueError("Target firmware image differs")
    descriptor_offset = 0x421C4
    descriptor = image[descriptor_offset:descriptor_offset + 18]
    if descriptor != bytes.fromhex('12010002000000406a04ce01040101020001'):
        raise ValueError("Target USB descriptor bytes differ")
    strings = [(m.start(), m.group()[:-1].decode('ascii')) for m in re.finditer(rb'[\x20-\x7e]{7,}\x00', image)]
    banks = {}
    for prefix, expected in [('led_define_', 8), ('kb_matrix_', 8), ('macro_data_', 48)]:
        rows = [{'offset': hex(offset), 'name': text} for offset, text in strings if re.fullmatch(re.escape(prefix) + r'[1-9]\d*', text)]
        if sorted(int(row['name'][len(prefix):]) for row in rows) != list(range(1, expected + 1)):
            raise ValueError("Firmware storage-name inventory differs")
        banks[prefix] = rows
    anchors = []
    for text in ('MX 3.0S Pokemon', 'led_define_1', 'macro_data_1'):
        offset = image.find(text.encode('ascii') + b'\0')
        if offset < 0:
            raise ValueError("Missing target firmware anchor")
        pointer = struct.pack('<I', offset + 0x10000)
        references = [m.start() for m in re.finditer(re.escape(pointer), image) if m.start() % 4 == 0]
        if not references:
            raise ValueError("Missing candidate link-base pointer anchor")
        anchors.append({'name': text, 'offset': hex(offset), 'candidateAddress': hex(offset + 0x10000),
                        'alignedPointerOffsets': [hex(value) for value in references]})
    return {'format': 'CherryMacOfficialPokemonFirmwareStaticAudit', 'version': 3,
            'updaterSHA256': digest, 'updaterMD5': hashlib.md5(data).hexdigest(),
            'method': 'Read-only PE32 resource parsing and fixed-byte inspection; no execution, emulation or hardware access',
            'resources': [{'id': identifier, 'language': language, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                          for (identifier, language), raw in sorted(resources.items())],
            'configurations': configurations,
            'targetImage': {'resource': {'id': 129, 'language': 0}, 'size': len(image), 'sha256': IMAGE_SHA256,
                            'usbDescriptorOffset': hex(descriptor_offset), 'vendorID': 0x046A, 'productID': 0x01CE,
                            'descriptorBCDDevice': 0x0104, 'initialVectorWords': list(struct.unpack_from('<4I', image)),
                            'candidateLinkBase': '0x10000', 'pointerAnchors': anchors, 'storageNames': banks},
            'reportDispatcher': inspect_report_dispatcher(image, banks),
            'storageSavePaths': inspect_storage_save_paths(image),
            'hardwareReady': False, 'firmwareUpgradeImplemented': False,
            'limits': 'The package contains two different images/configurations under different resource languages. The neutral resource has target identity and its image contains the target USB descriptor and model strings; updater runtime resource selection is not proved. No claim about installed firmware, name-to-bank capacity, command decoding, flash persistence or blackout cause. Storage names and pointer anchors guide further firmware analysis only.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('updater', help='Local official Pokémon 0104 updater; read only')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.updater), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, struct.error, UnicodeError) as error:
        parser.exit(1, str(error) + '\n')
