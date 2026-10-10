#!/usr/bin/env python3
"""Check a private Windows collection and optionally analyze one existing pcap.

No capture, HID, keyboard writes, uploads or file mutations. Hash agreement
links local files; it does not authenticate the collector or prove hardware IO.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, '清单含重复字段。')
        result[key] = value
    return result


def file_receipt(path, limit, keep=False):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as handle:
        first = os.fstat(handle.fileno())
        require(stat.S_ISREG(first.st_mode) and 0 < first.st_size <= limit,
                '资料不是有效大小的普通文件。')
        digest, size, data = hashlib.sha256(), 0, bytearray()
        while True:
            chunk = handle.read(min(1_048_576, limit + 1 - size))
            if not chunk:
                break
            size += len(chunk)
            require(size <= limit, '读取期间资料超过大小限制。')
            digest.update(chunk)
            if keep:
                data.extend(chunk)
        last = os.fstat(handle.fileno())
        require(size == first.st_size and
                (first.st_size, first.st_mtime_ns, first.st_ctime_ns) ==
                (last.st_size, last.st_mtime_ns, last.st_ctime_ns), '读取期间资料发生变化。')
        return size, digest.hexdigest(), bytes(data)


def inspect(directory, capture=None, bus=None, device=None):
    require((capture is None and bus is None and device is None) or
            (capture is not None and bus is not None and device is not None),
            '分析抓包时必须同时指定清单文件名、bus和设备地址。')
    manifest_path = directory / 'collection.json'
    _, manifest_sha, data = file_receipt(manifest_path, 65_536, keep=True)
    def invalid_constant(_):
        raise ValueError('清单含非有限数值。')
    value = json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique, parse_constant=invalid_constant)
    require(isinstance(value, dict) and value.get('format') == 'CherryMacWindowsEvidenceCollection' and
            type(value.get('version')) is int and value['version'] == 1, '不是支持的Windows资料清单。')
    for key in ('startedCapture', 'openedHID', 'keyboardWrites', 'targetIdentityVerified', 'configurationWriteAccepted'):
        require(value.get(key) is False, '清单的操作／证据范围声明不符。')
    rows = value.get('files')
    require(type(rows) is list and 1 <= len(rows) <= 16, '资料文件数无效。')
    verified = []
    for index, row in enumerate(rows, 1):
        require(type(row) is dict and type(row.get('file')) is str and
                re.fullmatch(r'sample-' + str(index) + r'\.(json|pcap|pcapng)', row['file']),
                '资料文件名或次序无效，不使用清单中的任意路径。')
        suffix = Path(row['file']).suffix
        kind = 'official-json-candidate' if suffix == '.json' else 'usb-capture-candidate'
        limit = 16_000_000 if suffix == '.json' else 256_000_000
        require(row.get('kind') == kind and type(row.get('bytes')) is int and
                0 < row['bytes'] <= limit and type(row.get('sha256')) is str and
                re.fullmatch(r'[0-9a-f]{64}', row['sha256']), '资料类型、大小或摘要无效。')
        size, digest, _ = file_receipt(directory / row['file'], limit)
        require(size == row['bytes'] and digest == row['sha256'], '资料与清单不一致：' + row['file'])
        verified.append({'file': row['file'], 'bytes': size, 'sha256': digest, 'kind': kind})
    analysis = None
    if capture is not None:
        selected = next((row for row in verified if row['file'] == capture), None)
        require(selected is not None and capture.endswith('.pcap'),
                '需要清单内的经典pcap；pcapng应先离线转换并重新收集。')
        source = Path(__file__).with_name('inspect-windows-usb-capture.py')
        spec = importlib.util.spec_from_file_location('cherrymac_windows_capture', source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        analysis = module.inspect(directory / capture, bus, device)
        require(analysis['captureSHA256'] == selected['sha256'], '抓包分析期间文件内容与已核对清单不同。')
    _, final_sha, _ = file_receipt(manifest_path, 65_536)
    require(final_sha == manifest_sha, '分析期间清单发生变化。')
    return {'format': 'CherryMacWindowsEvidenceInspection', 'version': 1,
            'collectionSHA256': manifest_sha, 'filesIntegrityVerified': True, 'files': verified,
            'captureAnalysis': analysis, 'deviceMetadataError': value.get('deviceMetadataError'),
            'officialConfigurationValidated': False, 'targetIdentityVerified': False,
            'configurationWriteAccepted': False, 'powerCycleVerified': False, 'authorizesReplay': False,
            'limits': 'Local file pairing only; no collector authenticity, JSON model validation, '
                      'capture bus/address-to-PnP identity or current hardware acceptance. '
                      'Analysis is historical; files may change after inspection.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--capture-file')
    parser.add_argument('--bus', type=int)
    parser.add_argument('--device', type=int)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.directory, args.capture_file, args.bus, args.device), ensure_ascii=False, indent=2))
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
        parser.exit(1, str(error) + '\n')
