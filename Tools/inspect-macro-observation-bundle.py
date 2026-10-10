#!/usr/bin/env python3
"""Check saved observer file bindings and mouse diagnostics without replay or HID.

Only fixed filenames inside the explicitly supplied folder are read. Does not
invoke an App, execute macro events, change logs, or validate physical playback.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat

spec = importlib.util.spec_from_file_location('cherrymac_mouse_review', Path(__file__).with_name('inspect-mouse-observation.py'))
mouse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mouse)
require = mouse.require
MAXIMUM = 64_000_000


def read_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        entry = os.fstat(fd)
        require(stat.S_ISREG(entry.st_mode) and entry.st_size <= MAXIMUM, 'Bundle file type/size invalid')
        with os.fdopen(fd, 'rb', closefd=False) as handle:
            data = handle.read(MAXIMUM+1)
        require(len(data) <= MAXIMUM, 'Bundle file exceeds bounds')
        return data
    finally:
        os.close(fd)


def invalid_constant(value):
    raise ValueError('Nonfinite JSON value')


def parse(data):
    return json.loads(data, object_pairs_hook=mouse.unique_object, parse_constant=invalid_constant)


def digest(value):
    return type(value) is str and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def inspect(folder):
    folder = folder.resolve(strict=True)
    require(folder.is_dir(), 'Observation folder invalid')
    session_bytes = read_file(folder / 'session.json')
    session = parse(session_bytes)
    diagnostic = mouse.inspect(session)
    phase = session.get('phase')
    require(phase in ('prepared', 'ready', 'observing', 'complete', 'failed'), 'Session phase invalid')
    artifacts = {'session.json': session_bytes}
    has_execution = 'executionSHA256' in session
    has_assessment = 'assessmentSHA256' in session
    require(has_execution == has_assessment, 'Session contains incomplete derived-file binding')
    binding = {'available': False, 'reason': 'No derived files bound by this saved session', 'reportedAssessment': None}
    issues = []
    if has_execution:
        require(digest(session['executionSHA256']) and digest(session['assessmentSHA256']), 'Derived hash invalid')
        for filename, key in [('execution.json', 'executionSHA256'), ('assessment.json', 'assessmentSHA256')]:
            data = read_file(folder / filename)
            require(hashlib.sha256(data).hexdigest() == session[key], 'Session hash differs from '+filename)
            artifacts[filename] = data
        execution = parse(artifacts['execution.json'])
        assessment = parse(artifacts['assessment.json'])
        require(type(execution) is dict and execution.get('format') == 'CherryMacMacroExecution' and
                type(execution.get('version')) is int and execution['version'] == 1, 'Execution format invalid')
        require(type(assessment) is dict and set(assessment) == {'format', 'version', 'inputSHA256', 'assessment'} and
                assessment['format'] == 'CherryMacMacroExecutionAssessment' and type(assessment['version']) is int and
                assessment['version'] == 1 and assessment['inputSHA256'] == session['executionSHA256'],
                'Assessment does not bind the saved execution')
        source = execution.get('source')
        require(source in ('hid', 'focusedBrowser', 'simulation'), 'Execution source invalid')
        start, end = execution.get('startedMilliseconds'), execution.get('assessedMilliseconds')
        require(mouse.number(start, 9007199254740991) and mouse.number(end, 9007199254740991) and end >= start,
                'Execution interval invalid')
        events = execution.get('events')
        require(type(events) is list and len(events) <= 65536, 'Execution event count invalid')
        previous = start
        for event in events:
            require(type(event) is dict and {'usage', 'pressed', 'milliseconds'} <= event.keys() <=
                    {'usage', 'pressed', 'milliseconds', 'kind'} and mouse.number(event['usage'], 255) and
                    type(event['pressed']) is bool and mouse.number(event['milliseconds'], end) and
                    event['milliseconds'] >= previous and event.get('kind') in (None, 'mouse', 'mouseX', 'mouseY'),
                    'Execution event structure/time invalid')
            previous = event['milliseconds']
        report = assessment['assessment']
        required = {'status', 'passed', 'source', 'scope', 'completedCycles', 'matchedEvents', 'observedEvents',
                    'eventsAfterStop', 'held', 'quietMilliseconds', 'requiredQuietMilliseconds'}
        require(type(report) is dict and required <= report.keys() <= required | {'stopSource', 'failure'} and
                report['status'] in ('passed', 'failed', 'waitingOutput', 'waitingStop', 'waitingRelease', 'waitingQuiet') and type(report['passed']) is bool and
                report['source'] == source and type(report['scope']) is str and len(report['scope']) <= 8192,
                'Reported assessment structure invalid')
        require(report.get('stopSource') in (None, 'physicalTriggerObserved', 'userAcknowledged', 'simulation') and
                (report.get('failure') is None or type(report['failure']) is str and len(report['failure']) <= 8192),
                'Reported assessment stop/failure invalid')
        for key in ['completedCycles', 'matchedEvents', 'observedEvents', 'eventsAfterStop', 'quietMilliseconds', 'requiredQuietMilliseconds']:
            require(mouse.number(report[key], 9007199254740991), 'Reported assessment counter invalid')
        require(type(report['held']) is list and len(report['held']) <= 512 and
                all(type(item) is str and len(item) <= 256 for item in report['held']), 'Held input list invalid')
        require(report['observedEvents'] == len(events), 'Assessment event count differs from execution')
        require(report['passed'] == (report['status'] == 'passed'), 'Reported passed/status contradict')
        if phase == 'complete' and not report['passed']:
            issues.append('Completed session has no reported passing assessment')
        if phase == 'failed' and report['passed']:
            issues.append('Failed session has a reported passing assessment')
        projection = session.get('rawValues')
        require(type(projection) is list and len(projection) <= 65536, 'Filtered value projection invalid')
        if len(projection) != len(events):
            issues.append('Filtered callback/event counts differ; failed observation can retain a rejected callback')
        else:
            for index, row in enumerate(projection):
                require(type(row) is dict and set(row) == {'page', 'usage', 'value', 'milliseconds'} and
                        mouse.number(row['page'], 4294967295) and mouse.number(row['usage'], 4294967295) and
                        type(row['value']) is int and -9223372036854775808 <= row['value'] <= 9223372036854775807 and
                        mouse.number(row['milliseconds'], 9007199254740991), 'Filtered callback fields invalid')
                if row['milliseconds'] != events[index]['milliseconds']:
                    issues.append('Filtered callback/event timestamps differ')
                    break
        binding = {'available': True, 'reason': None,
                   'reportedAssessment': {k: report[k] for k in ['status', 'passed', 'source', 'completedCycles', 'observedEvents']}}
    elif phase == 'complete':
        issues.append('Completed session has no hash-bound execution/assessment; no completion inferred')
    # Sampling is not a filesystem lock; keep each exact byte sequence unchanged
    # across the complete inspection rather than mixing concurrent save rounds.
    for filename, original in artifacts.items():
        require(read_file(folder / filename) == original, 'Bundle changed while inspecting: '+filename)
    return {'format': 'CherryMacMacroObservationBundleReview', 'version': 1, 'historicalOnly': True,
            'sessionPhase': phase, 'fileSHA256': {name: hashlib.sha256(raw).hexdigest() for name, raw in artifacts.items()},
            'derivedFileBinding': binding, 'issues': issues, 'mouseDiagnostic': diagnostic,
            'macroExecutionReplayed': False, 'hardwareExecutionPassed': False, 'onboardWriteVerified': False,
            'powerCycleVerified': False, 'authorizesHardwareOperation': False,
            'limits': 'Hash and structural consistency of saved files only, not signed authenticity or a locked snapshot. Reported pass is not recalculated; event semantics, active device, physical playback and power retention require separate acceptance.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.folder), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, RecursionError) as error:
        parser.exit(1, str(error)+'\n')
