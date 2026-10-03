#!/usr/bin/env python3
"""Summarize report sizes from a saved HID descriptor. No device access."""
import argparse
import json
from pathlib import Path


def parse_descriptor(data):
    if not data or len(data) > 65535:
        raise ValueError('Descriptor size invalid')
    state = {'page': 0, 'size': 0, 'count': 0, 'id': 0}
    stack, reports, collections = [], {}, []
    local, offset, top_level_count = {}, 0, 0
    collection_ordinals = []
    while offset < len(data):
        prefix = data[offset]
        offset += 1
        if prefix == 0xfe:
            raise ValueError('Long HID item unsupported; refusing an incomplete layout')
        size = [0, 1, 2, 4][prefix & 3]
        if offset + size > len(data):
            raise ValueError('Truncated HID item')
        value = int.from_bytes(data[offset:offset + size], 'little')
        offset += size
        kind, tag = (prefix >> 2) & 3, prefix >> 4
        if kind == 1:
            field = {0: 'page', 7: 'size', 8: 'id', 9: 'count'}.get(tag)
            if field:
                if field == 'id' and not 1 <= value <= 255:
                    raise ValueError('Invalid report ID')
                if field in ['size', 'count'] and value > 65535:
                    raise ValueError('Oversized report field')
                state[field] = value
            elif tag == 10:
                stack.append(state.copy())
            elif tag == 11:
                if not stack:
                    raise ValueError('Global state stack underflow')
                state = stack.pop()
        elif kind == 2:
            if tag in [0, 1, 2]:
                local[{0: 'usage', 1: 'minimum', 2: 'maximum'}[tag]] = value
        elif kind == 0:
            if tag == 10:
                if not collections:
                    top_level_count += 1
                collections.append((state['page'], local.get('usage')))
                collection_ordinals.append(top_level_count)
            elif tag == 12:
                if not collections:
                    raise ValueError('Collection stack underflow')
                collections.pop()
                collection_ordinals.pop()
            elif tag in [8, 9, 11]:
                direction = {8: 'input', 9: 'output', 11: 'feature'}[tag]
                key = (state['id'], direction)
                report = reports.setdefault(key, {'id': state['id'], 'direction': direction, 'bits': 0, 'fields': []})
                bits = state['size'] * state['count']
                if report['bits'] + bits > 65535 * 8:
                    raise ValueError('Oversized report')
                report['fields'].append({'offsetBits': report['bits'], 'sizeBits': state['size'], 'count': state['count'],
                                         'usagePage': state['page'], 'flags': value, 'local': local.copy(),
                                         'collections': [list(c) for c in collections],
                                         'topLevelCollectionOrdinal': collection_ordinals[0] if collection_ordinals else None})
                report['bits'] += bits
            else:
                raise ValueError('Unsupported main item')
            local = {}
        elif kind == 3:
            raise ValueError('Reserved HID item')
    if collections or stack:
        raise ValueError('Unbalanced HID descriptor')
    if any(key[0] == 0 for key in reports) and any(key[0] != 0 for key in reports):
        raise ValueError('Mixed numbered and unnumbered reports')
    for report in reports.values():
        report['payloadBytes'] = (report['bits'] + 7) // 8
        report['bytesIncludingID'] = report['payloadBytes'] + bool(report['id'])
    return sorted(reports.values(), key=lambda r: (r['id'], r['direction']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('saved_capabilities', type=Path)
    args = parser.parse_args()
    root = json.loads(args.saved_capabilities.read_text())
    results = []
    for device in root['devices']:
        if device.get('VendorID') != 0x046a or device.get('ProductID') != 0x01ce:
            continue
        results.append({'vendorID': 0x046a, 'productID': 0x01ce,
                        'reports': parse_descriptor(bytes.fromhex(device['reportDescriptorHex']))})
    if not results:
        raise ValueError('No target descriptor in saved file')
    print(json.dumps({'format': 'CherryMacSavedHIDLayout', 'devices': results,
                      'limits': 'Descriptor layout only; no report captured, no device access, no text event or onboard support proven'}, indent=2))


if __name__ == '__main__':
    main()
