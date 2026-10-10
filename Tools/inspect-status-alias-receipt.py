#!/usr/bin/env python3
"""Inspect fixed v5 alias-prefix comparisons; never promote them to a backup."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('cherrymac_tail_receipts', Path(__file__).with_name('inspect-status-tail-receipt.py'))
common = importlib.util.module_from_spec(spec)
spec.loader.exec_module(common)
require, octets, integer = common.require, common.octets, common.integer
unique_object, invalid_constant = common.unique_object, common.invalid_constant
# region, segment, ordinary command/offset/count, status offset/count
WINDOWS = [
    ('parameters', 'front', 5, 0, 56, 64, 56),
    ('parameters', 'tail', 5, 56, 7, 120, 8),
    ('colors', 'front', 10, 0, 56, 128, 56),
    ('colors', 'tail', 10, 456, 55, 584, 56),
    ('macroData', 'front', 20, 0, 54, 18516, 54),
    ('macroData', 'tail', 20, 3018, 53, 21534, 54),
]
PASS = [item for _, _, command, offset, count, candidate, length in WINDOWS
        for item in [(command, offset, count), (29, candidate, length)]] + [(3, 0, 34)]
SEQUENCE = [(3, 0, 34)] + PASS + PASS


def inspect(value):
    base = {'format', 'version', 'keyboardWritesPerformed', 'queries', 'aliasCorrelationScope', 'status'}
    require(type(value) is dict and base <= value.keys() <= base | {'identity', 'error', 'aliasPrefixesCompared', 'completeBackupCreated'},
            '别名比较日志字段无效。')
    require(value['format'] == 'CherryMacReadOnlyProbe' and type(value['version']) is int and value['version'] == 1 and
            value['keyboardWritesPerformed'] is False and value['aliasCorrelationScope'] == 'fixed0104 alias prefix correlation only',
            '不是固定v5只读比较日志。')
    require(value['status'] in ('failed', 'complete'), '只分析终态日志。')
    complete = value['status'] == 'complete'
    require(('error' not in value) if complete else common.text(value.get('error')), '终态错误信息不一致。')
    if complete:
        require(value.get('aliasPrefixesCompared') is True and value.get('completeBackupCreated') is False, '完成声明无效。')
    else:
        require('aliasPrefixesCompared' not in value and 'completeBackupCreated' not in value, '失败日志错误声明比较完成。')
    identity = value.get('identity')
    if identity is not None:
        require(type(identity) is dict and set(identity) == {'vendorID', 'productID', 'transport', 'registryID', 'usbRevision'}, 'USB身份字段无效。')
        require(type(identity['vendorID']) is int and identity['vendorID'] == 0x046a and
                type(identity['productID']) is int and identity['productID'] == 0x01ce and identity['transport'] == 'USB' and
                integer(identity['usbRevision'], 65535), '目标USB身份无效。')
        token = identity['registryID']
        require(type(token) is str and token.isascii() and token.isdecimal() and token == str(int(token)) and
                0 < int(token) <= 18446744073709551615, 'USB会话标识无效。')
    rows = value['queries']
    require(type(rows) is list and len(rows) <= 27 and (not rows or identity is not None), '查询数量或身份缺失。')
    if complete:
        require(len(rows) == 27, '完成声明缺少27条固定查询。')
    infos, observed, summaries = [], {}, []
    for index, row in enumerate(rows):
        command, offset, count = SEQUENCE[index]
        fields = {'command', 'offset', 'length', 'request', 'status'}
        require(type(row) is dict and fields <= row.keys() <= fields | {'data', 'reply', 'error'}, '查询字段无效。')
        require(all(type(row[k]) is int and row[k] == expected for k, expected in
                    [('command', command), ('offset', offset), ('length', count)]), '查询次序或范围不同。')
        require(octets(row['request'], 64) and row['request'] == common.request(command, offset, count), '请求不是固定比较帧。')
        state = row['status']
        require(state in ('prepared', 'accepted', 'failed') and (state == 'accepted' or index == len(rows)-1), '中断后继续了查询。')
        if 'data' in row:
            require(octets(row['data'], count), '数据长度无效。')
        if 'reply' in row:
            require(octets(row['reply'], 64), '回复长度无效。')
        if state == 'prepared':
            require(set(row) == fields, '未完成记录含结果。')
        elif state == 'failed':
            require(common.text(row.get('error')), '失败记录缺原因。')
            if 'data' in row:
                require('reply' in row and row['data'] == row['reply'][8:8+count], '失败数据与原始回复不同。')
        else:
            require(set(row) == fields | {'data', 'reply'} and row['reply'][:8] == row['request'][:8] and
                    row['data'] == row['reply'][8:8+count], '接受记录不匹配原始回复。')
            key = (command, offset, count)
            if command == 3:
                require(hashlib.sha256(bytes(row['data'])).hexdigest() == common.INFO_SHA and
                        (not infos or row['data'] == infos[0]), '设备信息变化或不匹配。')
                infos.append(row['data'])
            else:
                require(infos, '未核对设备信息就读取候选。')
                previous = observed.setdefault(key, [])
                require(not previous or row['data'] == previous[0], '两遍读取内容不同。')
                if command == 29:
                    window = next(w for w in WINDOWS if w[5:7] == (offset, count))
                    ordinary = observed.get(tuple(window[2:5]), [])
                    expected_pass = (index - 1) // len(PASS) + 1
                    require(len(ordinary) == expected_pass and ordinary[-1] == row['data'][:window[4]],
                            '候选已知前缀与本轮正常读取不同。')
                previous.append(row['data'])
        summaries.append({'sequence': index+1, 'command': command, 'offset': offset, 'status': state,
                          'replyStatusByte': row.get('reply', [None]*64)[7], 'error': row.get('error')})
    require(not complete or all(r['status'] == 'accepted' for r in rows), '完成日志包含中断查询。')
    windows = []
    for region, segment, cmd, offset, count, candidate, length in WINDOWS:
        normal, alias = observed.get((cmd, offset, count), []), observed.get((29, candidate, length), [])
        known = normal[0] if normal else []
        windows.append({'region': region, 'segment': segment, 'knownByteCount': count,
                        'ordinaryAcceptedPasses': len(normal), 'candidateAcceptedPasses': len(alias),
                        'twoPassPrefixAgreement': len(normal) == len(alias) == 2,
                        'nonzeroKnownBytes': sum(b != 0 for b in known), 'distinctKnownValues': len(set(known)),
                        'observedExtraByte': alias[0][-1] if alias and length > count else None,
                        'allZeroPrefix': bool(known) and not any(known)})
    return {'format': 'CherryMacStatusAliasReceiptReview', 'version': 1, 'historicalOnly': True,
            'outcome': 'two-pass-prefixes-match' if complete else 'interrupted', 'failure': value.get('error'),
            'queriesRecorded': len(rows), 'acceptedQueries': sum(r['status'] == 'accepted' for r in rows),
            'deviceInfoComparisonsComplete': len(infos) == 3, 'windows': windows, 'queries': summaries,
            'keymapTailObserved': False, 'completeBackupCreated': False, 'runningFirmwareIdentityProved': False,
            'currentConfigurationVerified': False, 'authorizesRestoreOrPairing': False,
            'limits': '仅历史固定窗口相关性；全零前缀可能偶然一致，未证明当前固件别名、完整配置、无线身份或恢复资格。'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path)
    args = parser.parse_args()
    try:
        with args.receipt.open('rb') as handle:
            raw = handle.read(128001)
        require(len(raw) <= 128000, '日志超过128KB。')
        value = json.loads(raw, object_pairs_hook=common.unique_object, parse_constant=common.invalid_constant)
        result = inspect(value)
        result['receiptSHA256'] = hashlib.sha256(raw).hexdigest()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, StopIteration, UnicodeError, RecursionError) as error:
        parser.exit(1, str(error) + '\n')
