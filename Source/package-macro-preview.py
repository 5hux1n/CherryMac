#!/usr/bin/env python3
"""Package an already signed macro product app; never launch it."""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile

if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--lighting-acceptance'):
    raise SystemExit('Usage: python3 Source/package-macro-preview.py OUTPUT_DIRECTORY [--lighting-acceptance]')
lighting_acceptance = len(sys.argv) == 3
root = pathlib.Path(__file__).resolve().parent
output_dir = pathlib.Path(sys.argv[1]).resolve()
app = output_dir / ('CherryMacLightingAcceptance.app' if lighting_acceptance else 'CherryMacMacroPreview.app')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != ('local.cherrymac.lighting-acceptance' if lighting_acceptance else 'local.cherrymac.macro-product-preview'):
    raise SystemExit('Refusing to package a different app identity')
version = info['CFBundleShortVersionString']
prefix = f'CherryMac-LightingAcceptance-{version}' if lighting_acceptance else f'CherryMac-MacroPreview-{version}'
output = output_dir / (prefix + '.zip')
checksum_file = output.with_suffix('.zip.sha256')
manifest_file = output_dir / 'manifest.json'
if any(path.exists() for path in [output, checksum_file, manifest_file]):
    raise SystemExit('Refusing to overwrite an existing preview artifact')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'Source'], cwd=root.parent, check=True)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
if info.get('CherryMacSourceCommit') != commit:
    raise SystemExit('App source commit differs; rebuild with the preview build script')
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True).split()
files = {path.relative_to(app).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
         for path in sorted(app.rglob('*')) if path.is_file()}
symbols = subprocess.check_output(['nm', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True)
if ('LightingAcceptanceWindow' in symbols) != lighting_acceptance:
    raise SystemExit('App lighting acceptance compilation differs from requested package type')
if 'applyDefaultCandidate' in symbols:
    raise SystemExit('Default research USB entry must remain disabled in preview packages')
manifest = {'format': 'CherryMacNativeLightingAcceptance' if lighting_acceptance else 'CherryMacNativeMacroPreview', 'version': version,
            'build': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
            'sourceCommit': commit, 'hardwareAcceptance': 'pending', 'signing': 'ad-hoc', 'architectures': architectures,
            'minimumMacOS': info.get('LSMinimumSystemVersion', '13.0'),
            'compileFlags': ['CHERRY_MACRO_PRODUCT'],
            'features': {'defaultTemplateImport': True, 'defaultRestoreOfflineReview': True, 'defaultRecoveryOfflineReview': True, 'defaultTransactionStorage': True, 'defaultResetWrite': False, 'defaultResearchEntryEnabled': False, 'defaultMacroSemanticsComplete': False, 'macros': True, 'officialMacroStorage': True, 'macroDraftIdentityStorage': True, 'macroRecoveryMetadata': True, 'macroEventLimit': 762, 'macroAcceptance': 'pending', 'hostText': True, 'webTextBridge': True, 'mixedOfficialImportExport': True, 'portableTextDraft': True, 'lightingDraftExport': True, 'lightingOnlyImport': True, 'lightingFlagDraftSync': True, 'mediaActionPicker': True, 'macApplicationShortcutPresets': True, 'macApplicationShortcutInstallation': True, 'macApplicationShortcutFailureRollback': True, 'lightingMainAction': True, 'lightingEditorReturn': lighting_acceptance, 'lightingMappingRead': True, 'lightingWrite': False, 'lightingOfflineReview': True, 'lightingRecoveryRecords': True, 'lightingRestorePreparation': True, 'deviceSettingsPage': True, 'readDraftReplacementConfirmation': True, 'officialPollingDraft': True}, 'files': files}
if lighting_acceptance:
    manifest['features']['lightingResearchAcceptance'] = True
    manifest['features']['lightingResearchWrite'] = True
    manifest['features']['lightingEditorPlanHandoff'] = True
    manifest['features']['lightingOperationDiagnostics'] = True
    manifest['compileFlags'] = ['CHERRY_MACRO_PRODUCT', 'CHERRY_LIGHTING_TEST']
manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
readme = '''# CherryMac 宏与文本预览

设备设置与诊断使用独立菜单。回报率目前只保存到官方配置文件；Mac 端适配入口也在设备设置中。读取前若编辑区有资料会先提示保存；请先导出需要保留的草稿。快捷操作安装失败时会尝试恢复本次修改，无法恢复的项目会明确提示。

在“配置与备份”可选择官方 DefaultData0～4.json 载入默认草稿，或核对并导出默认恢复计划。也可选择之前的计划／事务记录，核对并导出原始数据撤回计划。需要先读取完整配置和默认键位／LED 映射；文件核对不写入键盘。计划包含原始配置与宏，请保留原文件。完整恢复默认尚未开放，设备设置与宏存储默认语义仍在分析。

适用于 Apple Silicon Mac，macOS 13 或更新版本。此包用于宏与文本模块统一验收，尚未通过完整成品验收，也尚未经过 Apple 公证。

解压后将 CherryMacMacroPreview.app 放入应用程序，退出其他 CherryMac 再打开。本次打包不会打开 App、申请权限或连接键盘；请等统一验收安排后再进行写入。

使用 USB 数据线连接键盘并切换有线模式，先读取配置，再进入“宏”。可以录制、点选编辑步骤、排序、复制、改名、删除、清空、分配和单独解除绑定。录制片段可替换、追加或插入指定步骤前后。默认只录制窗口内区域；可勾选其他应用录制，需要辅助功能权限，只有点击开始后才监听，停止或取消后移除。操作仍会在原应用正常执行。支持键盘及五个鼠标按钮，滚轮尚未支持。启用鼠标录制时遇到滚轮会取消本次录制，保留原步骤。

宏页显示存储占用及设定等待总量。保存宏保留原按键各自的执行方式；“分配到所选键”才应用当前方式。解除绑定把所选键设为禁用，宏库保留。这些操作只改编辑区，点击写入后才改变键盘。

宏写入只更新宏库与宏绑定，普通键和灯效草稿保留。写入前自动保存完整备份和操作记录，写后完整读回。持续执行的宏需按提示先停止；所需输入监控权限按界面处理。取消发送不会停止键盘内部正在执行的宏。遇到错误可使用“配置与备份”中的宏恢复入口，断线后需重新连接。

“文本”页面可以选择本型号官方 JSON，编辑文字、分配到按键、安装和解除绑定。文本内容保存在 Mac，键盘保存触发键；输入需要 CherryMac 持续运行及辅助功能权限。选择或编辑不会写入，安装前显示变更，写后完整读回。已保存配置和恢复记录可导出；恢复记录可在新版 Mac／网页两端导入，已有不同记录不会被覆盖。

网页联动默认关闭。在文本页点击“网页联动”，开启并复制临时联动码，粘贴到网页文本页并连接。网页启用服务会把已安装定义交给 Mac，无需手动搬文件；配置操作和宏录制前等待服务释放 USB。关闭客户端配置窗口或关闭联动会停用文本服务。联动码仅本次运行有效。文本实体触发、实际输入及两端新流程仍待统一验收。

“配置与备份”可导入同时包含键位、宏和文本的 Windows 官方 JSON：键位和宏进入编辑区，文本定义进入文本页；文本键保留当前键盘功能，需要单独安装。“导出 Windows 配置草稿”会合并宏编辑和文本页当前定义，保留共享引用与附加字段。同一键若同时有普通键位修改和文本绑定，会提示先解除冲突；导入、导出都不会自动写入。

Windows 配置草稿导出会合并当前支持的灯效模式、亮度、速度、方向、全局颜色和逐键配色；需先导入官方模板；逐键配色需要原始 RGB 和实际 LED 映射；官方模板缺少颜色表时可补齐，已有表的隐藏颜色与未知字段保留。内置模式允许没有逐键表。隐藏颜色和未核对字段保留原值，设备设置继续沿用模板。导出文件不会向键盘写入。点击读取时会另外核对默认键位和 LED 索引；取得的映射随普通配置和读取备份保存，用于预览与配色。映射读取失败时保留按键、宏读取结果并显示原因。普通 CherryMac 配置导出已包含文本页选中的草稿，可在两端离线导入；安装版本与恢复记录仍需在文本页另行导出。导入只载入草稿，不写键盘、不覆盖安装记录、不启用输入服务。旧配置不含文本时会清空选中的文本草稿，已保存安装记录保留。

“配置与备份”中的“检查灯效恢复记录”可检查原始写入或恢复操作记录，显示读回、失败与缺失信息，并导出分析。此入口仅处理文件，不连接或写入键盘。检查灯效恢复记录后，可以导出原始数据恢复计划。只接受记录中完整、可识别的读回状态；缺失读回或范围外变化会被拒绝。恢复计划只保存文件，尚未执行，实际恢复前仍需要重新读取键盘。

官方方式按每个绑定分别占用宏区，单个宏最多 762 个事件，总容量 3071 字节；同一宏绑定多个键会重复占用，未绑定宏仅保存本地。旧配置可在宏页点击“启用扩展宏编辑”，先转换草稿再核对写入。新存储范围仍待统一真机验收。

宏恢复记录同时保存可与写前硬件数据匹配的名称资料，恢复后再次核对；旧记录或资料缺失时仍可恢复原始硬件配置。

宏名称、录制偏好与官方模板保存在本机，读取时仅沿用与实际宏库相符的资料。建议导出 JSON 保存。灯效页的“核对灯效写入”仅生成本地计划，不写入键盘。自定义配色核对和 Windows 草稿导出需要明确的官方原始 RGB；直接读回或来源未知的颜色不能直接转为原始配色。内置灯效遇到读回颜色时保留官方模板里的逐键配色。

灯效及设备参数写入尚未开放。本包不包含官方软件、用户配置或真机日志。
'''.encode()
readme += '\n读取实际 LED 映射后，在逐键配色页点击“新建逐键配色”，可从全熄灭开始编辑原始 RGB，无需先导入 Windows 文件。内置灯效读取后也可直接准备计划。草稿可导出 CherryMac JSON；导出 Windows 格式需要本型号的官方根模板。\n\n“保存本机配色”只保存与最近读回匹配的原始 RGB、灯效参数和实际映射。未写入的草稿请导出 JSON；此按钮不发送 USB 报告，不代表固件已保存。普通版灯效发送仍关闭。\n'.encode()
if lighting_acceptance:
    readme = '''# CherryMac 灯效独立验收版

适用于 Apple Silicon、macOS 13 及更新版本，使用临时签名，尚未 Apple 公证。此包用于统一灯效实机验收，尚未验证灯光外观与断电保存，不是完整成品。

解压得到 CherryMacLightingAcceptance.app，退出其他 CherryMac 和键盘配置程序后打开。本次打包不打开 App、不申请权限、不访问键盘；请按统一验收安排使用。它使用独立名称和标识，不替换已安装的宏预览 App。

在主配置窗口读取键盘，导入本型号 Windows 官方 JSON，编辑并保存灯效，再点击“独立灯效验收”，自动载入当前编辑区的核对计划，无需先导出文件。也可保留“核对灯效写入”文件流程。自定义配色需要官方原始 RGB 和读取到的 LED 映射；内置模式允许没有逐键表。

独立验收窗口按顺序读取 USB、核对并确认写入。没有读取基线或编辑区计划无效时，也可载入此前导出的计划或恢复记录。打开窗口与载入文件不连接设备；读取按钮才打开接口，可能需要输入监控权限。写入前自动保存完整备份和逐包日志，失败中止，可停止后续发送；已发送报告不能撤回。当前只允许已核对固件、配置 0 和完整开始／结束布局。测试期间主配置窗口暂停其他操作，Mac 文本服务停止，保持验收窗口前台并松开全部按键。

写入读回通过后观察灯光，拔 USB、关闭键盘电源并点击关电确认；至少等待 15 秒后开电、接 USB，重新读取并核对。记录包含操作系统拔插事件和用户关电确认，不能证明电池实际断电或灯光外观正确。

最后点击恢复原始数据并核对键盘功能。恢复先重新读取并检查范围，拒绝未知变化；原始颜色不会再次缩放，不自动重试。超时或断开后可在新会话载入保存的独立恢复记录再核对，恢复中断保留原计划。关闭验收窗口后主页面需要重新读取配置。

操作日志包含开始、完成／取消／失败、错误和打开的 USB 标识，并关联独立恢复记录文件。准备阶段失败也会保存原因；日志保存失败不能作为操作通过。

“打开本轮资料”显示完整备份、读取快照、操作日志、power-events.json 和独立恢复记录，无需手工抓包。记录可在网页端导入核对，文件不上传。不含官方 EXE、用户配置或既有真机日志。普通配置页仍不提供灯效写入，只有独立研究窗口提供实际发送入口。
'''.encode()
readme += '\n灯效页可使用“仅导入官方灯效”，单独载入本型号官方 JSON 的灯效和原始配色，保留已有键位、宏、文本及设备设置草稿。此前没有模板时，不载入该文件的设备设置。LightOpenFlag 已在导入、草稿和导出之间同步；尚未确定其物理开关含义，没有新增开／关控件。此版本只编译与打包，未运行测试或访问键盘。\n'.encode()
readme += '\n按键页增加官方默认可见的 11 项多媒体功能，以及计算器、Finder、邮件、音乐启动组合键。点击“安装并设置 Mac 启动”才会安装系统快捷操作并保存键位草稿，仍需单独确认写入；安装与实体触发尚待验收。\n'.encode()
readme += ('\n灯效主按钮在研究版进入独立备份、写入、读回与恢复流程，关闭时接回与原计划匹配的有效结果，保留所有未发送草稿及原始 RGB。拔线、取消或计划不符时须重新读取；USB 标识仅核对当前会话，不能证明断电后物理身份。\n' if lighting_acceptance else '\n灯效主按钮仅核对并导出计划，不发送灯效；已移除主入口对旧灯效发送方法的调用。\n').encode()

with tempfile.TemporaryDirectory(prefix='.native-preview-', dir=output_dir) as temp:
    package = pathlib.Path(temp) / prefix
    package.mkdir()
    subprocess.run(['ditto', str(app), str(package / app.name)], check=True)
    (package / 'README.md').write_bytes(readme)
    (package / 'manifest.json').write_bytes(manifest_data)
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(package), str(output)], check=True)
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Preview archive is corrupt')
    for name, digest in files.items():
        if hashlib.sha256(archive.read(f'{prefix}/{app.name}/{name}')).hexdigest() != digest:
            raise SystemExit('Packaged app differs from signed app')
    if archive.read(prefix + '/manifest.json') != manifest_data:
        raise SystemExit('Packaged manifest differs')
manifest_file.write_bytes(manifest_data)
digest = hashlib.sha256(output.read_bytes()).hexdigest()
checksum_file.write_text(f'{digest}  {output.name}\n')
print(f'{digest}  {output} (not launched)')
