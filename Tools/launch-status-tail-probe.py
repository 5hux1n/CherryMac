#!/usr/bin/env python3
"""Stage private logs locally before launching the fixed v4 read-only App.

No HID code. Runs only when explicitly invoked; collection never relaunches.
The protected staging directory remains available after interruption.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import time
import uuid


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        entry = os.fstat(fd)
        require(stat.S_ISREG(entry.st_mode) and entry.st_size <= maximum, '日志文件类型或大小无效。')
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        require(len(data) <= maximum, '日志超过上限。')
        return bytes(data)
    finally:
        os.close(fd)


def exclusive(path, raw):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        # Preserve an incomplete file as evidence; never overwrite on retry.
        raise
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    require(regular(path, len(raw)) == raw, '保存日志后的读回内容不一致。')


def save_identical(path, raw):
    try:
        exclusive(path, raw)
        return True
    except FileExistsError:
        require(regular(path, len(raw)) == raw, '已有记录内容不同，保留原文件，不覆盖。')
        return False


def analyzer(alias=False):
    path = Path(__file__).resolve().with_name('inspect-status-alias-receipt.py' if alias else 'inspect-status-tail-receipt.py')
    spec = importlib.util.spec_from_file_location('cherrymac_status_tail_review', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def collect(ticket_path):
    ticket = json.loads(regular(ticket_path, 8192))
    require(type(ticket) is dict and set(ticket) == {'format', 'version', 'operationID', 'stagingDirectory', 'receiptPath'},
            '启动记录格式无效。')
    require(ticket['format'] == 'CherryMacReadOnlyProbeLaunch' and type(ticket['version']) is int and ticket['version'] == 1,
            '启动记录版本无效。')
    require(str(uuid.UUID(ticket['operationID'])) == ticket['operationID'], '启动标识无效。')
    stage = Path(ticket['stagingDirectory'])
    require(stage.parent == Path('/tmp') and stage.name.startswith('cherrymac-readonly-'), '日志暂存位置无效。')
    entry = stage.lstat()
    require(stat.S_ISDIR(entry.st_mode) and entry.st_uid == os.getuid() and stat.S_IMODE(entry.st_mode) == 0o700,
            '日志暂存目录不属于当前用户或权限不私密。')
    source = stage / 'receipt.json'
    require(ticket['receiptPath'] == str(source), '日志路径与启动记录不一致。')
    if not source.exists():
        return {'status': 'awaiting-receipt', 'ticket': str(ticket_path), 'relaunchPerformed': False}
    raw = regular(source, 128000)
    review = analyzer()
    receipt = json.loads(raw, object_pairs_hook=review.unique_object, parse_constant=review.invalid_constant)
    require(type(receipt) is dict and receipt.get('format') == 'CherryMacReadOnlyProbe', '输出不是只读工具日志。')
    if receipt.get('status') not in ('complete', 'failed'):
        return {'status': 'receipt-not-terminal', 'ticket': str(ticket_path), 'relaunchPerformed': False}
    target = ticket_path.parent / ('status-tail-' + ticket['operationID'] + '.json')
    # Preserve the raw terminal receipt even when strict diagnosis rejects it.
    copied = save_identical(target, raw)
    diagnosis_path = ticket_path.parent / ('status-tail-review-' + ticket['operationID'] + '.json')
    try:
        if 'aliasCorrelationScope' in receipt:
            review = analyzer(alias=True)
        diagnosis = review.inspect(receipt)
        diagnosis['receiptSHA256'] = hashlib.sha256(raw).hexdigest()
    except (ValueError, TypeError, KeyError) as error:
        diagnosis = {'format': 'CherryMacStatusTailReceiptReviewFailure', 'version': 1,
                     'receiptSHA256': hashlib.sha256(raw).hexdigest(), 'error': str(error),
                     'completeBackupCreated': False, 'authorizesRestoreOrPairing': False}
    save_identical(diagnosis_path, (json.dumps(diagnosis, ensure_ascii=False, indent=2) + '\n').encode())
    return {'status': receipt['status'], 'receipt': str(target), 'review': str(diagnosis_path),
            'rawFileCreated': copied, 'diagnosisAccepted': diagnosis['format'] in ('CherryMacStatusTailReceiptReview', 'CherryMacStatusAliasReceiptReview'),
            'error': receipt.get('error'), 'relaunchPerformed': False}


def launch(app_path, output_directory, alias=False):
    app = app_path.resolve(strict=True)
    info = plistlib.loads(regular(app / 'Contents' / 'Info.plist', 16384))
    require(info.get('CFBundleIdentifier') == ('local.cherrymac.read-only-probe.v5' if alias else 'local.cherrymac.read-only-probe.v4') and
            info.get('CFBundleShortVersionString') == ('0.5.0' if alias else '0.4.0') and
            info.get('CFBundleExecutable') == 'CherryMacReadOnlyProbe', '需要与指定模式对应的独立v4／v5只读工具。')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    output_directory.mkdir(parents=True, exist_ok=True)
    out = output_directory.resolve(strict=True)
    operation = str(uuid.uuid4())
    stage = Path(tempfile.mkdtemp(prefix='cherrymac-readonly-', dir='/tmp'))
    os.chmod(stage, 0o700)
    receipt = stage / 'receipt.json'
    ticket = out / ('readonly-launch-' + operation + '.json')
    data = {'format': 'CherryMacReadOnlyProbeLaunch', 'version': 1, 'operationID': operation,
            'stagingDirectory': str(stage), 'receiptPath': str(receipt)}
    # Save launch intent before asking LaunchServices to open the App.
    exclusive(ticket, (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode())
    subprocess.run(['open', '-n', '-a', str(app), '--args', str(receipt), '--status-alias-correlation' if alias else '--status-tail-candidates'], check=True)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        if receipt.exists():
            result = collect(ticket)
            if result['status'] in ('complete', 'failed'):
                return result
        time.sleep(0.25)
    # An absent receipt is not evidence of a running App or permission grant.
    return {'status': 'awaiting-receipt', 'ticket': str(ticket), 'relaunchPerformed': False,
            'note': '只检查日志是否保存；未认定App仍在运行。授权完成后可单独收集，不自动重试查询。'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    start = actions.add_parser('launch')
    start.add_argument('app', type=Path)
    start.add_argument('output_directory', type=Path)
    start.add_argument('--alias-correlation', action='store_true', help='Requires the separate v5 App; fixed prefix comparisons only')
    saved = actions.add_parser('collect')
    saved.add_argument('ticket', type=Path)
    args = parser.parse_args()
    try:
        result = launch(args.app, args.output_directory, args.alias_correlation) if args.action == 'launch' else collect(args.ticket)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')
