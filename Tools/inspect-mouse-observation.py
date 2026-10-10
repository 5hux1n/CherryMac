#!/usr/bin/env python3
"""Decode saved v2/v3 macro-observer mouse bytes using the saved HID descriptor.

No device access, writes, injected input or firmware-layout compensation.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, maximum):
    return type(value) is int and 0 <= value <= maximum


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def decode(payload, report):
    packed = int.from_bytes(payload, 'little')
    result = []
    for field in report['fields']:
        if field['flags'] & 1:
            continue
        require(field['flags'] & 2, 'Mouse array fields are unsupported')
        width, count, local = field['sizeBits'], field['count'], field['local']
        require(1 <= width <= 32 and 1 <= count <= 512, 'Mouse field size exceeds bounds')
        usages = local.get('usages', [])
        require(not (usages and ('minimum' in local or 'maximum' in local)),
                'Mixed explicit/range usage mapping is unsupported')
        if not usages and 'minimum' in local and 'maximum' in local:
            require(local['maximum'] >= local['minimum'] and local['maximum'] - local['minimum'] < 512,
                    'Mouse usage range exceeds bounds')
            usages = list(range(local['minimum'], local['maximum'] + 1))
        require(len(usages) >= count, 'Mouse field usage mapping is incomplete')
        for index in range(count):
            offset = field['offsetBits'] + index * width
            raw = (packed >> offset) & ((1 << width) - 1)
            signed = field['logicalMinimum'] < 0
            value = raw - (1 << width) if signed and raw & (1 << (width-1)) else raw
            usage = usages[index]
            page = usage >> 16 if usage > 65535 else field['usagePage']
            usage &= 65535
            result.append({'usagePage': page, 'usage': usage, 'offsetBits': offset,
                           'sizeBits': width, 'value': value, 'relative': bool(field['flags'] & 4),
                           'logicalMinimum': field['logicalMinimum'], 'logicalMaximum': field['logicalMaximum'],
                           'inDeclaredRange': field['logicalMinimum'] <= value <= field['logicalMaximum']})
    return result



def compare_values(session, reports, registry):
    # v2 rawValues is a filtered event projection, not an input-value ledger.
    if session['version'] == 2:
        require('rawMouseValues' not in session, 'v2 session unexpectedly includes a v3 value ledger')
        return {'available': False, 'reason': 'v2 lacks complete report2 value callbacks', 'values': []}
    values = session.get('rawMouseValues')
    require(type(values) is list and len(values) <= 65536, 'Mouse value ledger exceeds bounds')
    by_time = {}
    for report in reports:
        by_time.setdefault(report['milliseconds'], []).append(report)
    output = []
    for row in values:
        require(type(row) is dict and set(row) == {'reportID', 'page', 'usage', 'value', 'milliseconds', 'registryID'} and
                type(row['reportID']) is int and row['reportID'] == 2 and
                number(row['page'], 65535) and number(row['usage'], 65535) and type(row['value']) is int and
                -9223372036854775808 <= row['value'] <= 9223372036854775807 and
                number(row['milliseconds'], 9007199254740991) and row['registryID'] == registry,
                'Mouse value source/time/fields invalid')
        matches = by_time.get(row['milliseconds'], [])
        declared = None
        if not matches:
            state = 'no-raw-report-in-time-bucket'
        elif len(matches) != 1:
            state = 'ambiguous-time-bucket'
        elif matches[0]['error'] is not None:
            state = 'raw-report-not-decodable'
        else:
            fields = [f for f in matches[0]['fields'] if f['usagePage'] == row['page'] and f['usage'] == row['usage']]
            if len(fields) != 1:
                state = 'field-unavailable-or-ambiguous'
            else:
                declared = fields[0]['value']
                state = 'same-value' if declared == row['value'] else 'different-value'
        output.append({'milliseconds': row['milliseconds'], 'page': row['page'], 'usage': row['usage'],
                       'callbackValue': row['value'], 'descriptorDecodedValue': declared, 'status': state})
    counts = {}
    for row in output:
        counts[row['status']] = counts.get(row['status'], 0) + 1
    return {'available': True, 'valueCount': len(output), 'counts': counts, 'values': output,
            'joinMethod': 'Exactly one saved raw report in the same millisecond and one matching descriptor usage',
            'limits': 'Millisecond buckets are not packet IDs. Same/different values indicate historical correlation only; absent, ambiguous or filtered callbacks are not inferred. Does not change macro execution assessment.'}


def inspect(session):
    require(type(session) is dict and session.get('format') == 'CherryMacMacroObservationSession' and
            type(session.get('version')) is int and session['version'] in (2, 3), 'Need a v2 or v3 native observation session')
    rows = session.get('rawMouseReports')
    require(type(rows) is list and len(rows) <= 4096 and type(session.get('descriptorAvailable')) is bool,
            'Raw mouse evidence structure invalid')
    registry = session.get('registryID')
    if rows or session.get('rawMouseValues'):
        require(type(registry) is str and registry.isascii() and registry.isdecimal() and
                registry == str(int(registry)) and 0 < int(registry) <= 18446744073709551615, 'USB registry identity invalid')
    descriptor = None
    report = None
    if session['descriptorAvailable']:
        encoded = session.get('reportDescriptorHex')
        require(type(encoded) is str and 0 < len(encoded) <= 32768 and len(encoded) % 2 == 0 and
                all(c in '0123456789abcdef' for c in encoded), 'Descriptor hex invalid')
        descriptor = bytes.fromhex(encoded)
        require(hashlib.sha256(descriptor).hexdigest() == session.get('reportDescriptorSHA256'), 'Descriptor hash mismatch')
        path = Path(__file__).with_name('hid-report-layout.py')
        spec = importlib.util.spec_from_file_location('cherrymac_mouse_layout', path)
        layout = importlib.util.module_from_spec(spec);spec.loader.exec_module(layout)
        matches = [r for r in layout.parse_descriptor(descriptor) if r['id'] == 2 and r['direction'] == 'input']
        require(len(matches) == 1 and 0 < matches[0]['bits'] <= 512 and
                all([1, 2] in f['collections'] for f in matches[0]['fields']), 'Report2 is not a bounded mouse collection')
        report = matches[0]
    else:
        require('reportDescriptorHex' not in session and 'reportDescriptorSHA256' not in session, 'Descriptor availability contradicts fields')
    output = []
    for row in rows:
        require(type(row) is dict and set(row) == {'reportID', 'result', 'bytes', 'receivedLength', 'milliseconds', 'registryID'},
                'Raw report fields invalid')
        raw = row['bytes']
        require(type(raw) is list and len(raw) <= 64 and all(number(b, 255) for b in raw) and
                type(row['receivedLength']) is int and row['receivedLength'] == len(raw) and
                type(row['reportID']) is int and row['reportID'] == 2 and row['registryID'] == registry and
                number(row['milliseconds'], 9007199254740991) and type(row['result']) is int and
                -2147483648 <= row['result'] <= 2147483647, 'Raw report byte/session/time/result invalid')
        item = {'milliseconds': row['milliseconds'], 'receivedLength': len(raw), 'result': row['result'],
                'fields': [], 'error': None, 'normalization': None}
        if row['result'] != 0:
            item['error'] = 'Input callback failed'
        elif descriptor is None:
            item['error'] = 'Descriptor missing; no layout guessed'
        else:
            payload = None
            if len(raw) == report['payloadBytes']:
                payload = bytes(raw);item['normalization'] = 'payload-only'
            elif len(raw) == report['bytesIncludingID'] and raw[0] == 2:
                payload = bytes(raw[1:]);item['normalization'] = 'includes-report-id'
            if payload is None:
                item['error'] = 'Raw length/ID disagrees with saved descriptor'
            else:
                try:
                    item['fields'] = decode(payload, report)
                except ValueError as error:
                    item['error'] = str(error)
        output.append(item)
    return {'format': 'CherryMacMouseObservationReview', 'version': 2, 'historicalOnly': True,
            'descriptorAvailable': descriptor is not None,
            'descriptorSHA256': hashlib.sha256(descriptor).hexdigest() if descriptor is not None else None,
            'registryID': registry, 'reportLayout': report, 'reportCount': len(rows),
            'reportsDecoded': sum(r['error'] is None for r in output),
            'reportsOutsideDeclaredRange': sum(any(not f['inDeclaredRange'] for f in r['fields']) for r in output),
            'reports': output, 'valueCorrelation': compare_values(session, output, registry),
            'hardwareExecutionPassed': False, 'powerCycleVerified': False,
            'limits': 'Saved descriptor interpretation only; not proof that firmware emitted intended movement, a macro passed, or a live keyboard is unchanged. No alternate firmware field order is substituted.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path)
    args = parser.parse_args()
    try:
        with args.session.open('rb') as handle:
            raw = handle.read(64000001)
        require(len(raw) <= 64000000, 'Observation session exceeds bounds')
        def invalid_constant(value):
            raise ValueError('Nonfinite JSON value')
        session = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
        result = inspect(session);result['sessionSHA256'] = hashlib.sha256(raw).hexdigest()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, RecursionError) as error:
        parser.exit(1, str(error) + '\n')
