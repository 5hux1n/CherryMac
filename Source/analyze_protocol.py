#!/usr/bin/env python3
"""Offline inspection of CHERRY report-4 hex dumps; never opens a device."""
import argparse
import json
import re
from pathlib import Path


def decode_packet(packet):
    if len(packet) != 64 or packet[0] != 4:
        raise ValueError('Expected a 64-byte report beginning with report ID 04')
    command = packet[3]
    # The Rust implementation checks only the query header for these replies.
    # Other commands include all bytes, including padding, in the checksum.
    calculated = sum(packet[3:8] if command in (7, 0x1B) else packet[3:])
    stored = int.from_bytes(packet[1:3], 'little')
    names = {1: 'transaction_start', 2: 'transaction_end', 3: 'unknown_info',
             5: 'unknown', 6: 'lighting_parameters', 7: 'keymap_query',
             9: 'keymap_write_candidate', 11: 'custom_led_data',
             0x1B: 'index_query_project_interpretation'}
    result = {'command': f'{command:02x}', 'name': names.get(command, 'unknown'),
              'checksum_stored': stored, 'checksum_calculated': calculated,
              'checksum_valid': stored == calculated}
    if command in (7, 9, 11, 0x1B):
        size = packet[4]
        if size > 56:
            raise ValueError('Chunk exceeds report capacity')
        result.update(offset=int.from_bytes(packet[5:7], 'little'),
                      length=size, data_hex=packet[8:8+size].hex())
    if command == 6:
        result['parameter_header_hex'] = packet[4:9].hex()
        if packet[4:9] == bytes.fromhex('0900005500'):
            result.update(mode=packet[9], brightness=packet[10], speed=packet[11],
                          direction_or_unknown=packet[12], rainbow=packet[13],
                          rgb=list(packet[14:17]))
    return result


def read_hex_packets(source):
    """Accept full 128-hex-digit reports, including the contributor's HTML dump."""
    packets = []
    for line in source.splitlines():
        line = re.sub(r'<[^>]*>', '', line).split('//', 1)[0].strip()
        compact = re.sub(r'\s+', '', line)
        if re.fullmatch(r'[0-9a-fA-F]{128}', compact):
            packets.append(bytes.fromhex(compact))
    if not packets:
        raise ValueError('No complete 64-byte hex reports found')
    return packets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    packets = read_hex_packets(args.input.read_text())
    results = [decode_packet(packet) for packet in packets]
    report = {'offline_only': True, 'input': str(args.input),
              'packet_count': len(results),
              'invalid_checksum_count': sum(not r['checksum_valid'] for r in results),
              'packets': results}
    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.write_text(rendered + '\n')
    else:
        print(rendered)


if __name__ == '__main__':
    main()
