#!/usr/bin/env python3
"""Offline USBPcap Report-4 extraction; never capture, open HID or replay.

USBPcap layout: https://desowin.org/usbpcap/captureformat.html
DLT 249: https://github.com/desowin/usbpcap/blob/master/USBPcapDriver/include/USBPcap.h
Only classic pcap is supported. Export pcapng to pcap without capturing again.
Bus/address selection is explicit; it is NOT a VID/PID or firmware identity proof.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import stat
import struct


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect(path, bus, device):
    require(1 <= bus <= 65535 and 1 <= device <= 127, "需要明确的 USB bus 和设备地址。")
    # Reject FIFOs/devices after opening without waiting for a writer.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        initial = os.fstat(handle.fileno())
        require(stat.S_ISREG(initial.st_mode) and 24 <= initial.st_size <= 256_000_000,
                "需要不超过 256 MB 的普通 pcap 文件。")
        digest = hashlib.sha256()

        def read(length):
            data = handle.read(length)
            require(len(data) == length, "抓包文件截断；不输出部分成功结果。")
            digest.update(data)
            return data

        header = read(24)
        formats = {b"\xd4\xc3\xb2\xa1": ("<", 1_000_000),
                   b"\xa1\xb2\xc3\xd4": (">", 1_000_000),
                   b"\x4d\x3c\xb2\xa1": ("<", 1_000_000_000),
                   b"\xa1\xb2\x3c\x4d": (">", 1_000_000_000)}
        require(header[:4] in formats, "仅支持经典 pcap；pcapng 请先离线另存为 pcap。")
        endian, resolution = formats[header[:4]]
        major, minor, _, _, snaplen, linktype = struct.unpack(endian+"HHIIII", header[4:])
        require((major, minor) == (2, 4) and linktype == 249 and 0 < snaplen <= 16_000_000,
                "需要 USBPcap（LINKTYPE 249）的 pcap 2.4 文件。")
        packets = 0
        selected = 0
        frames = []
        issues = []
        counts = collections.Counter()
        pending_out = {}
        completion_counts = collections.Counter()
        opaque_groups = {}

        def register_out(irp, record):
            if irp == 0:
                record['usbCompletionAssociation'] = 'unusable-zero-IRP'
                completion_counts['submissions-with-zero-IRP'] += 1
                return
            active = pending_out.setdefault(irp, [])
            if active:
                record['usbCompletionAssociation'] = 'ambiguous-active-IRP'
                for old in active:
                    old['usbCompletionAssociation'] = 'ambiguous-active-IRP'
            # Two entries already prove ambiguity; retain no unbounded list
            # of repeated submissions for the same pointer.
            if len(active) < 2:
                active.append(record)
        while handle.tell() < initial.st_size:
            packets += 1
            require(packets <= 1_000_000, "抓包超过一百万包，请先离线筛选。")
            sec, subsecond, captured, original = struct.unpack(endian+"IIII", read(16))
            require(subsecond < resolution and captured <= original and captured <= snaplen,
                    "pcap 时间或长度字段无效。")
            require(captured <= initial.st_size-handle.tell(), "pcap 包超出文件范围。")
            packet = read(captured)
            require(len(packet) >= 27, "USBPcap 基本头截断。")
            size, irp, status, function, info, packet_bus, address, endpoint, transfer, data_length = \
                struct.unpack("<HQIHBHHBBI", packet[:27])
            if (packet_bus, address) != (bus, device):
                continue
            selected += 1
            require(27 <= size <= len(packet) and info in (0, 1), "所选设备 USBPcap 头无效。")
            require(captured == original and data_length == len(packet)-size,
                    "所选设备含截断或不匹配的 payload，不能用于完整通信分析。")
            payload = packet[size:]
            stage = None
            setup = None
            source = None
            if transfer == 1:
                # OUT payload is on submission; IN payload is on completion.
                if (endpoint & 0x80) == 0 and info == 0:
                    source = "interrupt-out-submission"
                elif endpoint & 0x80 and info == 1:
                    source = "interrupt-in-completion"
            elif transfer == 2:
                require(size >= 28, "控制传输缺少 stage。")
                stage = packet[27]
                require(stage in (0, 1, 2, 3), "未知控制传输 stage。")
                if stage == 0:
                    require(len(payload) >= 8, "控制 SETUP 截断。")
                    request_type, request, value, interface, length = struct.unpack("<BBHHH", payload[:8])
                    setup = {"requestType": request_type, "request": request,
                             "value": value, "interface": interface, "length": length}
                    # HID SET_REPORT, output type 2, report ID 4. No guessed
                    # decoding of Feature reports or an unobserved control DATA.
                    if info == 0 and request_type == 0x21 and request == 9 and value == 0x0204:
                        body = payload[8:]
                        if length == len(body) == 64 and body[0] == 4:
                            payload = body
                            source = "control-set-output-report"
                        else:
                            require(len(issues) < 10_000, "所选通信异常超过分析上限。")
                            issues.append({"packet": packets, "setup": setup,
                                           "observedDataLength": len(body),
                                           "observedDataHex": body.hex() if len(body) <= 64 else None,
                                           "observedDataSHA256": hashlib.sha256(body).hexdigest(),
                                           "issue": "SET_REPORT 不是可直接解码的64字节Report4；保留原始片段，不填补Report ID或数据。"})
                # Completed control data is left opaque without its SETUP
                # correlation. Do not mistake its leading byte for report ID.
            is_out_completion = info == 1 and ((transfer == 1 and not endpoint & 0x80) or
                                               (transfer == 2 and not endpoint & 0x80 and stage in (2, 3)))
            if is_out_completion:
                pending = pending_out.get(irp)
                if pending is None:
                    completion_counts['without-decoded-out-submission'] += 1
                elif len(pending) != 1:
                    # An IRP pointer may be reused. Multiple active submissions
                    # cannot be assigned to a single completion by proximity.
                    for old in pending:
                        old['usbCompletionAssociation'] = 'ambiguous-active-IRP'
                    del pending_out[irp]
                    completion_counts['ambiguous-active-IRP'] += 1
                else:
                    old = pending[0]
                    expected_transfer = 2 if old['source'] == 'control-set-output-report' else 1
                    if endpoint != old['endpoint'] or function != old['urbFunction'] or transfer != expected_transfer:
                        old['usbCompletionAssociation'] = 'metadata-mismatch-observed'
                        del pending_out[irp]
                        completion_counts['metadata-mismatch-observed'] += 1
                    else:
                        if old.get('decodedReport4', True):
                            old['usbCompletion'] = {'packet': packets, 'timestampSeconds': sec,
                                'timestampFraction': subsecond, 'timestampResolution': resolution,
                                'usbStatus': status, 'controlStage': stage,
                                'classification': 'host-controller completion only; not a keyboard acknowledgement'}
                            old['usbCompletionAssociation'] = 'matched-IRP-and-transfer-metadata'
                            completion_counts['matched'] += 1
                        else:
                            completion_counts['without-decoded-out-submission'] += 1
                        del pending_out[irp]
            if source is None or len(payload) != 64 or payload[0] != 4:
                # Track opaque submissions too, so another transfer reusing
                # an active IRP cannot complete a decoded Report-4 by mistake.
                if info == 0 and ((transfer == 1 and not endpoint & 0x80) or
                                  (transfer == 2 and stage == 0 and setup is not None and
                                   not setup['requestType'] & 0x80)):
                    register_out(irp, {'decodedReport4': False, 'endpoint': endpoint,
                        'urbFunction': function, 'source': 'control-set-output-report' if transfer == 2
                        else 'interrupt-out-submission'})
                # A first-byte value here is not called a report ID. Setup,
                # unknown HID payloads and empty completions remain opaque.
                setup_key = tuple(setup.get(k) for k in ('requestType', 'request', 'value', 'interface', 'length')) if setup else None
                key = (transfer, endpoint, function, info, stage, len(packet[size:]),
                       packet[size] if len(packet) > size else None, setup_key)
                group = opaque_groups.get(key)
                if group is None:
                    require(len(opaque_groups) < 10_000, "未解码通信分类超过分析上限。")
                    body = packet[size:]
                    group = {'transferType': transfer, 'endpoint': endpoint, 'urbFunction': function,
                        'directionInfo': info, 'controlStage': stage, 'payloadBytes': len(body),
                        'firstPayloadByte': body[0] if body else None, 'setup': setup,
                        'packets': 0, 'firstPacket': packets, 'lastPacket': packets,
                        'firstSample': {'packet': packets, 'timestampSeconds': sec,
                            'timestampFraction': subsecond, 'timestampResolution': resolution,
                            'irpID': f'0x{irp:016x}', 'usbStatus': status if info == 1 else None,
                            'payloadHex': body.hex() if len(body) <= 256 else None,
                            'payloadSHA256': hashlib.sha256(body).hexdigest()},
                        'classification': 'opaque selected-device traffic; first sample only, not full payload history'}
                    opaque_groups[key] = group
                group['packets'] += 1
                group['lastPacket'] = packets
                continue
            require(len(frames) < 100_000 and len(issues) <= 10_000, "所选通信超过分析上限。")
            counts[f"{source}:0x{payload[3]:02x}"] += 1
            frame = {"packet": packets, "timestampSeconds": sec,
                     "timestampFraction": subsecond, "timestampResolution": resolution,
                     "irpID": f"0x{irp:016x}", "usbStatus": status if info == 1 else None,
                     "urbFunction": function, "endpoint": endpoint, "source": source,
                     "controlStage": stage, "setup": setup,
                     "commandByte": payload[3], "countByte": payload[4],
                     "offsetWord": int.from_bytes(payload[5:7], "little"),
                     "statusByte": payload[7], "reportHex": payload.hex(),
                     "checksumWord": int.from_bytes(payload[1:3], "little")}
            if source != "interrupt-in-completion":
                frame['usbCompletion'] = None
                frame['usbCompletionAssociation'] = 'completion-not-observed'
                frame["sumBytes3Through63"] = sum(payload[3:64])
                frame["checksumMatchesFullSum"] = frame["checksumWord"] == sum(payload[3:64])
                if payload[3] == 6 and 1 <= payload[4] <= 56:
                    frame["parameterWriteCandidate"] = {
                        "offset": frame["offsetWord"], "dataHex": payload[8:8+payload[4]].hex(),
                        "classification": "matches existing command-06 shape only; not identity/acceptance proof"}
                register_out(irp, frame)
            frames.append(frame)
        final = os.fstat(handle.fileno())
        require((initial.st_size, initial.st_mtime_ns, initial.st_ctime_ns) ==
                (final.st_size, final.st_mtime_ns, final.st_ctime_ns), "分析期间抓包文件发生变化。")
    return {"format": "CherryMacWindowsUSBCaptureInspection", "version": 4,
            "captureSHA256": digest.hexdigest(), "bus": bus, "deviceAddress": device,
            "packets": packets, "selectedDevicePackets": selected, "report4Frames": frames,
            "commandCounts": dict(sorted(counts.items())), "issues": issues,
            "usbCompletionCounts": dict(sorted(completion_counts.items())),
            "opaqueTrafficGroups": list(opaque_groups.values()),
            "opaqueTrafficPackets": sum(group['packets'] for group in opaque_groups.values()),
            "outReportsWithoutAssociatedCompletion": sum(f.get('usbCompletionAssociation') is not None and
                                                          f.get('usbCompletion') is None for f in frames),
            "targetIdentityVerified": False, "configurationWriteAccepted": False,
            "powerCycleVerified": False, "authorizesReplay": False,
            "limits": "Offline observed bytes only. USB completion is not a keyboard acknowledgement. "
                      "No keyboard-protocol request/reply pairing, VID/PID identity, reconnect address continuity, "
                      "old split-control DATA, Feature reports or persistence inference. "
                      "Other selected-device traffic is grouped with a first raw sample, not decoded; "
                      "samples do not contain every unknown payload."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--bus", type=int, required=True)
    parser.add_argument("--device", type=int, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.capture, args.bus, args.device), ensure_ascii=False, indent=2))
    except (OSError, ValueError, struct.error) as error:
        parser.exit(1, str(error)+"\n")
