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
        'limits':'Fixed registration and named deferred enqueue paths only. Initializer call reachability, queue worker callback dispatch, actual scheduling, duration units, every cancellation/error branch, USB completion and installed firmware identity remain unproved. Do not treat 50 as milliseconds or add guessed host waits. No execution or hardware access.'}


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
    return {'format': 'CherryMacOfficialPokemonFirmwareStaticAudit', 'version': 11,
            'updaterSHA256': digest, 'updaterMD5': hashlib.md5(data).hexdigest(),
            'method': 'Read-only PE32 resource parsing and fixed-byte inspection; no execution, emulation or hardware access',
            'resources': [{'id': identifier, 'language': language, 'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                          for (identifier, language), raw in sorted(resources.items())],
            'configurations': configurations,
            'targetImage': {'resource': {'id': 129, 'language': 0}, 'size': len(image), 'sha256': IMAGE_SHA256,
                            'usbDescriptorOffset': hex(descriptor_offset), 'vendorID': 0x046A, 'productID': 0x01CE,
                            'descriptorBCDDevice': 0x0104, 'initialVectorWords': list(struct.unpack_from('<4I', image)),
                            'candidateLinkBase': '0x10000', 'pointerAnchors': anchors, 'storageNames': banks},
            'reportDispatcher': inspect_report_dispatcher(image, banks),
            'storageSavePaths': inspect_storage_save_paths(image),
            'saveScheduler': inspect_save_scheduler(image),
            'concreteStorageBackend': inspect_concrete_backend(image),
            'flashBinding': inspect_flash_binding(image),
            'flashCompletion': inspect_flash_completion(image),
            'reportReplyCache': inspect_report_reply_cache(image),
            'parameterConsumers': inspect_parameter_consumers(image),
            'macroBlockSaving': inspect_macro_block_saving(image),
            'saveWorkRegistration': inspect_save_work_registration(image),
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
