#!/usr/bin/env python3
"""Inspect a saved request.json/stop.json pair, without replay or device access."""
import argparse
import hashlib
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('cherrymac_saved_observer_files',
                                           Path(__file__).with_name('inspect-macro-observation-bundle.py'))
files = importlib.util.module_from_spec(spec)
spec.loader.exec_module(files)
require = files.require
number = files.mouse.number


def inspect(folder):
    folder = folder.resolve(strict=True)
    require(folder.is_dir(), 'Stop record folder invalid')
    artifacts = {name: files.read_file(folder/name) for name in ('request.json', 'stop.json')}
    request, record = (files.parse(artifacts[name]) for name in ('request.json', 'stop.json'))
    require(type(record) is dict and record.get('format') == 'CherryMacPhysicalMacroStop' and
            type(record.get('version')) is int and record['version'] in (1, 2), 'Stop record format invalid')
    require(type(request) is dict and request.get('phase') in ('beforeWrite', 'recovery') and
            record.get('phase') == request['phase'], 'Request/record phase differs')
    configurations, requirements = request.get('configurations'), request.get('requirements')
    count = 1 if request['phase'] == 'beforeWrite' else 2
    require(type(configurations) is list and len(configurations) == count and
            type(requirements) is list and len(requirements) == count and
            all(type(x) is dict for x in configurations+requirements), 'Stop request structure invalid')
    # These summaries remain declared metadata; don't pretend to recompute
    # firmware cancellation or replay a user's stored macros here.
    quiet, last = record.get('quietMilliseconds'), record.get('lastActivityMilliseconds')
    require(number(quiet, 9007199254740991) and quiet >= 200 and
            number(last, 9007199254740991), 'Quiet interval or last activity invalid')
    bound = False
    if record['version'] == 2:
        require(files.digest(record.get('requestSHA256')) and
                record['requestSHA256'] == hashlib.sha256(artifacts['request.json']).hexdigest(),
                'Stop record does not bind the exact saved request')
        bound = True
    else:
        require('requestSHA256' not in record, 'Legacy version unexpectedly contains v2 binding')
    rows = record.get('events')
    require(type(rows) is list and len(rows) <= 65536, 'Stop event count invalid')
    relative_count = 0
    for row in rows:
        require(type(row) is dict and number(row.get('page'), 4294967295) and
                number(row.get('usage'), 4294967295) and type(row.get('value')) is int and
                -9223372036854775808 <= row['value'] <= 9223372036854775807 and
                number(row.get('milliseconds'), last), 'Stop callback fields/time invalid')
        if row.get('activityKind') == 'relativeAxis':
            required = {'page', 'usage', 'value', 'milliseconds', 'activityKind', 'reportID',
                        'logicalMinimum', 'logicalMaximum', 'relative'}
            require(record['version'] == 2 and set(row) == required and row['page'] == 1 and
                    row['usage'] in (0x30, 0x31, 0x38) and type(row['reportID']) is int and
                    row['reportID'] == 2 and row['relative'] is True and
                    type(row['logicalMinimum']) is int and type(row['logicalMaximum']) is int and
                    -32768 <= row['logicalMinimum'] <= 0 <= row['logicalMaximum'] <= 32767 and
                    row['value'] != 0 and row['logicalMinimum'] <= row['value'] <= row['logicalMaximum'],
                    'Relative activity does not match its recorded declaration')
            relative_count += 1
        else:
            require(set(row) == {'page', 'usage', 'value', 'milliseconds', 'pressed'} and
                    type(row['pressed']) is bool and row['value'] in (0, 1) and
                    row['pressed'] == bool(row['value']) and
                    (row['page'] == 7 and 4 <= row['usage'] <= 231 or row['page'] == 9 and 1 <= row['usage'] <= 5),
                    'Button callback structure invalid')
    if relative_count:
        registry = record.get('registryID')
        require(type(registry) is str and registry.isascii() and registry.isdecimal() and
                registry == str(int(registry)) and 0 < int(registry) <= 18446744073709551615,
                'Relative activity lacks a recorded USB registry identity')
    result = record.get('result')
    require(result in (None, 'acknowledged', 'failed'), 'Stop result invalid')
    acknowledged = record.get('userConfirmedStopped', False)
    require(type(acknowledged) is bool, 'User confirmation flag invalid')
    if result == 'acknowledged':
        clicked = record.get('acknowledgedMilliseconds')
        drained = record.get('postAcknowledgementQuietMilliseconds')
        require(acknowledged and number(clicked, 9007199254740991) and clicked-last >= quiet and
                number(drained, 9007199254740991) and drained >= 250 and 'error' not in record,
                'Acknowledged result lacks the declared quiet/confirmation interval')
        if record['version'] == 2:
            require(record.get('pendingUserConfirmationMilliseconds') == clicked and
                    type(record.get('pendingUserConfirmationMilliseconds')) is int,
                    'Acknowledgement differs from recorded intent')
    else:
        require(not acknowledged, 'Non-acknowledged result claims user confirmation')
    if result == 'failed':
        require(type(record.get('error')) is str and 0 < len(record['error']) <= 8192,
                'Failed stop record lacks an error')
    for name, original in artifacts.items():
        require(files.read_file(folder/name) == original, 'Stop pair changed during inspection: '+name)
    return {'format': 'CherryMacMacroStopReview', 'version': 1, 'historicalOnly': True,
            'recordVersion': record['version'], 'requestHashMatched': bound,
            'legacyBindingMissing': not bound, 'phase': record['phase'],
            'recordedResult': result, 'recordedUserAcknowledgement': acknowledged,
            'events': len(rows), 'relativeActivityEvents': relative_count,
            'fileSHA256': {name: hashlib.sha256(raw).hexdigest() for name, raw in artifacts.items()},
            'macroRequirementsRecalculated': False, 'currentDeviceVerified': False,
            'internalFirmwareStopped': False, 'hardwareExecutionPassed': False,
            'powerCycleVerified': False, 'authorizesHardwareOperation': False,
            'limits': 'Historical file consistency only. Recorded descriptor metadata/registry values are not '
                      'live identity or authenticated HID evidence. Declared quiet budget is not recomputed; '
                      'reported acknowledgement is not permission to write or proof of internal cancellation. '
                      'Repeated file reads are not a filesystem lock or power-loss guarantee.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    try:
        print(files.json.dumps(inspect(args.folder), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, RecursionError) as error:
        parser.exit(1, str(error)+'\n')
