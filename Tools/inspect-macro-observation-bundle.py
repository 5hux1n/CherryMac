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
import struct

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


def inspect_context(session, folder, artifacts):
    context = session.get('observationContext')
    if context is None:
        require('baselineSHA256' not in session and 'diagnosticEnd' not in session,
                'Context-less session has new context-dependent fields')
        return {'available': False, 'reason': 'Older or not-yet-configured session has no bound expectation'}
    require(type(context) is dict and set(context) == {'format', 'version', 'slot', 'binding', 'macro',
            'playback', 'source', 'startedMilliseconds', 'started'} and
            context['format'] == 'CherryMacMacroObservationContext' and type(context['version']) is int and
            context['version'] == 1 and type(context['slot']) is int and context['slot'] == 102 and
            context['source'] in ('hid', 'focusedBrowser', 'simulation') and type(context['started']) is bool and
            mouse.number(context['startedMilliseconds'], 9007199254740991), 'Observation context invalid')
    require(digest(session.get('baselineSHA256')), 'Observation baseline hash invalid')
    baseline = read_file(folder / 'baseline.json')
    require(hashlib.sha256(baseline).hexdigest() == session['baselineSHA256'], 'Baseline hash mismatch')
    artifacts['baseline.json'] = baseline
    profile = parse(baseline)
    require(type(profile) is dict and profile.get('format') == 'CherryMacProfile' and
            type(profile.get('snapshot')) is dict, 'Observation baseline profile invalid')
    snapshot = profile['snapshot']
    keys, bank = snapshot.get('keymap'), snapshot.get('macroData')
    require(type(keys) is list and len(keys) == 378 and all(mouse.number(x, 255) for x in keys) and
            type(bank) is list and len(bank) == 3071 and all(mouse.number(x, 255) for x in bank),
            'Observation baseline banks invalid')
    binding = context['binding']
    require(type(binding) is list and binding == keys[306:309] and
            all(mouse.number(x, 255) for x in binding), 'Observed binding differs from baseline')
    raw = bytes(bank)
    word = lambda offset: int.from_bytes(raw[offset:offset+2], 'little')
    length, count = word(2), word(4)
    require(raw[:2] == b'\xaa\x55' and 1 <= count <= 126 and 16+2*count <= length <= len(raw) and
            binding[0] in (0x70, 0x71) and binding[1] < count, 'Observed macro bank/reference invalid')
    record = None
    cursor = 16+2*count
    for index in range(count):
        offset = word(16+2*index)
        require(cursor <= offset and offset+4 <= length, 'Macro record overlaps or exceeds bank')
        steps = word(offset)
        end = offset+4+steps*4
        require(steps <= 762 and end <= length, 'Macro record event bounds invalid')
        if index == binding[1]:
            record = raw[offset+4:end]
        cursor = end
    macro = context['macro']
    require(type(macro) is dict and type(macro.get('name')) is str and 0 < len(macro['name']) <= 80 and
            type(macro.get('steps')) is list and len(macro['steps']) <= 762, 'Expected macro invalid')
    encoded = bytearray()
    movement = False
    for step in macro['steps']:
        require(type(step) is dict and {'usage', 'pressed', 'delayMilliseconds'} <= step.keys() <=
                {'usage', 'pressed', 'delayMilliseconds', 'kind'} and mouse.number(step['usage'], 255) and
                type(step['pressed']) is bool and mouse.number(step['delayMilliseconds'], 60000) and
                step.get('kind') in (None, 'mouse', 'mouseX', 'mouseY'), 'Expected macro step invalid')
        kind, code = step.get('kind'), step['usage']
        movement |= kind in ('mouseX', 'mouseY')
        if kind == 'mouse':
            require(code in (1, 2, 4, 8, 16), 'Expected mouse button invalid')
        elif kind is None:
            require(4 <= code <= 231, 'Expected keyboard usage invalid')
        type_byte = {'mouse': 1, 'mouseX': 4, 'mouseY': 5}.get(kind, 9 if code >= 224 else 10)
        if kind is None and code >= 224:
            code = 1 << (code-224)
        encoded.extend(struct.pack('<HBB', step['delayMilliseconds'], type_byte | (0x80 if step['pressed'] else 0), code))
    require(bytes(encoded) == record, 'Expected steps differ from selected baseline macro record')
    mode = context['playback']
    expected = {'mode': ('count', 'held', 'toggle')[binding[2]], 'count': 1} if binding[0] == 0x70 and binding[2] <= 2 else \
               {'mode': 'count', 'count': binding[2]} if binding[0] == 0x71 and binding[2] >= 2 else None
    require(type(mode) is dict and set(mode) == {'mode', 'count'} and type(mode['count']) is int and
            expected is not None and mode == expected, 'Expected playback differs from baseline binding')
    diagnostic_only = not macro['steps'] or movement
    require(session.get('diagnosticOnly') == diagnostic_only, 'Diagnostic flag differs from expected macro')
    ending = session.get('diagnosticEnd')
    if ending is not None:
        require(diagnostic_only and context['started'] and type(ending) is dict and
                set(ending) == {'milliseconds', 'source', 'physicalTriggerVerified', 'quietIntervalVerified'} and
                mouse.number(ending['milliseconds'], 9007199254740991) and
                ending['milliseconds'] >= context['startedMilliseconds'] and ending['source'] == 'userAcknowledged' and
                ending['physicalTriggerVerified'] is False and ending['quietIntervalVerified'] is False,
                'Diagnostic ending invalid or claims unsupported verification')
    if session['phase'] == 'diagnosticComplete':
        require(ending is not None, 'Completed contextual diagnostic lacks its ending marker')
    for field in ('rawValues', 'rawMouseReports', 'rawMouseValues'):
        rows = session.get(field, [])
        require(type(rows) is list and len(rows) <= 65536, 'Contextual observation rows invalid')
        for row in rows:
            require(context['started'] and type(row) is dict and
                    mouse.number(row.get('milliseconds'), 9007199254740991) and
                    row['milliseconds'] >= context['startedMilliseconds'] and
                    (ending is None or row['milliseconds'] <= ending['milliseconds']),
                    'Observation lies outside contextual interval')
    return {'available': True, 'baselineHashMatched': True, 'bindingAndStepsMatched': True,
            'slot': 102, 'eventCount': len(macro['steps']), 'containsMovement': movement,
            'playback': mode, 'source': context['source'], 'started': context['started'],
            'diagnosticEnd': ending, 'physicalTriggerVerified': False, 'hardwareExecutionPassed': False}


def inspect(folder):
    folder = folder.resolve(strict=True)
    require(folder.is_dir(), 'Observation folder invalid')
    session_bytes = read_file(folder / 'session.json')
    session = parse(session_bytes)
    diagnostic = mouse.inspect(session)
    phase = session.get('phase')
    require(phase in ('prepared', 'ready', 'observing', 'complete', 'diagnosticComplete', 'failed'), 'Session phase invalid')
    diagnostic_only = session.get('diagnosticOnly', False)
    require(type(diagnostic_only) is bool and (phase != 'diagnosticComplete' or diagnostic_only), 'Diagnostic phase/flag invalid')
    artifacts = {'session.json': session_bytes}
    context = inspect_context(session, folder, artifacts)
    has_execution = 'executionSHA256' in session
    has_assessment = 'assessmentSHA256' in session
    require(has_execution == has_assessment, 'Session contains incomplete derived-file binding')
    binding = {'available': False, 'reason': 'Diagnostic-only capture has no execution assessment' if diagnostic_only else 'No derived files bound by this saved session', 'reportedAssessment': None}
    issues = []
    require(not diagnostic_only or not has_execution, 'Diagnostic-only capture unexpectedly binds an execution assessment')
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
        if context['available']:
            expected_context = session['observationContext']
            require(expected_context['started'] and expected_context['source'] == source and
                    expected_context['startedMilliseconds'] == start and
                    expected_context['macro'] == execution.get('macro') and
                    expected_context['playback'] == execution.get('playback'),
                    'Execution differs from hash-bound baseline expectation')
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
    return {'format': 'CherryMacMacroObservationBundleReview', 'version': 2, 'historicalOnly': True,
            'sessionPhase': phase, 'diagnosticOnly': diagnostic_only, 'fileSHA256': {name: hashlib.sha256(raw).hexdigest() for name, raw in artifacts.items()},
            'derivedFileBinding': binding, 'observationContext': context, 'issues': issues, 'mouseDiagnostic': diagnostic,
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
