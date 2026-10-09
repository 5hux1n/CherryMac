#!/usr/bin/env python3
"""Read the fixed official updater's firmware resources; never run or flash it."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct

EXPECTED_SHA256 = "188836c15eb1560d0282ae3c2485b4a4d2edd5dfb69a91d4510b273c61047088"
IMAGE_SHA256 = "31d0a07361ad531fa16867412d46e496737b126efc90482f86baa7e6bd5051bd"


def inspect_custom_lighting_output(image):
    """Pin mode8 bank-to-output transformation; no firmware execution."""
    def at(a,n):return image[a-0x10000:a-0x10000+n]
    bodies={(0x2BFE4,0x2C0C4):"ce2c0721d81747eae16ed435f2dc25238688f430116dca44e70543bf8b119ce6",
            (0x2B2C4,0x2B302):"622caa2d361ec795760981c31e9ea3cddfc98c901bb6e6b0e70c0afb55c2e1b1",
            (0x2D414,0x2D486):"f75450a0388e979a062e2989a3bc1dfd508f6bd6ab16113382baa4f13c0ba3c1"}
    for (a,b),h in bodies.items():
        if hashlib.sha256(at(a,b-a)).hexdigest()!=h:raise ValueError("Custom lighting output differs")
    table=at(0x2C55C,48)
    if hashlib.sha256(table).hexdigest()!="accc50fcd4de71ad3e0ffab535b26f435ca89b32cb3532820fe8c1d4addca551":raise ValueError("Lighting TBH data differs")
    if struct.unpack_from('<H',table,16)[0]!=511 or at(0x2C95A,4)!=bytes.fromhex("fff743fb"):raise ValueError("Mode8 dispatch differs")
    literals={0x2C0CC:0x20000CD8,0x2C0D8:0x20009AFC,0x2C0E0:0x20004DF8,0x2C0E4:0x20000D18,0x2C0E8:0x4E7EC,0x2C0F8:0x20000D1A,0x2B304:0x4E57C,0x2B308:0x20005284,0x2B30C:0x20005184,0x2D488:0x200053EC,0x2D48C:0x200053E4}
    for a,v in literals.items():
        if struct.unpack('<I',at(a,4))[0]!=v:raise ValueError("Custom output literal differs")
    if at(0x4E7EC,5)!=bytes([0,64,128,192,255]):raise ValueError("Firmware custom brightness table differs")
    return {"codeSegments":[{"start":hex(a),"endExclusive":hex(b),"sha256":h} for (a,b),h in bodies.items()],
            "mode8Dispatch":{"table":"0x2c55c..0x2c58c","tableIsData":True,"target":"0x2c95a","call":"0x2bfe4"},
            "bankSource":{"when20009afcZero":"0x20000d18 + 3*LED index","alternate":"0x20004df8 + 3*LED index"},
            "brightness":{"parameterIndex":2,"tableROM":"0x4e7ec","coefficients":[0,64,128,192,255],"transform":"(bank channel * coefficient) >> 8 before mapper 0x2b2c4","relation":"Separate from the official host pre-scaling table [0,65,135,195,255]; do not remove host scaling to compensate"},
            "channelMapper":{"tableROM":"0x4e57c","stride":4,"marker0x74Buffer":"0x20005284","marker0x77Buffer":"0x20005184","channelOffsets":"Three byte offsets, minus 1; not the USB color-bank order"},
            "outputPacket":{"method":"0x2d414","buffer":"0x200053ec","header":"byte0 = argument1 OR 0x50; byte1 = argument2; source bytes copied at +2","send":"indirect interface on object from 0x200053e4"},
            "limits":"Fixed packaged 0104 image only. This closes a bank/brightness/mapper/output path, not current firmware identity, whole timer ordering, every gating state or actual LED appearance. LED wiring table remains separate from actual USB mapping reads. No execution, emulation or hardware access."}


def inspect_light_flag_callback(image):
    """Pin the byte21 consumer and callback registration, without execution."""
    def at(address,size):
        start=address-0x10000
        if start<0 or start+size>len(image):raise ValueError("Light flag address outside firmware")
        return image[start:start+size]
    bodies={
        (0x2B7E4,0x2B84E):"cecfe005f98dd02d7c92ae83bb3855ed3ae459c0af0a96e9033d343e64361e11",
        (0x2BB1E,0x2BB5C):"bb816a7e2f1d9c09cea7740630a0bc732d9c76f6b9c33487bc0d014a432ec5aa",
        (0x3A0EC,0x3A146):"37fd2dc5bd93e58174452770ddbf613415f1dc2c52fb24a4bc0b5496848f47d5",
    }
    for (a,b),digest in bodies.items():
        if hashlib.sha256(at(a,b-a)).hexdigest()!=digest:raise ValueError("Light flag code body differs")
    checks={0x2B7E6:"1a4b",0x2B7E8:"5b7d",0x2B7EC:"f3b9",0x2B830:"0c48",0x2B832:"0ef05bfc",0x2B83C:"0ef056fc",0x2B848:"fff7eefe"}
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):raise ValueError("Light flag branch instruction differs")
    literals={0x2B850:0x20000CD8,0x2B854:0x20009B21,0x2B858:0x20005284,0x2B85C:0x200034F8,0x2B860:0x20003E20,0x2B864:0x20005184,0x2B868:0x20009B35,0x2BB74:0x200034F8,0x2BB7C:0x2B7E5,0x2BB80:0x20003E20}
    for address,value in literals.items():
        if struct.unpack('<I',at(address,4))[0]!=value:raise ValueError("Light flag literal differs")
    return {"codeSegments":[{"start":hex(a),"endExclusive":hex(b),"sha256":h} for (a,b),h in bodies.items()],
            "instructionChecks":len(checks),"literals":{hex(a):hex(v) for a,v in literals.items()},
            "consumer":{"entry":"0x2b7e4","parameterBase":"0x20000cd8","parameterIndex":21,"branch":"0 goes directly to the common update at 0x2b7ee; nonzero clears two buffers first",
                "nonzeroClears":[{"start":"0x20005184","length":198},{"start":"0x20005284","length":198}],
                "clearHelper":"0x3a0ec..0x3a146 implements byte fill, called with r1=0 and r2=198",
                "additionalPath":"nonzero checks 0x20009b35; if zero, calls 0x2b628 before common update"},
            "registration":{"site":"0x2bb3e..0x2bb5c","callback":"0x2b7e5 (Thumb pointer)","object":"0x200034f8","callbackObjectByte":4,"scheduler":"0x20003e20","intervalArgument":20,"registerFunction":"0x4b064"},
            "limits":"This proves a consumer in the fixed packaged 0104 image, not installed firmware or a simple on/off meaning. Buffer purpose, whole callback timing and physical effect remain unverified. Literal pools are excluded from code hashes; no execution, emulation or device access."}


def inspect_macro_event_dispatch_and_release(image):
    """Pin the event TBB table and separate held-state cleanup, without execution."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or offset+size>len(image):
            raise ValueError("Macro event path exceeds fixed image")
        return image[offset:offset+size]
    bodies={
        (0x2F6C4,0x2F76C):"0ebd672b9ec709ab91e10fd4a94d1e75fa37c39e70ad7675dc22513da39398a0",
        (0x2F7FC,0x2F954):"da655abe4bcd1c6e334e920627f65d903a8307188fcff3d1ce30b6c6552e8dfd",
    }
    for (start,end),expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest()!=expected:
            raise ValueError("Unexpected macro event/release segment")
    checks={
        0x2F7D6:"a17894f902001a80654d01f07f03c217013b2a70092b3fd8dfe803f0",
        0x2F85A:"002866db4a4be278da7000221a71484b01221a7000232b7070bd",
        0x2F8EE:"002824db254be2785a7000229a70b4e7",
        0x2F92C:"e378164aff21117153b15b42d37095e7e378124aff21917023b15b4253708de7d3708be7537089e7",
        0x2F6D2:"284e012b",
        0x2F6EE:"092a28d0012a2dd0402b4ff0010133d016f8132017f81300dcb2651c0a2a03f10103edb2ecd1",
        0x2F728:"98f800502ab206eb450306f812405c703f2d8cbf00200120bde8f081",
    }
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):
            raise ValueError("Unexpected macro event/release instruction")
    table=at(0x2F7F2,10)
    if table!=bytes.fromhex("6c5a867e343e3e3e7551"):
        raise ValueError("Unexpected macro event TBB table")
    expected={0x2F774:0x20004B7C,0x2F77C:0x20009B2D,0x2F968:0x200054EC,0x2F988:0x20004C3C}
    for address,value in expected.items():
        if struct.unpack("<I",at(address,4))[0]!=value:
            raise ValueError("Unexpected macro state/bank pointer")
    return {'instructionChecks':len(checks),
            'codeSegments':[{'start':hex(a),'endExclusive':hex(b),'SHA256':h} for (a,b),h in bodies.items()],
            'eventDispatch':{'table':'0x2f7f2..0x2f7fc','dataNotInstructions':True,
                'entries':[{'type':i+1,'target':hex(0x2F7F2+2*v)} for i,v in enumerate(table)],
                'index':'event type byte & 0x7f, minus 1; >9 bypasses dispatch'},
            'axisFields':{'type4':{'target':'0x2f8ee','destination':'0x20004c3c+1/+2'},
                          'type5':{'target':'0x2f85a','destination':'0x20004c3c+3/+4'},
                          'positive':'payload byte copied to low byte, high byte zero',
                          'negative':'event bit 7 selects low byte -payload mod256, high byte ff; payload zero gives ff00 (-256), not zero',
                          'directionIsNotButtonState':True},
            'releaseState':{'entry':'0x2f6c4','twoByteHeldEntries':'0x20004b7c',
                            'savedScanIndex':'0x20009b2d','configurationBank':'0x200054ec',
                            'distinctRegions':True,'typesMatched':[1,9,10],
                            'clearEntry':'0x2f732/0x2f736 zero the two bytes of the selected held entry',
                            'result':'0x2f738..0x2f740 returns 1 for index<=63, otherwise 0; caller clears active state after a zero result'},
            'otherBranches':'Types 2/3 have distinct handlers; their full report and Windows producer semantics are not classified here. Types 6/7/8 target 0x2f86e.',
            'hardwareWriteAuthorized':False,
            'limits':'Selected fixed official-image event/release paths only. Does not prove Windows model visibility, all triggers/stops, report transport, installed firmware identity or actual output. No execution, emulation or HID access.'}


def inspect_macro_zero_event_path(image):
    """Pin selected macro-count load and zero-event branch, not live execution."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or offset+size>len(image):
            raise ValueError("Macro path exceeds fixed image bounds")
        return image[offset:offset+size]
    bodies={
        (0x2F780,0x2F7F2):"004a95a5e6174cda172ead0b7a474fe58050363960f74d8ee052c4aa37870ecc",
        (0x2F7FC,0x2F85A):"f63a55619cabe5465bb81738c4b0a8ae3e89e5e26aea9dea7a8dbea3e6810fa9",
    }
    for (start,end),expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest()!=expected:
            raise ValueError("Unexpected macro zero-event path")
    checks={
        0x2F79A:"714d288800282cd0",
        0x2F7A2:"704e704a3188043189b28c1831808a5c",
        0x2F7FC:"5e4b5f491b78002b36d00223013b01200b70107070bd",
        0x2F812:"5b4b54491d78544b514c187c102303eb45035d185b5c6d7803eb05239bb2544dc95a2180",
    }
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):
            raise ValueError("Unexpected macro zero-count instruction")
    if struct.unpack("<I",at(0x2F968,4))[0]!=0x200054EC:
        raise ValueError("Unexpected macro bank literal")
    return {'entry':'0x2f780','instructionChecks':len(checks),
            'codeSegments':[{'start':hex(a),'endExclusive':hex(b),'SHA256':h} for (a,b),h in bodies.items()],
            'bankLiteral':{'address':'0x2f968','value':'0x200054ec'},
            'recordHeader':'0x2f826..0x2f834 loads offset from bank+16+2*ordinal, then loads halfword event count and stores it in execution state',
            'zeroCount':'0x2f79c loads remaining event count; 0x2f7a0 branches to 0x2f7fc when zero, bypassing the four-byte event read path at 0x2f7a2..0x2f7f0',
            'completionBranch':'0x2f7fc..0x2f810 handles completion/rearm state; other completion paths call 0x2f6c4 and 0x2ae54 outside these pinned segments',
            'limits':'Fixed official image and selected segments only, excluding the TBB data at 0x2f7f2..0x2f7fc. Does not establish installed firmware identity, every stop/trigger producer, scheduler timing, actual output or power retention. No firmware execution or hardware access.'}


def inspect_report_dispatcher(image, banks):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Firmware address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2F094, 0x2F0F4): '437df5aeb884ae1c9e779ca7413291e14832580e875d318e6bda80afa4189257',
        (0x2F3A2, 0x2F412): 'd7a2c05ecc6a4ffa877267902a1700dd9ffad4ef26085828b397820d8e0624a0',
        (0x2F412, 0x2F496): '813a60eea970437a244e037df5aeb4b1389754e5a06118c9540806b2b97eec3b',
        (0x2F496, 0x2F4E0): '032a88a3879c3d63eb52fb9b6b4a49f8e75ab418d52c42b918a50dae665f5ee5',
        (0x3A084, 0x3A0EC): '540b4da145fefe200a6cc68d8b6b35341083fc0a74902e55d81b6845e334240a',
    }
    for (start, end), expected in bodies.items():
        if hashlib.sha256(at(start, end - start)).hexdigest() != expected:
            raise ValueError("Report dispatcher code differs")
    checks = {0x2F0A2:'ec782f79b5f80580', 0x2F0B8:'3378042b40f0f180',
              0x2F0D8:'b02c05f10809', 0x2F0E2:'022c40f2e880e31ead2b00f2e480dfe813f0',
              0x2F49A:'bff40daf', 0x2F4A6:'bff407af', 0x2F4B8:'bff4feae', 0x2F4C4:'bff4f8ae'}
    for address, encoded in checks.items():
        raw = bytes.fromhex(encoded)
        if at(address, len(raw)) != raw:
            raise ValueError("Report dispatcher instruction differs")
    table = at(0x2F0F4, 174 * 2)
    if hashlib.sha256(table).hexdigest() != 'eb517b3f7b43bdbc3872f6a0c5cf8fb25cd27e9d90ad0779faa6cb2bcdfbf36d':
        raise ValueError("Report dispatcher jump table differs")
    commands = {3:0x2F3A2, 5:0x2F3BA, 6:0x2F250, 7:0x2F3D6,
                8:0x2F3F4, 9:0x2F412, 10:0x2F43E, 11:0x2F45C,
                20:0x2F496, 21:0x2F4B4, 27:0x2F338, 29:0x2F4F4}
    for command, expected in commands.items():
        destination = 0x2F0F4 + struct.unpack_from('<H', table, (command - 3) * 2)[0] * 2
        if destination != expected:
            raise ValueError("Named report command target differs")
    storage = {}
    for prefix, ram in [('led_define_',0x20000D18), ('kb_matrix_',0x20000A98), ('macro_data_',0x200054EC)]:
        rows = []
        for entry in banks[prefix]:
            index = int(entry['name'][len(prefix):]) - 1
            pointer = struct.pack('<I', int(entry['offset'],16) + base)
            matches = [m.start() for m in re.finditer(re.escape(pointer), image)
                       if m.start() % 4 == 0 and m.start() + 8 <= len(image)
                       and struct.unpack_from('<I',image,m.start()+4)[0] == ram + index * 64]
            if len(matches) != 1:
                raise ValueError("Storage-name/RAM pointer pair differs")
            rows.append({'name':entry['name'], 'pointerPairAddress':hex(matches[0]+base),
                         'ramAddress':hex(ram+index*64)})
        storage[prefix] = {'stride':64, 'rows':rows, 'limits':'Adjacent name/RAM pointer pairs only; page loading callbacks and persistence are not fully traced'}
    return {'entry':'0x2f094', 'instructionChecks':len(checks),
            'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'reportFields':{'reportID':0,'command':3,'length':4,'offsetUInt16':5,'payload':8},
            'reportIDGuard':4, 'jumpTable':{'address':'0x2f0f4','entries':174,'firstCommand':3,'lastCommand':176},
            'namedCommandTargets':{hex(k):hex(v) for k,v in commands.items()},
            'macroBounds':{'readBranch':'0x2f496','writeBranch':'0x2f4b4',
                           'offsetMustBeLessThan':3072,'offsetPlusLengthMustBeLessThan':3072,
                           'maximumCoveredPrefixBytes':3071},
            'copyHelper':'0x3a084; byte/word source-to-destination copy with alignment handling',
            'storagePointerPairs':storage,
            'limits':'Fixed firmware report-dispatch entry and named branches only. USB callback routing, checksums upstream, all command side effects, save completion and installed firmware identity remain unproved. No new hardware authorization.'}


def inspect_storage_save_paths(image):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or offset + size > len(image):
            raise ValueError("Save-path address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2E9D0,0x2EA34):'a501d4e4e3d2c024aebdfdcfe4e7b7b50ed83dbdf0a9b25cbcc177f51872f992',
        (0x2EA48,0x2EBE8):'f6c92fccc934657658aafed40d4628d616e6de5be147315ec4c0aef2a99d5981',
        (0x2EC50,0x2EDBC):'69db63862d1312553707bbf38c617e1ae8ff616ae3a9fc7560d12cc27ca5a0d6',
        (0x2EE24,0x2EE54):'132098597e64eb9df1f61cd7f6a7cd5764567dfe2c6d1b59429958e9b2c525cc',
        (0x2EE64,0x2EEA4):'6561d35513cb2d824603a210c117d31eb2bcbf37bcfd279be0b3a707ed961c74',
        (0x33924,0x33960):'a9257d78973a3a3fe844a1c0f373e869b457b9e56aa046a795ee08e3231564b8',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Storage save-path body differs")

    def branch_link(address):
        first, second = struct.unpack('<HH', at(address,4))
        if first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000:
            raise ValueError("Expected a Thumb BL instruction")
        sign = (first >> 10) & 1
        i1 = 1 ^ ((second >> 13) & 1) ^ sign
        i2 = 1 ^ ((second >> 11) & 1) ^ sign
        displacement = (sign << 24) | (i1 << 23) | (i2 << 22) | ((first & 0x3FF) << 12) | ((second & 0x7FF) << 1)
        if sign:
            displacement -= 1 << 25
        return address + 4 + displacement

    calls = {'colors':[0x2EB0E,0x2EB2C,0x2EB4A,0x2EB68,0x2EB86,0x2EBA4,0x2EBC2,0x2EBE0],
             'keymap':[0x2ED0E,0x2ED26,0x2ED3E,0x2ED56,0x2ED6E,0x2ED86,0x2ED9E,0x2EDB6]}
    for addresses in calls.values():
        for address in addresses:
            if branch_link(address) != 0x33924 or struct.unpack('<H',at(address+4,2))[0] & 0xF800 != 0xE000:
                raise ValueError("Named save call/return-discard branch differs")
    if branch_link(0x2EE9A) != 0x33924 or at(0x2EE9E,4) != bytes.fromhex('06b070bd'):
        raise ValueError("Device-version save epilogue differs")
    if branch_link(0x2EA18) != 0x33924 or at(0x2EA1C,6) != bytes.fromhex('05460028e0d1'):
        raise ValueError("Parameter save return check differs")
    literals = {0x2EBE8:0x20009B2B,0x2EBEC:0x20009B25,
                0x2EDBC:0x20009B2B,0x2EDC0:0x20009B27,
                0x2EE54:0x20009B2B,0x2EE58:0x20009B26,
                0x2EEA4:0x20009B2B,0x2EEA8:0x20009B24,
                0x2EEAC:0x4F204,0x2EEB0:0x20000C98,0x33960:0x20007384,
                0x2EA34:0x20009B2B,0x2EA38:0x20009B28,0x2EA3C:0x20000CD8,
                0x2EA40:0x20006F2C,0x2EA44:0x4F0B4}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Save-path literal differs")
    if at(0x4F204,len(b'flash/device_version\0')) != b'flash/device_version\0':
        raise ValueError("Device-version storage name differs")
    if at(0x4F0B4,len(b'flash/func_ram\0')) != b'flash/func_ram\0':
        raise ValueError("Parameter storage name differs")
    return {'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'backendFacade':'0x33924; obtains backend from pointer at 0x20007384 and invokes its function-table offset 8; returns backend result or -2 when absent',
            'commonSkipCondition':'Named save helpers return without saving when byte 0x20009b2b equals 4; meaning of this state is not yet classified',
            'saveFlags':{'colors':'0x20009b25','keymap':'0x20009b27','macroData':'0x20009b26','parameters':'0x20009b28','deviceVersion':'0x20009b24'},
            'namedBackendCalls':{key:[hex(address) for address in addresses] for key,addresses in calls.items()},
            'returnHandling':'Each of the sixteen named color/keymap calls is followed immediately by an unconditional branch, without checking r0. The device-version helper clears its flag before the backend call and returns through its epilogue without checking r0. Parameter saving uses a separate return-checked helper',
            'macroGate':'0x2ee24 compares 3072 RAM bytes with its shadow; identical data clears the flag, differing data invokes 0x2dee8',
            'deviceVersionSave':{'helper':'0x2ee64','name':'flash/device_version','sourceRAM':'0x20000c98','length':64},
            'parameterSave':{'helper':'0x2e9d0','name':'flash/func_ram','sourceRAM':'0x20000cd8','shadowRAM':'0x20006f2c','length':64,
                             'returnHandling':'0x2ea18 calls the backend; a nonzero return skips shadow update/flag clearing. Zero updates the shadow and clears the flag; unchanged data also clears it',
                             'normalization':'When saving changed parameters, byte 16 equal to 4 is replaced with 2; purpose and live relevance remain unclassified'},
            'limits':'Named save helper/facade paths only. Actual backend selection, physical flash writes, polling schedule, failure propagation outside these calls and USB completion semantics remain unproved. RAM readback does not establish persistence; no automatic retry or added hardware authorization.'}


def inspect_save_scheduler(image):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or offset + size > len(image):
            raise ValueError("Save-scheduler address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x280EC,0x28114):'290fab69faacf38c2e5ad8881ff16c8b8991cfd8bd5d8998735f66d4a2fa460e',
        (0x2EF3C,0x2F044):'c9791c583fab0df9261fb516802925db7b9aaf1c612e67b2ec1fb301d1f088c0',
        (0x2FD2C,0x2FDB0):'d1cddb0e6fba64b602d7155477c3698ff249ec31875e95e42acb4dd63cbb3501',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Save-scheduler/event body differs")
    literals = {0x280E8:0x280ED,0x28114:0x200034C8,0x28118:0x20003E20,
                0x2F058:0x52768,0x2F064:0x20000CD8,0x2F080:0x20009B2B,0x2F084:0x20009B28,
                0x52768:0x4F50C,0x2FDB4:0x52768,0x2FDB8:0x52790,0x52790:0x4F520}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Save-scheduler/event literal differs")
    for address, text in [(0x4F50C,b'mulprotocol_event\0'),(0x4F520,b'usb_dtm_event\0')]:
        if at(address,len(text)) != text:
            raise ValueError("Save-event type name differs")
    return {'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'saveCallback':{'entry':'0x280ec','thumbPointer':'0x280ed','pointerLiteral':'0x280e8',
                            'orderedCalls':['0x2e9d0','0x2ec50','0x2ea48','0x2ee24','0x2ee64'],
                            'tailCall':'0x4b064; r0=0x20003e20, r1=0x200034c8, r2=50, r3=0',
                            'limits':'Proves the call sequence and tail-call arguments; see saveWorkRegistration for fixed initialization and deferred enqueue declarations. Live scheduling and duration units remain unproved; 50 is not claimed as milliseconds'},
            'protocolStateEvent':{'listener':'0x2ef3c','eventType':'mulprotocol_event','typeAddress':'0x52768',
                                  'branch':'0x2f000','eventStateOffset':8,'sharedStateRAM':'0x20009b2b',
                                  'parameterIndex':16,'parameterRAM':'0x20000cd8','saveFlagRAM':'0x20009b28',
                                  'behavior':'Copies event byte8 into shared state. If it differs from parameter byte16 and the old parameter byte is neither 4 nor 6, stores the new byte16 and sets the parameter-save flag to 1'},
            'relatedListener':{'entry':'0x2fd2c','eventTypes':['mulprotocol_event','usb_dtm_event'],
                               'limits':'Type identities and fixed body only; numeric protocol values, DTM behavior and reset branch semantics are not fully classified'},
            'limits':'Fixed firmware scheduling candidate and named event-state path only. Not a polling-rate field mapping or proof of actual scheduling, flash completion, current firmware identity or blackout cause. No hardware access or added authorization.'}


def inspect_concrete_backend(image):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or offset + size > len(image):
            raise ValueError("Backend address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x34320,0x343C0):'695ae51cad27c9b9a6d66eceb9db0918bea8cdf24f39fd103206de4e8347bf91',
        (0x33984,0x3398C):'ebb7dd893b4cffb08798c15e60dcebb8e07867694c5efcf4d0006c76e2c8a50d',
        (0x340E8,0x34280):'e4a26e5b10ffd9c379c762fd23ac0644a6463d506cf7d35fd004e8adf1ef0d9e',
        (0x34284,0x34298):'267888edbc4be9d5b74b109a006de3717cedd7b2f72f4c0be09a771b09c52ea6',
        (0x33864,0x338BC):'576b4f2c67a29f8cfa35cc02b8f56aa624eb5ae30ab510488e2969a147bf323a',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Concrete backend body differs")
    literals = {0x3398C:0x20007384,0x343C4:0x200012BC,0x343C8:0x4F894,
                0x343D0:0x3401D,0x343D4:0x34285,0x4F894:0x340D9,0x4F89C:0x340E9}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Concrete backend registration pointer differs")
    return {'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'initializer':'0x34320; successful preparation installs table 0x4f894 at object 0x200012bc+4 and calls 0x33984 at 0x3434e',
            'registration':'0x33984 stores its argument into 0x20007384; the facade subsequently reads this same pointer',
            'table':'0x4f894','loadEntry':'0x340d8','saveEntry':'0x340e8',
            'writer':'0x340e8 handles named records, allocation/reclamation paths, data serialization and a final record operation; return values are checked in its named data/final-operation path',
            'dataSerializer':'0x33dac, called at 0x3425e; it writes name/value data via a registered callback',
            'registeredCallbacks':{'read':'0x34298','write':'0x34284','thirdCallback':'0x3401c',
                                   'registration':'0x33f3c stores three function pointers and one configuration byte; third callback semantics are not classified'},
            'writeAdapter':'0x34284 adjusts the record-relative offset with two context offsets and branches to 0x33864',
            'deviceWrite':'0x33864 checks offset/length against region size, looks up a device via 0x49984, makes surrounding driver-table offset 12 calls with arguments 0/1, and writes via driver-table offset 4. It preserves the main operation error for return',
            'limits':'Fixed registration and named record-to-device chain only; not a live selected backend or confirmed physical flash write. Initializer recovery branches, all reclamation/serialization errors, concrete device driver, completion timing and USB acknowledgement propagation remain unproved. No execution or hardware access.'}


def inspect_flash_binding(image):
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or offset + size > len(image):
            raise ValueError("Flash-binding address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x4B140,0x4B15C):'f10a458f2d3b4b9646811b816fce8db68450b6bc488ea27c271e6cb5d08bf8a0',
        (0x45E38,0x45EA0):'f7ad1e63e0b4a540604f64f78f1a74c3e11d295ddf50141e8196f9f245178bad',
        (0x45D10,0x45D14):'a7ddd513d149ea16fdd4db3f82267f83087aeaddd06b5dde5468adb704205fc4',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Flash-binding code body differs")
    literals = {0x4B15C:0x20000000,0x4B160:0x20001E84,0x4B164:0x50428,
                0x49A10:0x20001A00,0x49A14:0x20001B20,0x516E0:0x4F840,0x4F890:5}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Initialized-data/device-table literal differs")
    # Inspect declared initial bytes, not running RAM or an emulated startup.
    ram_start, ram_end, rom_start = 0x20000000,0x20001E84,0x50428
    device_ram = 0x20001AA8
    if not ram_start <= device_ram < ram_end - 24:
        raise ValueError("Device blueprint exceeds initialized-data range")
    descriptor_address = rom_start + device_ram - ram_start
    descriptor = list(struct.unpack('<6I',at(descriptor_address,24)))
    if descriptor != [0x4F82C,0,0x502E8,0,0x49A41,0x20001928]:
        raise ValueError("Flash device initial descriptor differs")
    name = b'NRF_FLASH_DRV_NAME\0'
    if at(0x4F82C,len(name)) != name:
        raise ValueError("Flash binding name differs")
    area = list(struct.unpack('<4I',at(0x4F880,16)))
    if area != [4,0x7A000,0x6000,0x4F82C]:
        raise ValueError("Settings area descriptor differs")
    api = list(struct.unpack('<6I',at(0x502E8,24)))
    if api != [0x45EF1,0x45E39,0x45F41,0x45D11,0x45D09,0x45D15]:
        raise ValueError("Flash driver API table differs")
    return {'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'initializedData':{'copyRoutine':'0x4b140','romStart':hex(rom_start),'ramStart':hex(ram_start),'ramEndExclusive':hex(ram_end),
                               'limits':'Static initial-data blueprint only; no RAM access or startup execution'},
            'deviceRegistry':{'begin':'0x20001a00','endExclusive':'0x20001b20','rowSize':24,
                              'flashDeviceRAM':hex(device_ram),'initialDescriptorROM':hex(descriptor_address)},
            'settingsArea':{'descriptor':'0x4f880','id':area[0],'offset':area[1],'length':area[2],'bindingName':'NRF_FLASH_DRV_NAME'},
            'driverAPI':{'table':'0x502e8','read':'0x45ef0','write':'0x45e38','erase':'0x45f40','offset12':'0x45d10'},
            'offset12Behavior':'Complete 0x45d10 body returns zero without other operations; surrounding offset12 calls are not evidence of write-protection switching',
            'writeBehavior':'0x45e38 rejects invalid offset/length, stores a source/offset/length job, starts via 0x45e0c and takes a completion path via 0x4ad48 when starting succeeded; full low-level write and synchronization semantics are not yet classified',
            'limits':'Fixed named area, declared device descriptor and driver table only. Live initialization/readiness, current firmware identity, low-level controller operations and USB-to-persistence completion remain unproved. Area length is not a macro or profile capacity. No hardware access or added authorization.'}



def inspect_flash_completion(image):
    """Pin the real completion bodies, without invoking or emulating callbacks."""
    base = 0x10000

    def at(address, size):
        offset = address - base
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Flash-completion address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x13D8C,0x13DD6):'0c30901976dd2a5542c7ae401b2d5964bafaec8e52e29b81d04d64689b331920',
        (0x13DDC,0x13DFC):'7eba6460a60db616989c88e3fa4b7498b225346a6897f231941364e290196abd',
        (0x13E00,0x13E1C):'f3cde41b17a3dd0fc354ec8bd2e6469f8fbd52eec1321f4c31cab7e9298d47c7',
        (0x14760,0x147A8):'bc56faf4cfdb62098cd68f0da292201737b3723cd87c3cfd077d8becf7194134',
        (0x45EA4,0x45EE8):'4e6a1e016e89621df47a9941c38a09d41cb1b8653cc9d09f5c59970971d46e95',
        (0x4ACF0,0x4AD48):'526c680601e22a16c1358a0a76352583eb46f69ad65fae55584b6c02a41eb856',
        (0x4AD48,0x4AD98):'7694429a07a1993a4586e4efdbeca9cc9c49e419c0dc5b0c268a4d6c5b13348b',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Flash-completion body differs")
    literals = {0x13C68:0x13D8D,0x13DD8:0x2000007C,
                0x13DFC:0x2000007C,0x13E1C:0x2000007C,
                0x147A8:0x200000A0,0x45DD4:0x45EA5,
                0x45EE8:0x20008208,0x45EEC:0x2000821C}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Flash-completion literal differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'callbackSlot':'0x2000007c',
        'submitWrappers':{'write':'0x13e00','erase':'0x13ddc',
                          'writeBackend':'0x14aac','eraseBackend':'0x14bc8',
                          'behavior':'Store the supplied callback only after the low-level submit returns zero; reject a null callback or nonzero submit result with -22'},
        'eventDrain':{'entry':'0x13d8c','declaredThumbPointer':'0x13c68',
                      'poller':'0x14760','pendingBitmapRAM':'0x200000a0',
                      'successEvent':2,'failureEvent':3,
                      'behavior':'Capture the callback at entry, consume pending events, clear the callback slot and invoke the captured callback with 0 for event 2 or 1 for event 3. Poll result 5 exits the drain',
                      'limits':'Event meanings here are defined by this caller. Producers, caller scheduling and all low-level controller branches are not closed'},
        'jobCompletion':{'entry':'0x45ea4','jobRAM':'0x20008208',
                         'completionObjectRAM':'0x2000821c','nextChunk':'0x45d24','give':'0x4acf0','take':'0x4ad48',
                         'behavior':'Zero callback advances source/offset and reduces remaining length by the processed chunk. Remaining data tail-calls the next submit. A nonzero callback with remaining data also tail-calls the next submit without advancing. When remaining length is zero, clear job state and give completion',
                         'returnLimits':'The shown callback does not store a backend error into a separate result field. Retry-submit return handling and eventual completion on failure are not fully proved; this is not a host retry recommendation'},
        'completionPrimitive':'Take decrements an available count and returns zero; zero timeout with no count returns -16; otherwise it delegates to a waiter. Give wakes a waiter with zero or increments the bounded count',
        'limits':'Fixed static completion path only. Low-level event producers, all scheduling and error paths, USB acknowledgement coupling, installed firmware identity and physical persistence remain unproved. No execution, hardware access, upgrade or new write authorization.'}



def inspect_report_reply_cache(image):
    """Verify the dispatch and cached reply branches in the fixed target image."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Reply-cache address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x26778,0x267F0):'1d5c44ce373c372513e8d3ed6cdb2207e7cbebb96ffe79c03a33cda168ec257c',
        (0x27718,0x27784):'3cb0db4498523726d863e17e6e8867cc6e870fc26c8e007390d1d35432bbe143',
        (0x2F250,0x2F28A):'a165bb2be7023662178def9154583695885f8a66990d594ee88a665c46a6b721',
        (0x2F28A,0x2F2A6):'457f551ea07b082959a7f52adcf1e73666554684c4e7d70134704dbe341fd841',
        (0x2F412,0x2F43E):'81aae7dc11c9a7bf091abd9160466dc76f1fe04128ded8815db69148c2005c05',
        (0x2F45C,0x2F496):'988548b0111045f8201567b8c7ce4bb815b0320fca1000f093c646440af16841',
        (0x2F4B4,0x2F4F4):'186b4a8aa6c9bef4c4a561e332322963492e3e01df3b4d55a222325df83d4bca',
        (0x2F350,0x2F372):'ee227eef51f13d72575bc29b862d4a4fa00ba7b33a395c2adcf1a34d90ce226d',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Reply-cache code body differs")
    literals = {0x276F0:0x27719,0x27804:0x200060EC,
                0x2F2C8:0x2000716C,0x2F2CC:0x200060EC,
                0x2F2E8:0x20009B22,0x2F5E8:0x20009B22,
                0x2F5EC:0x20007174,0x2F5F0:0x200060F4}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Reply-cache literal differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'entryCandidates':{'controlStyleSet':'0x26778','reportCallback':'0x27718',
                           'reportCallbackThumbPointer':'0x276f0',
                           'limits':'Named call paths in the image; complete transport registration, USB stack scheduling and live routing are not established'},
        'reportCallbackBranches':{
            'nonzeroThirdArgument':'For report ID 4, ordinary commands excluding 0x23 and 0x24 tail-call 0x2f094',
            'zeroThirdArgument':'Load destination from the first structure word and count from its byte4; copy bytes from 0x200060ec through 0x3a084 and return, without a flash-completion wait in this branch'},
        'dispatcherCaches':{'initialReportCopyRAM':['0x2000716c','0x200060ec'],
                            'payloadCopyRAM':['0x20007174','0x200060f4'],
                            'payloadCopyFlagRAM':'0x20009b22',
                            'behavior':'The dispatcher first copies the incoming 64-byte report into both caches. Its shared tail may copy payload into the cache payloads, emit an event in state 2, or return'},
        'configurationWrites':'Named keymap/color/macro update branches copy payload to configuration RAM, set flags and branch to 0x2f28a. No direct named storage-save helper or completion wait occurs in those fixed branches or the inspected common reply tail',
        'limits':'Shows cached replies and RAM/flag updates in these fixed branches, not a whole-program proof that no other context saves concurrently or waits before transmission. Transport registration, checksum rules, all parameter side effects and live firmware identity remain unproved. Cached success and RAM readback do not establish power-off retention. No hardware access or added write authorization.'}



def inspect_parameter_consumers(image):
    """Locate declared base loads and pin two actual consumers; no emulation."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Parameter-consumer address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2811C,0x28158):'cabe5cce3799deb5f9c41c538030c04ef075b013686f76788b6987e0265e4d38',
        (0x28D48,0x28D9E):'0b35b4103991ad40ccbaabadffeed625a8f4a564a68f98c1572d04fdc3f535f5',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Parameter-consumer body differs")
    for address, expected in {0x28158:0x20009AD4,0x2815C:0x20009AC8,
                              0x28160:0x20004B60,0x28164:0x20000CD8,
                              0x28DA0:0x20000CD8,0x28DA4:0x20009AEA}.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Parameter-consumer literal differs")
    loads = []
    # Byte-pattern candidates, not a linear code disassembly: pools may look like instructions.
    for offset in range(0,len(image)-3,2):
        first, second = struct.unpack_from('<HH',image,offset)
        address = offset + 0x10000
        if first & 0xF800 == 0x4800:  # Thumb LDR literal T1
            register = (first >> 8) & 7
            literal = ((address + 4) & ~3) + (first & 0xFF) * 4
            width = 2
        elif first in (0xF8DF,0xF85F):  # Thumb LDR literal T2 +/- imm12
            register = second >> 12
            literal = ((address + 4) & ~3) + (1 if first == 0xF8DF else -1) * (second & 0xFFF)
            width = 4
        else:
            continue
        relative = literal - 0x10000
        if 0 <= relative <= len(image)-4 and struct.unpack_from('<I',image,relative)[0] == 0x20000CD8:
            loads.append({'instructionCandidate':hex(address),'literalAddress':hex(literal),
                          'destinationRegister':register,'instructionWidth':width})
    known = {0x2812E,0x28D4A,0x2F260,0x2F3CC,0x2F000}
    if not known.issubset({int(row['instructionCandidate'],16) for row in loads}):
        raise ValueError("Known parameter-base loads are absent")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'parameterBaseRAM':'0x20000cd8','baseLoadCandidates':loads,
        'candidateScanLimits':'Only PC-relative Thumb literal-load encodings. Candidates may occur in data or inside wide instructions; not a complete reference/data-flow census or proof that another field has no consumer',
        'bitMaskConsumer':{'entry':'0x2811c','stateByteRAM':'0x20004b60',
                           'condition':'On the nonzero event-state branch, parameter byte22 is nonzero and byte39 is zero',
                           'operation':'Merge the input mask, then AND the state byte with 0x77, clearing bits 3 and 7',
                           'otherBranch':'Zero event-state clears the supplied mask with BIC; zero input returns immediately'},
        'keyTransformConsumer':{'entry':'0x28d48','parameterIndex':39,
                               'condition':'Byte39 equals 1 enables the special branch',
                               'sourceStateRAM':'0x20009aea',
                               'specialCases':{'0x0b':'mask 0x04; key argument 0','0x11':'mask 0x08; key argument 0',
                                               '0x41':'mask 0x80; key argument 0','0x4d':'mask 0x40; key argument 0'},
                               'downstream':['0x2811c','0x28168']},
        'limits':'Actual fixed consumers only. State-byte report routing, exact user-facing lock/mode meaning, JSON WinFlag/WFlag/Key6Flag correspondence, polling-rate indices and persistence remain unproved. No product field mapping, execution, hardware access or added authorization.'}



def inspect_macro_block_saving(image):
    """Read all 48 named macro save blocks in the pinned official image."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Macro-save address exceeds image bounds")
        return image[offset:offset + size]

    def literal_load(address, register):
        instruction = struct.unpack('<H',at(address,2))[0]
        if instruction & 0xF800 != 0x4800 or (instruction >> 8) & 7 != register:
            raise ValueError("Macro-save literal load differs")
        literal = ((address + 4) & ~3) + (instruction & 255) * 4
        return struct.unpack('<I',at(literal,4))[0]

    bodies = {
        (0x2DEE8,0x2E1D0):'8d63e3f96b4b8ac4aa49cab9d9a5e63dc4cfe1b0270376383e00903afe8a0e72',
        (0x2E340,0x2E584):'7f029f5368c429f336507b7cb9b71c7b2d1a5e5edba62bc6f41c65e2c9e6310d',
        (0x2E648,0x2E89C):'585125dfdf044e99bedf78d560224e1e89c15f4d796e8d88b60359e15fcf7b1e',
        (0x2E958,0x2E9B8):'46e3702dd86bf3ea35fad2221cafc30d9bc52c625a728acf4669b207388441ab',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Macro-save code range differs")
    # compare entry, differing-block branch, backend BL, source-pointer load.
    locations = [
        (0x2deea,0x2e370,0x2e388,0x2e37e),(0x2defc,0x2e998,0x2e9b0,0x2e9a6),(0x2df0c,0x2e978,0x2e990,0x2e986),
        (0x2df1c,0x2e958,0x2e970,0x2e966),(0x2df2c,0x2e87e,0x2e896,0x2e88c),(0x2df3c,0x2e85e,0x2e876,0x2e86c),
        (0x2df4c,0x2e83e,0x2e856,0x2e84c),(0x2df5c,0x2e81e,0x2e836,0x2e82c),(0x2df6c,0x2e7fe,0x2e816,0x2e80c),
        (0x2df7c,0x2e7e4,0x2e7f6,0x2e7ee),(0x2df8c,0x2e7ca,0x2e7dc,0x2e7d4),(0x2df9c,0x2e7b0,0x2e7c2,0x2e7ba),
        (0x2dfac,0x2e798,0x2e7aa,0x2e7a2),(0x2dfbc,0x2e780,0x2e792,0x2e78a),(0x2dfcc,0x2e768,0x2e77a,0x2e772),
        (0x2dfdc,0x2e750,0x2e762,0x2e75a),(0x2dfec,0x2e738,0x2e74a,0x2e742),(0x2dffc,0x2e720,0x2e732,0x2e72a),
        (0x2e00c,0x2e708,0x2e71a,0x2e712),(0x2e01c,0x2e6f0,0x2e702,0x2e6fa),(0x2e02c,0x2e6d8,0x2e6ea,0x2e6e2),
        (0x2e03c,0x2e6c0,0x2e6d2,0x2e6ca),(0x2e04c,0x2e6a8,0x2e6ba,0x2e6b2),(0x2e05c,0x2e690,0x2e6a2,0x2e69a),
        (0x2e06c,0x2e678,0x2e68a,0x2e682),(0x2e07c,0x2e660,0x2e672,0x2e66a),(0x2e08c,0x2e648,0x2e65a,0x2e652),
        (0x2e09c,0x2e56e,0x2e580,0x2e578),(0x2e0ac,0x2e556,0x2e568,0x2e560),(0x2e0bc,0x2e53e,0x2e550,0x2e548),
        (0x2e0cc,0x2e526,0x2e538,0x2e530),(0x2e0dc,0x2e50e,0x2e520,0x2e518),(0x2e0ec,0x2e4f6,0x2e508,0x2e500),
        (0x2e0fc,0x2e4de,0x2e4f0,0x2e4e8),(0x2e10c,0x2e4c6,0x2e4d8,0x2e4d0),(0x2e11c,0x2e4ae,0x2e4c0,0x2e4b8),
        (0x2e12c,0x2e496,0x2e4a8,0x2e4a0),(0x2e13c,0x2e47e,0x2e490,0x2e488),(0x2e14c,0x2e466,0x2e478,0x2e470),
        (0x2e15c,0x2e44e,0x2e460,0x2e458),(0x2e16c,0x2e436,0x2e448,0x2e440),(0x2e17c,0x2e41e,0x2e430,0x2e428),
        (0x2e18c,0x2e406,0x2e418,0x2e410),(0x2e19c,0x2e3ee,0x2e400,0x2e3f8),(0x2e1ac,0x2e3d6,0x2e3e8,0x2e3e0),
        (0x2e1bc,0x2e3be,0x2e3d0,0x2e3c8),(0x2e340,0x2e3a6,0x2e3b8,0x2e3b0),(0x2e34e,0x2e38e,0x2e3a0,0x2e398),
    ]
    rows = []
    for index,(compare,save,call,source_load) in enumerate(locations):
        current, shadow = 0x200054EC + index*64, 0x2000632C + index*64
        if literal_load(compare,1) != current or literal_load(compare+2,0) != shadow:
            raise ValueError("Macro compare RAM pair differs")
        name_address = literal_load(save,5)
        name = f'flash/macro_data_{index+1}'
        if at(name_address,len(name)+1) != name.encode('ascii') + b'\0':
            raise ValueError("Macro-save storage name differs")
        if literal_load(source_load,1) != current:
            raise ValueError("Macro-save source differs")
        first,second = struct.unpack('<HH',at(call,4))
        if first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000:
            raise ValueError("Macro-save BL differs")
        sign = (first >> 10) & 1
        displacement = (sign << 24) | ((1 ^ ((second >> 13) & 1) ^ sign) << 23) | ((1 ^ ((second >> 11) & 1) ^ sign) << 22) | ((first & 0x3FF) << 12) | ((second & 0x7FF) << 1)
        if sign:
            displacement -= 1 << 25
        if call + 4 + displacement != 0x33924:
            raise ValueError("Macro-save backend target differs")
        tail_first,tail_second = struct.unpack('<HH',at(call+4,4))
        short_branch = tail_first & 0xF800 == 0xE000
        wide_branch = tail_first & 0xF800 == 0xF000 and tail_second & 0xD000 == 0x9000
        if not (short_branch or wide_branch):
            raise ValueError("Macro-save unchecked continuation differs")
        rows.append({'block':index+1,'compareEntry':hex(compare),'saveEntry':hex(save),
                     'backendCall':hex(call),'name':name,'sourceRAM':hex(current),'shadowRAM':hex(shadow),'length':64})
    if literal_load(0x2E35A,1) != 0x200054EC or literal_load(0x2E35C,0) != 0x2000632C or literal_load(0x2E366,3) != 0x20009B26:
        raise ValueError("Macro-save final shadow/flag pointers differ")
    return {'entry':'0x2dee8','blockCount':48,'blockSize':64,'rows':rows,
            'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
            'returnHandling':'Every named backend BL is followed immediately by an unconditional branch; these 48 paths do not inspect r0',
            'finalization':'0x2e35a..0x2e36e copies 3072 bytes from current RAM to shadow, clears the macro-save flag and returns',
            'limits':'Fixed helper and named paths only. This does not establish whether another layer suppresses backend failures, how all failure contexts recover, installed firmware identity or power-off retention. 48 blocks are not 48 macros. Host transfer remains 3071 bytes; no hardware access or new write authorization.'}



def inspect_save_work_registration(image):
    """Pin initialization of the save work object and its deferred enqueue path."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Save-work registration address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2803C,0x280CA):'6358a630edd52f88ef00eef65abb8ca855ae5f9fe22b31c8f03daba7fc5b70d7',
        (0x4B064,0x4B10C):'0676a18492b267c6cc7a33ce1d0431a99a6e82b2d4b67ab32ccbd744e6c8160a',
        (0x4AFE0,0x4B016):'588859040be1422ed51f4cec36caecee55a1c63a9715e9fa34edcd76833bd074',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Save-work registration code differs")
    literals = {0x280D4:0x20003498,0x280D8:0x200034C8,0x280E0:0x20003E20,
                0x280E4:0x28021,0x280E8:0x280ED,0x4B10C:0x4AFE1}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Save-work registration literal differs")
    # Explicit pointer stores: r6 is the save object, r5 the separate input object.
    if at(0x280A8,4) != bytes.fromhex('0f4b7360') or at(0x28098,6) != bytes.fromhex('114f124b6b60'):
        raise ValueError("Save/input callback pointer stores differ")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'initializer':'0x2803c',
        'saveWork':{'ram':'0x200034c8','clearedBytes':48,'callbackFieldOffset':4,
                    'callbackThumbPointer':'0x280ed','store':'0x280aa',
                    'initialSubmit':'0x280b4','queueRAM':'0x20003e20','delayLowWord':50,'delayHighWord':0},
        'separateInputWork':{'ram':'0x20003498','callbackThumbPointer':'0x28021','delayLowWord':10,'delayHighWord':0},
        'resubmit':'The previously pinned save callback 0x280ec submits the same object to the same queue with the same 50/0 argument pair',
        'scheduler':'0x4b064 records queue ownership at work+0x28. A nonzero delay calls 0x4b284 on work+0x10 using the declared callback 0x4afe1. The zero-delay branch sets pending bit0 at work+8 and enqueues through 0x4a108 when it was not pending',
        'deferredEnqueue':'0x4afe0 obtains the queue at timer-node+0x18, sets pending bit0 at timer-node-8 and, when newly pending, enqueues the recovered work at timer-node-0x10 through 0x4a108',
        'limits':'Fixed registration and named deferred enqueue paths only. Initializer call reachability, actual scheduling, duration units, every cancellation/error branch, USB completion and installed firmware identity remain unproved. Do not treat 50 as milliseconds or add guessed host waits. No execution or hardware access.'}



def inspect_queue_worker(image):
    """Pin the declared queue worker and its callback dispatch body."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Queue-worker address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x4AD9C,0x4ADBE):'7eaa8d05c0f57e959373b1d06a3fcdc528c217d0926fc9b089613f669609cfda',
        (0x4B018,0x4B05C):'0906e8b431faebbd704132970d49c77d05daf76d04d8aa9ef491b4c0016f0db8',
        (0x31070,0x310B4):'d1ce423cb09f0cf22e054b045ef5b75b7fcc025d6d568325e2414a6b8ffed61f',
        (0x4A1C0,0x4A22A):'5613c41b151de4702e3e8e8bc4ceb4864eeb322bad4803e822b6adb627204eb4',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Queue-worker body differs")
    literals = {0x4ADC0:0x20003E20,0x4ADC4:0x2000C5C8,0x4ADC8:0x50410,
                0x4B05C:0x31071,0x4B060:0x5041C}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Queue-worker creation literal differs")
    if at(0x3108A,2) != bytes.fromhex('4168') or at(0x310AA,2) != bytes.fromhex('8847'):
        raise ValueError("Queue-worker callback load/invoke differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'queueInitializer':{'entry':'0x4ad9c','queueRAM':'0x20003e20',
                            'stackRAM':'0x2000c5c8','stackSize':1536,'createCall':'0x4b018'},
        'workerDeclaration':{'constructor':'0x4b018','thumbPointer':'0x31071',
                             'literal':'0x4b05c','queueArgument':'Declared constructor stores its queue argument in the thread argument setup'},
        'workerLoop':{'entry':'0x31070','getWork':'0x4a1c0','timeoutLowWord':4294967295,'timeoutHighWord':4294967295,
                      'callbackFieldOffset':4,'pendingFieldOffset':8,
                      'behavior':'Get a work object; a null result loops. Load callback at work+4, atomically clear pending bit0 at work+8, invoke callback through BLX only when bit0 was previously set, then call 0x4abdc and loop'},
        'getWork':'0x4a1c0 removes a queued head or delegates to a waiter when no head is present and the timeout is nonzero; includes tagged-node and error paths',
        'saveChain':'The declared queue matches saveWorkRegistration; its initialized save object carries 0x280ed in the same callback field that this worker invokes',
        'limits':'Fixed queue construction and dispatch chain only. Actual startup/thread readiness, precise scheduling and timeout units, all waiter/error/cancellation paths, USB completion coupling, live firmware identity and power-off retention remain unproved. No execution, emulation or hardware access.'}



def inspect_scheduler_clock(image):
    """Pin RTC count conversion; nominal units are not a persistence barrier."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Scheduler-clock address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x35EDC,0x35F1E):'dc3719cf95ebe81a41fa3bcd54302e61d25af52a397857c1f00b1fd48179c3dc',
        (0x35FA4,0x35FCE):'639401244ab581b4834fc6643516dcd366f5b6f202f6355bf423563d4e5f2f45',
        (0x35EB8,0x35ED6):'749bd7c31c7cfbea13b3183bca977cb263369acebbc2a4163eeeb14692f09fc5',
        (0x4B284,0x4B3AC):'6d7fe1df18d56d04e6f68a8caf7e9461cadff403f56b8cd62fddff120029c630',
        (0x4B464,0x4B4E8):'d313566002134a6b433e6294a9746a7af2eb39bf55b0aebe010eb4652187e001',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Scheduler-clock code range differs")
    literals = {0x35F20:0x40011000,0x35F28:0x40011008,
                0x35FD0:0x40011000,0x35FD4:0x20007614,0x35ED8:0x20007614}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Scheduler-clock literal differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'rtcDeclaration':{'initializer':'0x35edc','base':'0x40011000','counterOffset':1284,'prescalerOffset':1288,
                          'prescalerWrite':0,'startWrite':1},
        'elapsedConversion':{'entry':'0x35fa4','baselineRAM':'0x20007614',
                             'behavior':'Read COUNTER, subtract the baseline, extract bits 5..23 (floor count difference /32 modulo the counter range)'},
        'announceConversion':{'entry':'0x35eb8','baselineRAM':'0x20007614',
                              'behavior':'Advance baseline by the aligned counter difference; pass its bits 5..23 to 0x4b464'},
        'timeoutInsertion':'0x4b284 adds one to the 64-bit timeout except its all-ones special path, then handles elapsed compensation and ordered timeout-list insertion',
        'expiryCallbackPrefix':'0x4b464 consumes elapsed units and, for an expired node in the inspected prefix, loads callback at node+8 and invokes it at 0x4b4e6',
        'nominalClockInference':{'source':'https://docs.nordicsemi.com/r/bundle/ps_nrf52833/page/rtc.html',
                                 'manufacturerCounterHzFormula':'32768/(PRESCALER+1)',
                                 'counterCountsPerSchedulerUnit':32,'nominalUnitsPerSecond':1024,
                                 'nominalUnitMilliseconds':0.9765625,
                                 'condition':'Inference for the declared RTC1 prescaler-zero initialization using nominal LFCLK; not a measured live rate or deadline'},
        'limits':'Fixed initialization and count conversion only. LFCLK startup, installed firmware, clock accuracy, all timeout/list branches and live queue latency remain unproved. Parameter 50 is not an exact 50ms wait or host persistence barrier; no guessed waits, hardware access or additional write authorization.'}



def inspect_factory_event_path(image):
    """Pin reset candidates without constructing or sending a hardware request."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Factory-event address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x2EEB4,0x2EF0C):'e46891f3348ae31df0f133ba45181bceab76eb3f2d84b056c62b717cb82eb0da',
        (0x2D49C,0x2D4D4):'e2fba12fdc216c7bad7bc73f6bb186a22ce8c191f7142379e1393b0a20f81e0a',
        (0x2EFF0,0x2F000):'f8d1d68d1972705a62d1d3ada62159a5f4a101802ec7b4dd5e89240150e9a0d2',
        (0x2F488,0x2F496):'46717d2b47e68ade5944da1f0d2446eba86ba92c7d4f6ae3ce807b5f73d53abf',
        (0x2F516,0x2F538):'07419cf3e668221067ea68cc1d956baa674b7a30e8fd5d6eb5750e3e3bac1c06',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Factory-event code body differs")
    commands = {0x0D:0x2F488,0x21:0x2F516,0x22:0x2F52A}
    for command, expected in commands.items():
        destination = 0x2F0F4 + 2*struct.unpack('<H',at(0x2F0F4+2*(command-3),2))[0]
        if destination != expected:
            raise ValueError("Factory-event command branch differs")
    literals = {0x2F054:0x527B8,0x2D4E4:0x527B8,0x527B8:0x4F54C,
                0x2EF0C:0x4F264,0x2EF10:0x20000CD8,0x2EF18:0x4D738,
                0x2EF1C:0x20000A98,0x2EF24:0x4F2A4,0x2EF28:0x20000D18,
                0x2EF30:0x200054EC,0x2EF34:0x20009B26}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Factory-event literal differs")
    if at(0x4F54C,len(b'userflash_event\0')) != b'userflash_event\0':
        raise ValueError("Factory-event type name differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'commandCandidates':{hex(k):hex(v) for k,v in commands.items()},
        'eventBuilder':{'entry':'0x2d49c','type':'userflash_event','typeAddress':'0x527b8','publish':'0x3737c',
                        'modesByCommand':{'0x0d':1,'0x21':3,'0x22':2},
                        'fields':{'byte8':1,'byte9':'1 iff mode equals 2','byte10':'1 iff mode equals 3'}},
        'eventConsumer':{'listener':'0x2ef3c','branch':'0x2eff0',
                         'behavior':'When event byte8 is nonzero, clear it and call 0x2eeb4'},
        'resetHelper':{'entry':'0x2eeb4',
                       'copies':[{'sourceROM':'0x4f264','destinationRAM':'0x20000cd8','length':64},
                                 {'sourceROM':'0x4d738','destinationRAM':'0x20000a98','length':512},
                                 {'sourceROM':'0x4f2a4','destinationRAM':'0x20000d18','length':512}],
                       'macroZeroPrefix':{'destinationRAM':'0x200054ec','length':128,'entireBankCleared':False},
                       'saveCalls':['0x2ec50','0x2ea48','0x2ee24'],
                       'otherCall':'0x2c1b4; remaining side effects still require correlation'},
        'limits':'Fixed named command/event/helper paths only. All other event consumers, command branch flags, event dispatch ordering, pairing/radio effects, macro playback after prefix clearing, Windows button equivalence and live firmware identity remain unproved. Not a reset implementation or authorization; no requests generated or sent.'}



def inspect_factory_event_identity_branches(image):
    """Separate secondary event branches from configuration-only reset scope."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Factory-event secondary address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x24070,0x240BE):'88143db5aeb1e3b6c835becf8c73189de26abd8eb5de1f21084eaa2a4c6001dd',
        (0x2450A,0x2453A):'1b7b5142470d88d2a7ea97a45f42bacf6b414f97115ccb31cd54666baf0b6b5c',
        (0x24566,0x245C8):'f6e3fe6dae882a90947514044ff22bc0b887a37ddc083e6c00acc44ef6e6c72d',
        (0x23A98,0x23AC0):'2639f96b0c15daf4b62a17d079ce13e4bc191baa9721fbe0e48f6ccbc4aff5f8',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Factory-event secondary body differs")
    literals = {0x2436C:0x527B8,0x23AC0:0x20009A8C,0x23AC4:0x20003EDC,
                0x2469C:0x20009A8C,0x246B4:0x20003EDC}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Factory-event secondary selector differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'listener':'0x24070','eventType':'userflash_event','typeLiteral':'0x2436c','branch':'0x2450a',
        'mode2Flag':{'eventByte':9,'branch':'0x24566','requestedSlots':[0,1,2],
                     'behavior':'Clear event byte9 and another internal byte; for each requested slot, call 0x23a98 followed by 0x3c9b8 with the selected first argument and zero second/third arguments'},
        'mode3Flag':{'eventByte':10,'branch':'0x2450e',
                     'condition':'Byte9 is zero and byte10 is nonzero','requestedSlots':[3],
                     'behavior':'Clear event byte10; call 0x23a98 then 0x3c9b8 with selected first argument and zero second/third arguments'},
        'selector':{'stateRAM':'0x20009a8c','tableRAM':'0x20003edc',
                    'behavior':'State 4 or 5 selects table byte4 regardless of requested slot; other states select the requested table byte'},
        'slotHelper':{'entry':'0x23a98','downstream':'0x3c2e0',
                      'behavior':'Select the same table entry, prepare a zero seven-byte structure on stack and pass its pointer as the second argument'},
        'limits':'Proves distinct secondary calls, not their complete pairing/identity semantics. The downstream implementation, all event listeners and ordering, protocol enum values, installed firmware and Windows button correspondence still need classification. Mode2/3 candidates are not configuration-only reset requests; no commands generated or sent.'}



def inspect_factory_related_storage(image):
    """Pin the secondary path to Bluetooth-named records, without applying it."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Factory-related storage address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x3c2e0,0x3c32e):'2d1744e6e818a3d352c30ae8a51c16cec6144c3a47a75306032d8c77921aa668',
        (0x43de8,0x43e26):'b58bdf68d6f7df33a5dd82c5196a4af11f9cbfdd05871e7a7f436ae87a9cd962',
        (0x3ac44,0x3acb4):'6adcb0152eb31031bea7892bb9e975dc0cc4312fef875749be22faf8a195878b',
        (0x3acb8,0x3acc2):'6c43fac5cc6de306969c9929106578b8bd194364f2c4ae2129855d984f2d1bad',
        (0x43fcc,0x44016):'77b478545a4b002403d9cddc4bd93b2ce56f2e35b02fd3f30dd51ea02d1a3f0f',
        (0x41814,0x41878):'3592a4b18037932a1c0b6e3f04f71aa8157f9e7f46b3a609f1d1b633bae672c9',
        (0x339f0,0x339f8):'2407cd74eb344ac5715845f86566ebda8b7a4ba36e224ae88e1c65dd6230c040',
        (0x3a864,0x3a8be):'df12ce2d3ee2db7af1001ad446d9c8330a7967e9b64f6c8d4009abbd23f98385',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Factory-related storage code differs")
    literals = {0x3C330:0x3ACB9,0x3CA6C:0x3ACB9,0x44018:0x501E0,
                0x4187C:0x4FFC0,0x3A8C0:0x4FC58,0x3A8C4:0x4FC7C}
    for address, expected in literals.items():
        if struct.unpack('<I',at(address,4))[0] != expected:
            raise ValueError("Factory-related storage literal differs")
    for address, name in [(0x501E0,b'keys\0'),(0x4FFC0,b'ccc\0'),
                          (0x4FC58,b'bt/%s/%02x%02x%02x%02x%02x%02x%u/%s\0'),
                          (0x4FC7C,b'bt/%s/%02x%02x%02x%02x%02x%02x%u\0')]:
        if at(address,len(name)) != name:
            raise ValueError("Factory-related storage format differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'selectedRecordPath':{'entry':'0x3c2e0',
                              'behavior':'When the supplied seven-byte value is null or all-zero, iterate matching records through 0x43de8 with callback 0x3acb9'},
        'iterator':{'entry':'0x43de8','rowStride':132,'declaredTableBytes':660,
                    'behavior':'Skip rows with an empty marker; match the selected byte preceding the seven-byte row value, copy that value and invoke the callback'},
        'recordCallback':{'entry':'0x3acb8','target':'0x3ac44',
                          'downstream':['0x43f7c','0x43fcc','0x41814'],
                          'limits':'Includes connection/state and conditional record paths; not every branch is fully classified'},
        'keyRecordPath':{'entry':'0x43fcc','namespace':'bt/keys',
                         'behavior':'Construct a Bluetooth-address-based name through 0x3a864, call 0x339f0, then clear 132 bytes of the RAM record'},
        'cccRecordPath':{'entry':'0x41814','namespace':'bt/ccc',
                         'behavior':'Construct another address-based name and call 0x339f0; other setup and cleanup calls remain to be classified'},
        'zeroLengthOperation':{'entry':'0x339f0','target':'0x33924','payloadPointer':0,'length':0},
        'limits':'Proves Bluetooth-named record operations and RAM clearing, not complete pairing removal, zero-length backend tombstone semantics, all connection effects or live persistence. This is outside normal key/color/macro configuration restoration. Candidate commands remain unimplemented and unsent; no hardware access.'}



def inspect_pairing_endpoint_commands(image):
    """Separate keyboard-image effects from receiver Utility predicates."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or offset+size>len(image):
            raise ValueError("Pairing command evidence exceeds image bounds")
        return image[offset:offset+size]
    bodies={
        (0x2f2b8,0x2f2be):"a9859aaae1615603ec45704596c7caa40c96644055da1047b05945b4201a4ae9",
        (0x2f556,0x2f56a):"38f4380c2e7494a81bef308c44d815c9b41c52247cd70a06acac1c113c487ddf",
    }
    for (start,end),expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest()!=expected:
            raise ValueError("Endpoint-specific command body differs")
    commands={0x20:0x2f2b8,0x21:0x2f516,0xa0:0x2f2b8,0xa1:0x2f2b8,0xaa:0x2f556}
    for command,target in commands.items():
        if 0x2f0f4+struct.unpack("<H",at(0x2f0f4+(command-3)*2,2))[0]*2!=target:
            raise ValueError("Endpoint-specific command dispatch differs")
    checks={0x2f2b8:"ff23f371",0x2f51a:"00200122087003201a70",
            0x2f524:"fdf7baff",0x2f558:"2a7a1a70",0x2f560:"687aaa7a08701a70"}
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):
            raise ValueError("Endpoint-specific command instruction differs")
    literals={0x2f648:0x20009b08,0x2f64c:0x20009b03,0x2f650:0x20009ace}
    for address,value in literals.items():
        if struct.unpack("<I",at(address,4))[0]!=value:
            raise ValueError("Keyboard AA destination literal differs")
    defaults=[]
    for name,rom,size in [("parameters",0x4f264,64),("keymap",0x4d738,512),("colors",0x4f2a4,512)]:
        data=at(rom,size)
        defaults.append({"region":name,"sourceROM":hex(rom),"bytes":size,
                         "SHA256":hashlib.sha256(data).hexdigest(),"lastOffset":size-1,"lastByte":data[-1]})
    return {"endpoint":"Keyboard image USB046a:01ce/descriptor0104 only; receiver firmware not supplied",
            "codeSHA256":{f"{a:#x}..{b:#x}":h for (a,b),h in bodies.items()},
            "instructionChecks":len(checks),"dispatch":{hex(k):hex(v) for k,v in commands.items()},
            "keyboardStart21":{"branch":"0x2f516", "eventBuilder":"0x2d49c", "mode":3,
                "reuse":"factoryEventPath pins the complete branch, event byte8=1, byte10=1, reset consumer and all three ROM-to-RAM copies",
                "configurationEffects":"Named consumer resets all64 parameter bytes, all512 key/color bytes and128 macro-header bytes; other event consumers handle secondary records"},
            "rejectedOnKeyboard":["0x20","0xa0","0xa1"],
            "keyboardAA":{"payloadOffsets":[8,9,10],"destinationRAM":["0x20009b08","0x20009b03","0x20009ace"],
                          "effect":"Stores three incoming bytes; not the receiver Utility byte8-FF polling predicate"},
            "resetROMDefaults":defaults,
            "limits":"Uses fixed legacy keyboard image and already pinned factory-event paths, not live0102 firmware. No whole-program event-order proof, complete pairing persistence or receiver command meaning. ROM default tails cannot substitute for pre-operation backup tails; missing capture bytes remain unknown. No requests generated or sent."}




def inspect_hid_callback_read_sources(image):
    """Pin named callback/cache sources; do not infer USB or live BLE capability."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or size<0 or offset+size>len(image):
            raise ValueError("Callback source evidence exceeds image bounds")
        return image[offset:offset+size]
    bodies={
        (0x27638,0x276b6):"4e4de46f844a9ff1070b7d6c38dbc7cd6ec1377c319bb7737f4d2ce6e9a5390a",
        (0x276fc,0x27712):"5913ddb5e8c5583ab11d9b74e90df11372febd0c7183bb6014c192c216a177ac",
        (0x27f00,0x27f20):"70cceb129f8330a141373a788035ae5bb16140843998a547c736d33493e83899",
        (0x36a8c,0x36afa):"9536feccd375aa0f50ae34fc41cb0d51143abdd7cf3c69f0569dc11b070ea6ab",
        (0x27718,0x277c8):"366b0bde0c6ac5563090506e76ce95657335d9005325b9eea2b2fc5f6f2122ca",
    }
    for (a,b),digest in bodies.items():
        if hashlib.sha256(at(a,b-a)).hexdigest()!=digest:
            raise ValueError("HID callback source body differs")
    literals={0x276e8:0x276fd,0x276f0:0x27719,0x27714:0x200033e0,0x27804:0x200060ec}
    for address,value in literals.items():
        if struct.unpack("<I",at(address,4))[0]!=value:
            raise ValueError("HID callback source literal differs")
    checks={0x27650:"9c959f95",0x2768a:"184b",0x27690:"174da993",
            0x276b0:"01a90ff0ebf9",0x36aa6:"41f61203",0x36aba:"42f64e21",
            0x36b16:"42f64d2c",0x27750:"95b10378042b",0x27764:"07f096bc",
            0x27778:"22792249bde8f84312f080bc",0x27f06:"04f1360112f0bbf8"}
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):
            raise ValueError("HID callback routing instruction differs")
    return {"codeSHA256":{f"{a:#x}..{b:#x}":h for (a,b),h in bodies.items()},
            "instructionChecks":len(checks),
            "registration":{"site":"0x27638..0x276b6", "method":"0x36a8c",
                "callback276FC":"Thumb literal0x276fd copied tostack+0x270 and+0x27c",
                "callback27718":"Thumb literal0x27719 copied tostack+0x2a4",
                "serviceUUID":"0x1812", "characteristicUUIDs":["0x2a4e","0x2a4d"],
                "classification":"Bluetooth HID service identifiers; named registration is not proof of USB GET_REPORT routing",
                "assignedNumbersSource":"https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/Assigned_Numbers.pdf?v=1706572800142"},
            "callback276FC":{"directionArgument":"r2","whenZero":"tail-call0x27f00 with object0x200033e0 and caller buffer/count",
                "readSourceRAM":"0x20003416", "copy":"object+0x36 through0x3a084; count comes from request structure byte4",
                "readSideEffect":"If object byte0x53 is3, set it to1 after copying",
                "whenNonzero":"tail-call0x27f20; no new read candidate generated"},
            "callback27718":{"directionArgument":"r2 preserved inr5",
                "whenZero":"Copy caller count from cached reportRAM0x200060ec through0x3a084",
                "whenNonzero":"Requires reportID4; handles commands23/24 locally, others tail-call0x2f094",
                "prelude":"May allocate/publish events before checking direction; callback is not globally side-effect-free"},
            "configurationTailSourceDiscovered":False,
            "limits":"Fixed0104 code and named callback sources only. Full report-row binding, incoming USB/BLE dispatch, current0102 implementation, host permissions and wireless writes remain unproved. No report9/feature reads generated, no emulation, device access or configuration changes."}


def inspect_nonreading_control_branches(image):
    """Keep adjacent allocation-failure code distinct from command27 flag writes."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or size<0 or offset+size>len(image):
            raise ValueError("Control classification exceeds image bounds")
        return image[offset:offset+size]
    bodies={
        (0x2f56a,0x2f598):"c014257e66969c737fa905b707e30ca8b96aab9a4b44ec744cb716ff9ccbd58f",
        (0x2f372,0x2f3a2):"280e6095c66ea36b3218bff509f0c09fa3487147487de503558aa05634b6055b",
        (0x2f59c,0x2f5d8):"9ebf5356d43d65bbe06e6330966142b102477a417d0e6a5b2b53ad7983fe7d3a",
        (0x34754,0x3477e):"dbd645d40769a9f1b974c917156620604321ec546391c7745e47a1def4204739",
    }
    for (a,b),digest in bodies.items():
        if hashlib.sha256(at(a,b-a)).hexdigest()!=digest:
            raise ValueError("Nonreading control body differs")
    table=0x2f0f4
    targets={0x27:0x2f572,0xb0:0x2f372}
    for command,target in targets.items():
        if table+2*struct.unpack("<H",at(table+2*(command-3),2))[0]!=target:
            raise ValueError("Nonreading control dispatch differs")
    literals={0x2f650:0x20009ace,0x2f658:0x20009ab7,
              0x2f654:0x4c098,0x34780:0x4f900}
    for address,value in literals.items():
        if struct.unpack("<I",at(address,4))[0]!=value:
            raise ValueError("Nonreading control literal differs")
    strings={0x4c098:b"Event Manager OOM error\n\0",
             0x4f900:b"Failed to reboot: spinning endlessly...\n\0"}
    for address,value in strings.items():
        if at(address,len(value))!=value:
            raise ValueError("Failure-path message differs")
    return {"codeSHA256":{f"{a:#x}..{b:#x}":h for (a,b),h in bodies.items()},
            "command27":{"target":"0x2f572","payloadByte":8,
                "zeroBranch":"0x2f574 CBZ targets0x2f58c, not adjacent0x2f57e",
                "zeroEffect":"Store1 atRAM0x20009ab7",
                "nonzeroEffect":"Store1 atRAM0x20009ace",
                "return":"Both named paths branch to0x2f28a; neither selects a configuration source"},
            "commandB0":{"target":"0x2f372","allocator":"0x4bcb4",
                "failureBranches":["0x2f5bc","0x2f5ca"],
                "effect":"Allocation failures print the OOM message and call0x34754; normal paths allocate and publish events, not configuration replies"},
            "adjacentFailureCode":{"range":"0x2f57e..0x2f58c",
                "effect":"Print OOM, pass request pointer to0x34754; adjacency does not identify its incoming control flow"},
            "failureHandler":{"range":"0x34754..0x3477e",
                "effect":"Raises BASEPRI to0x40, calls0x35dd0 then0x3a1f0, prints failed-reboot message, loops between0x34778 and0x3477c",
                "nonreturningNamedBody":True},
            "configurationReadCandidateCreated":False,
            "limits":"Fixed packaged0104 image only. No whole-program caller inventory, current firmware equivalence, exact downstream reset behavior, blackout causation or execution. No commands generated or sent; missing keymap byte remains unknown."}


def inspect_status_region_aliases(image):
    """Pin a bounded candidate calculation, not current device read support."""
    def at(address,size):
        offset=address-0x10000
        if offset<0 or offset+size>len(image):raise ValueError("Status alias evidence exceeds image bounds")
        return image[offset:offset+size]
    segment=(0x2f4f4,0x2f4fe)
    expected="0663ed314b801976291296ee4a2587fb459092a08ba27af671d72db5c9844073"
    if hashlib.sha256(at(segment[0],segment[1]-segment[0])).hexdigest()!=expected:
        raise ValueError("Status alias source branch differs")
    checks={0x2f0a2:"ec782f79b5f80580",0x2f4f4:"4e4a3c4b02eb080928e7",
            0x2f354:"3a464946a448",0x2f35a:"0af093fe"}
    for address,encoded in checks.items():
        if at(address,len(bytes.fromhex(encoded)))!=bytes.fromhex(encoded):
            raise ValueError("Status alias offset/copy instruction differs")
    base=struct.unpack("<I",at(0x2f630,4))[0]
    if base!=0x20000c98:raise ValueError("Status alias source literal differs")
    candidates=[]
    for name,ram,offset in [("parameters",0x20000cd8,63),("colors",0x20000d18,511),("macroData",0x200054ec,3071)]:
        address=ram+offset;relative=address-base
        if not 0<=relative<=65535:raise ValueError("Status alias candidate offset invalid")
        candidates.append({"region":name,"regionOffset":offset,"RAMAddress":hex(address),"statusReadOffset":relative,"requestedBytes":1})
    info=at(0x4f224,34)
    return {"command":29,"branch":"0x2f4f4..0x2f4fe","segmentSHA256":expected,
            "instructionChecks":len(checks),"sourceBaseRAM":hex(base),"sourceLiteral":"0x2f630",
            "offsetEncoding":"Report bytes5..6 are loaded as unsigned halfword into r8; source becomes base+r8",
            "copy":"Shared0x2f350 path uses request byte4 as count and0x3a084 to copy source into reply payload",
            "branchBounds":"This named1D branch has no additional offset or offset+length guard; not a whole-entry or USB-stack bounds proof",
            "tailReadCandidates":candidates,
            "keymapTail":{"RAMAddress":"0x20000c97","relativeOffset":-1,"candidateCreated":False,"reason":"Below base; never reinterpret -1 as65535 or assume RAM mirroring"},
            "deviceInfoROM":{"address":"0x4f224","bytes":34,"SHA256":hashlib.sha256(info).hexdigest()},
            "limits":"Fixed0104 keyboard image only. Matching info bytes do not identify current firmware code. Three positive offsets are unexecuted read candidates, not captured tail data or proof of current1D support; no arbitrary RAM reader, missing key byte, wireless identity backup or write plan. No reports sent."}


def inspect_backup_boundaries(image):
    """Pin strict versus inclusive bounds; does not create a capture plan."""
    bodies = {
        (0x2f250,0x2f25e):'a166799587f90eb918baec488fc933ef0af5cf65e52d563e4bae5ebf52b35d32',
        (0x2f3ba,0x2f3cc):'d5335e97216eac624076cbac6d2de4650bf14c71731bb801fe551d17a2b07f50',
        (0x2f3f4,0x2f426):'cf616b3f9f4bed726b16334dfa97f90509dc17d00e2a653a2d4d31170571463a',
        (0x2f43e,0x2f470):'57f4d3c339a819ea1d0d8a636a90c099ff16dfc041e388e70ae216163c603200',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(image[start-0x10000:end-0x10000]).hexdigest()!=expected:
            raise ValueError("Backup access boundaries differ")
    return {
        'codeSHA256':{f'{a:#x}..{b:#x}':v for (a,b),v in bodies.items()},
        'parameters':{'readGuard':'0x2f3ba','writeGuard':'0x2f250',
                      'offsetMaximumInclusive':63,'offsetPlusLengthMaximumInclusive':63,
                      'maximumPositiveLengthPrefix':63,'uncoveredLastOffsetIn64ByteRegion':63},
        'keymap':{'readGuard':'0x2f3f4','writeGuard':'0x2f412',
                  'offsetMaximumExclusive':512,'offsetPlusLengthMaximumExclusive':512,
                  'maximumPositiveLengthPrefix':511,'uncoveredLastOffsetIn512ByteRegion':511},
        'colors':{'readGuard':'0x2f43e','writeGuard':'0x2f45c',
                  'offsetMaximumExclusive':512,'offsetPlusLengthMaximumExclusive':512,
                  'maximumPositiveLengthPrefix':511,'uncoveredLastOffsetIn512ByteRegion':511},
        'macroReference':'reportDispatcher independently pins strict3072 boundary and3071-byte prefix',
        'limits':'Positive-length access through these specific command guards only. Other interfaces, tail-byte uses, installed firmware identity and reset effects in current hardware are unproved. Ordinary378-byte snapshots are not complete512-byte preservation evidence. No capture or write plan is generated.'}


def inspect_zero_length_record_semantics(image):
    """Pin empty-record serialization and load-time filtering of named values."""
    def at(address, size):
        offset = address - 0x10000
        if offset < 0 or size < 0 or offset + size > len(image):
            raise ValueError("Empty-record address exceeds image bounds")
        return image[offset:offset + size]

    bodies = {
        (0x34020,0x340D8):'aa02f60b6ab08fbdb98b52a90cc3cb328c4522032674fbf7b50f67ce9161db0e',
        (0x340D8,0x340E2):'d817ac7cf8be8661ab98d01da1f586574ca3fb598da9cb508e5eb0486d150ca0',
        (0x33DAC,0x33E88):'2c4e7c7a4d91c9050fc162f4c68decdfdcf9ca63ae8c588ca8ec598294cf406c',
        (0x33E8C,0x33E9A):'02cb885994eda9c1e732684c53d1b8b90fa561c3a254a594d56d98c53decb59e',
    }
    for (start,end), expected in bodies.items():
        if hashlib.sha256(at(start,end-start)).hexdigest() != expected:
            raise ValueError("Empty-record code body differs")
    if struct.unpack('<I',at(0x340E4,4))[0] != 0x33FED:
        raise ValueError("Named loader callback differs")
    return {
        'codeSHA256':{f'{start:#x}..{end:#x}':digest for (start,end),digest in bodies.items()},
        'recordSize':'0x33e8c computes name length + 1 + payload length',
        'serializer':{'entry':'0x33dac','separatorByte':61,
                      'behavior':'Serialize name, append =, copy payload only while remaining payload length is nonzero, align and send through the registered writer. A zero-length operation still has a named record'},
        'loadWrapper':{'entry':'0x340d8','walk':'0x34020','filterFlag':1,'callbackThumbPointer':'0x33fed'},
        'emptyFilter':{'entry':'0x34064',
                       'behavior':'With the load filter enabled, skip a record when parsed name length + 1 is greater than or equal to the record length'},
        'sameNameFilter':{'entry':'0x34070',
                          'behavior':'Walk following records and compare names with 0x39ffc. A matching name skips the earlier record, without requiring a nonempty value in that matching record'},
        'inference':'Together these fixed paths support a named empty record acting as a logical deletion marker once successfully committed. This is not a whole-flash erase or proof that every affected Bluetooth record was successfully removed',
        'limits':'Fixed serializer and loading filters only. Record iterator order/recovery, commit failures, reclamation, all same-value shortcuts, installed firmware and physical retention still require confirmation. Candidate factory commands remain unimplemented and unsent; no hardware access.'}


def download_resources(pe):
    optional = pe.u32(0x3C) + 24
    base = pe.base + pe.u32(optional + 96 + 2 * 8)

    def entries(offset):
        header = struct.unpack("<II4H", pe.at(base + offset, 16))
        count = header[-2] + header[-1]
        if count > 512:
            raise ValueError("Resource directory exceeds bounds")
        return [struct.unpack("<II", pe.at(base + offset + 16 + i * 8, 8)) for i in range(count)]

    def name(value):
        if not value & 0x80000000:
            return value
        address = base + (value & 0x7FFFFFFF)
        length = struct.unpack("<H", pe.at(address, 2))[0]
        if length > 128:
            raise ValueError("Resource name exceeds bounds")
        return pe.at(address + 2, length * 2).decode("utf-16-le")

    result = {}
    for kind, directory in entries(0):
        if name(kind) != "DOWNLOAD":
            continue
        if not directory & 0x80000000:
            raise ValueError("Invalid DOWNLOAD resource directory")
        for identifier, languages in entries(directory & 0x7FFFFFFF):
            if identifier not in (129, 141) or not languages & 0x80000000:
                raise ValueError("Unexpected DOWNLOAD resource identifier")
            for language, leaf in entries(languages & 0x7FFFFFFF):
                if language not in (0, 2052) or leaf & 0x80000000 or (identifier, language) in result:
                    raise ValueError("Unexpected or duplicate DOWNLOAD language")
                rva, size, _, _ = struct.unpack("<4I", pe.at(base + leaf, 16))
                if not 0 < size <= 1_000_000:
                    raise ValueError("DOWNLOAD resource size exceeds bounds")
                result[identifier, language] = pe.at(pe.base + rva, size)
    if set(result) != {(129, 0), (129, 2052), (141, 0), (141, 2052)}:
        raise ValueError("Missing expected DOWNLOAD resources")
    return result


def inspect(path):
    source = Path(path)
    if source.stat().st_size != 4_873_728:
        raise ValueError("Unexpected updater size")
    data = source.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("Updater differs from the analyzed official download")
    spec = importlib.util.spec_from_file_location("settings_pe_reader", Path(__file__).with_name("inspect-official-settings.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    resources = download_resources(module.PE32(data))
    # The fixed neutral resource contains a literal newline in a UI string.
    # Preserve its bytes/hash; relax string control characters only for reading.
    configurations = {lang: json.loads(resources[141, lang], strict=False)['device'] for lang in (0, 2052)}
    target = configurations[0]
    if (target.get('device_VID'), target.get('device_PID'), target.get('device_REV')) != ('046A', '01CE', '0104'):
        raise ValueError("Target resource configuration identity differs")
    image = resources[129, 0]
    if len(image) != 272_876 or hashlib.sha256(image).hexdigest() != IMAGE_SHA256:
        raise ValueError("Target firmware image differs")
    descriptor_offset = 0x421C4
    descriptor = image[descriptor_offset:descriptor_offset + 18]
    if descriptor != bytes.fromhex('12010002000000406a04ce01040101020001'):
        raise ValueError("Target USB descriptor bytes differ")
    strings = [(m.start(), m.group()[:-1].decode('ascii')) for m in re.finditer(rb'[\x20-\x7e]{7,}\x00', image)]
    banks = {}
    for prefix, expected in [('led_define_', 8), ('kb_matrix_', 8), ('macro_data_', 48)]:
        rows = [{'offset': hex(offset), 'name': text} for offset, text in strings if re.fullmatch(re.escape(prefix) + r'[1-9]\d*', text)]
        if sorted(int(row['name'][len(prefix):]) for row in rows) != list(range(1, expected + 1)):
            raise ValueError("Firmware storage-name inventory differs")
        banks[prefix] = rows
    anchors = []
    for text in ('MX 3.0S Pokemon', 'led_define_1', 'macro_data_1'):
        offset = image.find(text.encode('ascii') + b'\0')
        if offset < 0:
            raise ValueError("Missing target firmware anchor")
        pointer = struct.pack('<I', offset + 0x10000)
        references = [m.start() for m in re.finditer(re.escape(pointer), image) if m.start() % 4 == 0]
        if not references:
            raise ValueError("Missing candidate link-base pointer anchor")
        anchors.append({'name': text, 'offset': hex(offset), 'candidateAddress': hex(offset + 0x10000),
                        'alignedPointerOffsets': [hex(value) for value in references]})
    return {'format': 'CherryMacOfficialPokemonFirmwareStaticAudit', 'version': 26,
            'updaterSHA256': digest, 'updaterMD5': hashlib.md5(data).hexdigest(),
            'method': 'Read-only PE32 resource parsing and fixed-byte inspection; no execution, emulation or hardware access',
            'resources': [{'id': identifier, 'language': language, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                          for (identifier, language), raw in sorted(resources.items())],
            'configurations': configurations,
            'targetImage': {'resource': {'id': 129, 'language': 0}, 'size': len(image), 'sha256': IMAGE_SHA256,
                            'usbDescriptorOffset': hex(descriptor_offset), 'vendorID': 0x046A, 'productID': 0x01CE,
                            'descriptorBCDDevice': 0x0104, 'initialVectorWords': list(struct.unpack_from('<4I', image)),
                            'candidateLinkBase': '0x10000', 'pointerAnchors': anchors, 'storageNames': banks},
            'macroEventDispatchAndRelease': inspect_macro_event_dispatch_and_release(image),
            'macroZeroEventPath': inspect_macro_zero_event_path(image),
            'reportDispatcher': inspect_report_dispatcher(image, banks),
            'storageSavePaths': inspect_storage_save_paths(image),
            'saveScheduler': inspect_save_scheduler(image),
            'concreteStorageBackend': inspect_concrete_backend(image),
            'flashBinding': inspect_flash_binding(image),
            'flashCompletion': inspect_flash_completion(image),
            'reportReplyCache': inspect_report_reply_cache(image),
            'parameterConsumers': inspect_parameter_consumers(image),
            'lightFlagCallback': inspect_light_flag_callback(image),
            'customLightingOutput': inspect_custom_lighting_output(image),
            'macroBlockSaving': inspect_macro_block_saving(image),
            'saveWorkRegistration': inspect_save_work_registration(image),
            'queueWorker': inspect_queue_worker(image),
            'schedulerClock': inspect_scheduler_clock(image),
            'factoryEventPath': inspect_factory_event_path(image),
            'factoryEventIdentityBranches': inspect_factory_event_identity_branches(image),
            'factoryRelatedStorage': inspect_factory_related_storage(image),
            'zeroLengthRecordSemantics': inspect_zero_length_record_semantics(image),
            'backupBoundaries': inspect_backup_boundaries(image),
            'pairingEndpointCommands': inspect_pairing_endpoint_commands(image),
            'statusRegionAliases': inspect_status_region_aliases(image),
            'nonreadingControlBranches': inspect_nonreading_control_branches(image),
            'hidCallbackReadSources': inspect_hid_callback_read_sources(image),
            'hardwareReady': False, 'firmwareUpgradeImplemented': False,
            'limits': 'The package contains two different images/configurations under different resource languages. The neutral resource has target identity and its image contains the target USB descriptor and model strings; updater runtime resource selection is not proved. No claim about installed firmware, name-to-bank capacity, command decoding, flash persistence or blackout cause. Storage names and pointer anchors guide further firmware analysis only.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('updater', help='Local official Pokémon 0104 updater; read only')
    args = parser.parse_args()
    try:
        print(json.dumps(inspect(args.updater), ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, struct.error, UnicodeError) as error:
        parser.exit(1, str(error) + '\n')
