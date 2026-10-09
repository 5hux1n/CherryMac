#!/usr/bin/env python3
"""Inspect a v4 probe's saved candidate receipt; no USB, writes or tail promotion."""
import argparse
import hashlib
import json
from pathlib import Path

IMAGE_SHA = '31d0a07361ad531fa16867412d46e496737b126efc90482f86baa7e6bd5051bd'
INFO_SHA = 'df2355e97afdcb63f8485c1dcf8719615b7ad52c2e190230f1e8125da918c7fa'
SCOPE = 'parameters/colors/macroData single-byte0104 aliases only'
REGIONS = [('parameters', 63, 127), ('colors', 511, 639), ('macroData', 3071, 21587)]
SEQUENCE = [(3, 0, 34)] + [(29, offset, 1) for _, _, offset in REGIONS] + [(3, 0, 34)]
SEQUENCE += [(29, offset, 1) for _, _, offset in REGIONS] + [(3, 0, 34)]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, maximum):
    return type(value) is int and 0 <= value <= maximum


def octets(value, count):
    return type(value) is list and len(value) == count and all(integer(b, 255) for b in value)


def text(value):
    return type(value) is str and 0 < len(value.encode('utf-8')) <= 8192


def request(command, offset, count):
    data = [0] * 64
    data[0], data[3], data[4] = 4, command, count
    data[5], data[6] = offset & 255, offset >> 8
    checksum = sum(data[3:])
    data[1], data[2] = checksum & 255, checksum >> 8
    return data


def inspect(value):
    required = {'format', 'version', 'keyboardWritesPerformed', 'queries', 'candidateEvidence', 'status'}
    allowed = required | {'identity', 'error', 'candidateReadsCompared', 'completeBackupCreated'}
    require(type(value) is dict and required <= value.keys() <= allowed, '不是完整的候选读取日志结构。')
    require(value['format'] == 'CherryMacReadOnlyProbe' and type(value['version']) is int and value['version'] == 1,
            '只读日志格式或版本无效。')
    require(value['keyboardWritesPerformed'] is False, '日志未声明未写入。')
    evidence = value['candidateEvidence']
    expected = {'sourceImageSHA256': IMAGE_SHA, 'deviceInfoSHA256': INFO_SHA,
                'runningFirmwareIdentityProved': False, 'completeBackupCreated': False,
                'keymapTailRead': False, 'scope': SCOPE}
    require(type(evidence) is dict and evidence.keys() == expected.keys() and
            all(type(evidence[k]) is type(v) and evidence[k] == v for k, v in expected.items()),
            '候选来源或范围声明不匹配。')
    require(value['status'] in ('failed', 'complete'), '仅接受结束后保存的日志。')
    if 'error' in value:
        require(text(value['error']), '日志错误信息无效。')
    if value['status'] == 'failed':
        require('error' in value, '失败日志缺少错误原因。')
    else:
        require('error' not in value, '完成日志包含未解决错误。')
    identity = value.get('identity')
    if identity is not None:
        require(type(identity) is dict and identity.keys() ==
                {'vendorID', 'productID', 'transport', 'registryID', 'usbRevision'}, 'USB身份字段不完整。')
        require(type(identity['vendorID']) is int and identity['vendorID'] == 0x046a and
                type(identity['productID']) is int and identity['productID'] == 0x01ce and
                identity['transport'] == 'USB' and integer(identity['usbRevision'], 65535), '不是目标USB键盘。')
        token = identity['registryID']
        require(type(token) is str and token.isascii() and token.isdecimal() and
                token == str(int(token)) and 0 < int(token) <= 18446744073709551615, 'USB会话标识无效。')
    rows = value['queries']
    require(type(rows) is list and len(rows) <= len(SEQUENCE), '候选查询数量无效。')
    if rows:
        require(identity is not None, '实际查询缺少USB会话身份。')
    summaries, infos, observed = [], [], {}
    for index, row in enumerate(rows):
        base = {'command', 'offset', 'length', 'request', 'status'}
        require(type(row) is dict and base <= row.keys() <= base | {'data', 'reply', 'error'}, '查询含未知字段。')
        command, offset, count = SEQUENCE[index]
        require(all(type(row[k]) is int and row[k] == expected for k, expected in
                    [('command', command), ('offset', offset), ('length', count)]), '查询次序或固定范围不同。')
        require(octets(row['request'], 64) and row['request'] == request(command, offset, count), '请求不是固定候选帧。')
        status = row['status']
        require(status in ('prepared', 'accepted', 'failed'), '查询状态无效。')
        require(status == 'accepted' or index == len(rows) - 1, '中断后仍有后续查询。')
        if 'data' in row:
            require(octets(row['data'], count), '查询数据长度或字节无效。')
        if 'reply' in row:
            require(octets(row['reply'], 64), '原始回复不是64字节。')
        if 'error' in row:
            require(text(row['error']), '查询错误信息无效。')
        if status == 'prepared':
            require(row.keys() == base, '未完成意图包含结果字段。')
        elif status == 'failed':
            require('error' in row, '失败查询缺少原因。')
            if 'data' in row:
                require('reply' in row and row['data'] == row['reply'][8:8+count], '失败记录的数据与原始回复矛盾。')
        else:
            require(row.keys() == base | {'data', 'reply'}, '已接受查询缺少原始结果。')
            require(row['reply'][:8] == row['request'][:8] and
                    row['data'] == row['reply'][8:8+count], '接受记录的回复或数据不匹配。')
            if command == 3:
                require(hashlib.sha256(bytes(row['data'])).hexdigest() == INFO_SHA, '设备信息不匹配候选来源。')
                require(not infos or row['data'] == infos[0], '已接受的设备信息变化。')
                infos.append(row['data'])
            else:
                require(infos, '设备信息核对前发送了候选请求。')
                previous = observed.setdefault(offset, [])
                require(not previous or row['data'] == previous[0], '已接受的两遍候选数据不一致。')
                previous.append(row['data'])
        summaries.append({'sequence': index+1, 'command': command, 'offset': offset,
                          'status': status, 'replyStatusByte': row.get('reply', [None]*64)[7],
                          'error': row.get('error')})
    complete = value['status'] == 'complete'
    require(not complete or len(rows) == 9 and all(r['status'] == 'accepted' for r in rows),
            '完成声明与实际九次查询不一致。')
    if complete:
        require(value.get('candidateReadsCompared') is True and value.get('completeBackupCreated') is False,
                '完成声明缺少比较结果或误称完整备份。')
    else:
        require('candidateReadsCompared' not in value and 'completeBackupCreated' not in value,
                '失败记录错误声明完整比较。')
    return {'format': 'CherryMacStatusTailReceiptReview', 'version': 1,
            'historicalOnly': True, 'outcome': 'two-pass-candidates-observed' if complete else 'interrupted',
            'queriesRecorded': len(rows), 'acceptedQueries': sum(r['status'] == 'accepted' for r in rows),
            'deviceInfoComparisonsComplete': len(infos) == 3, 'failure': value.get('error'),
            'regions': [{'region': name, 'regionOffset': position, 'statusReadOffset': offset,
                         'acceptedPasses': len(observed.get(offset, [])),
                         'observedByte': observed[offset][0][0] if offset in observed else None,
                         'twoPassAgreement': len(observed.get(offset, [])) == 2}
                        for name, position, offset in REGIONS],
            'queries': summaries, 'keymapTailObserved': False, 'completeBackupCreated': False,
            'runningFirmwareIdentityProved': False, 'currentConfigurationVerified': False,
            'authorizesRestoreOrPairing': False,
            'limits': '保存的旧0104别名候选观察记录；不是当前配置、完整四区备份、无线身份备份或断电验收。'}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'JSON含重复字段。')
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError('JSON含非有限数值。')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('receipt', type=Path, help='Private saved v4 candidate JSON; never uploads it')
    args = parser.parse_args()
    try:
        with args.receipt.open('rb') as handle:
            raw = handle.read(128001)
        require(len(raw) <= 128000, '日志超过128KB。')
        value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
        report = inspect(value)
        report['receiptSHA256'] = hashlib.sha256(raw).hexdigest()
        print(json.dumps(report, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, UnicodeError, RecursionError) as error:
        parser.exit(1, str(error) + '\n')
