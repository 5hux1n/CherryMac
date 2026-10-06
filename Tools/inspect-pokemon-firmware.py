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
    return {'format': 'CherryMacOfficialPokemonFirmwareStaticAudit', 'version': 1,
            'updaterSHA256': digest, 'updaterMD5': hashlib.md5(data).hexdigest(),
            'method': 'Read-only PE32 resource parsing and fixed-byte inspection; no execution, emulation or hardware access',
            'resources': [{'id': identifier, 'language': language, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                          for (identifier, language), raw in sorted(resources.items())],
            'configurations': configurations,
            'targetImage': {'resource': {'id': 129, 'language': 0}, 'size': len(image), 'sha256': IMAGE_SHA256,
                            'usbDescriptorOffset': hex(descriptor_offset), 'vendorID': 0x046A, 'productID': 0x01CE,
                            'descriptorBCDDevice': 0x0104, 'initialVectorWords': list(struct.unpack_from('<4I', image)),
                            'candidateLinkBase': '0x10000', 'pointerAnchors': anchors, 'storageNames': banks},
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
