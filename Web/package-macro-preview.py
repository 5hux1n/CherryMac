#!/usr/bin/env python3
"""Build a local, no-Node macro acceptance ZIP without starting a server."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import zipfile
from package_runtime import runtime_files, preview_versions

root = pathlib.Path(__file__).resolve().parent
if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != '--lighting-acceptance'):
    raise SystemExit('Usage: python3 Web/package-macro-preview.py OUTPUT_DIRECTORY [--lighting-acceptance]')
lighting_acceptance = len(sys.argv) == 3
output_dir = pathlib.Path(sys.argv[1]).resolve()
version = preview_versions(root)['lightingAcceptance' if lighting_acceptance else 'product']
package_name = 'CherryMac-Web-LightingAcceptance' if lighting_acceptance else 'CherryMac-Web-MacroPreview'
source_version_match = re.search(r'CherryMac Web (\d+\.\d+\.\d+)', (root / 'index.php').read_text())
if not source_version_match:
    raise SystemExit('Cannot determine source version')
source_version = source_version_match.group(1)
try:
    files = runtime_files(root, source_version, lighting_acceptance=lighting_acceptance)
except ValueError as error:
    raise SystemExit(str(error))
output_dir.mkdir(parents=True, exist_ok=True)
output = output_dir / f'{package_name}-{version}.zip'
checksum_file = output.with_suffix('.zip.sha256')
if output.exists() or checksum_file.exists():
    raise SystemExit('Refusing to overwrite an existing preview artifact')
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'Web'], cwd=root.parent, check=True)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
contents = {}
for path in files:
    text = path.read_text().replace('?v=' + source_version, '?v=' + version)
    text = text.replace('CherryMac Web ' + source_version, 'CherryMac Web ' + version + (' · 灯效独立验收版' if lighting_acceptance else ' · 宏与文本预览'))
    text = text.replace("webVersion:'" + source_version + "'", "webVersion:'" + version + "'")
    contents[path.relative_to(root).as_posix()] = text.encode()
contents['start.command'] = '''#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
command -v php >/dev/null || { print '请先安装 PHP，再运行此脚本。'; exit 1; }
print 'CherryMac 宏与文本预览：http://localhost:8770/'
print '请用 Chrome 或 Edge 打开；按 Control+C 停止本机服务。'
exec env CHERRY_MACRO_PRODUCT=1 CHERRY_TEXT_PRODUCT=1 php -S 127.0.0.1:8770 -t .
'''.encode()
contents['README.md'] = '''# CherryMac 网页宏与文本预览

独立宏文件：Mac 在“宏草稿选项…”选择导入／导出，网页展开“独立宏文件”。.mac 只保存步骤，导入会确认替换当前步骤编辑区，随后需要点击保存宏；名称、执行方式和绑定保留，不自动写入。支持键盘、修饰键、五鼠标按钮、手动 X／Y 位移及空事件 null／[]；按当前格式限制为 256 或 762 个事件，文件上限 3 MB。带未知附加事件字段的独立文件会明确拒绝；请保留原文件并使用完整官方配置导入，避免丢失来源。由完整配置导出的 .mac 会保留可对应的附加字段，因此这类文件也受上述独立导入限制。

保存宏以及宏库复制、删除、清空、分配、解绑和扩展格式转换，会保存一份最新的本机编辑草稿；未点击保存的步骤输入不会自动保存。Mac 在“宏草稿选项…”中载入，网页点击“载入上次宏草稿”。载入前会提示替换完整编辑区，包括保存时的键位、灯效和文本定义；不会自动写入键盘。草稿与硬件读回名称资料分别保存，读取键盘不会自动采用旧草稿。本机草稿只保留最新一份，重要版本请导出 JSON；清除浏览器网站数据会删除网页草稿。保存失败会明确提示。

逐键配色页可直接设置配色全局亮度，立即保存到编辑草稿；原始 RGB 保留，实际写入计划只处理一次全局亮度。亮度为 0 时明确提示全部熄灭。读回颜色可能已经缩放，不能唯一反推原始 RGB；未取得原始配色和 LED 映射时，应用颜色／熄灭／配色亮度入口会提示先新建逐键配色或导入官方配色。颜色查看仍可使用。该调整不改变键位、宏、文本或设备设置，也不自动写入。

设备设置与诊断使用独立菜单。回报率目前只保存到官方配置文件。读取前若编辑区有资料会先提示保存；请先导出需要保留的草稿。

在“配置与备份”可选择官方 DefaultData0～4.json 载入默认草稿，或核对并导出默认恢复计划。也可选择之前的计划／事务记录，核对并导出原始数据撤回计划。需要先读取完整配置和默认键位／LED 映射；文件核对不写入键盘。计划包含原始配置与宏，请保留原文件。完整恢复默认尚未开放，设备设置与宏存储默认语义仍在分析。

这是宏与文本模块统一验收用的预览包，还未通过完整成品验收。不会自动连接或修改键盘。

电脑已有 PHP 时，解压后双击 `start.command`，用 Chrome 或 Edge 打开 http://localhost:8770/ 。无需 Node、安装依赖或构建。Linux／Windows 可在解压目录设置环境变量 `CHERRY_MACRO_PRODUCT=1` 与 `CHERRY_TEXT_PRODUCT=1` 后运行 `php -S 127.0.0.1:8770 -t .`。

按键、灯效、宏、配置与备份、设备与诊断、文本分成不同页面。宏支持录制片段替换／追加／插入、步骤编辑与排序、复制、删除、清空、单独解绑，以及单次／指定次数、按住持续、再次按键停止。编辑时显示宏容量和设定等待总量；等待总量不是实际固件执行时间。保存宏不会改动已有按键的执行方式；选择执行方式后点击“分配到所选键”才更改对应绑定。解绑、删除或清空宏库时，可选择让关联键恢复默认功能或禁用；单独解绑保留宏库，仍需写入。恢复默认需要完整默认表，写入前须与最近读取一致。X／Y 位移可手动编辑 -256…255 的有符号设备单位，不是屏幕像素，不自动录制；位移输出仍待统一实机验收。滚轮尚未支持；启用鼠标录制时遇到滚轮会取消本次录制，保留原步骤。连接与读取不会自动写入。宏页写入只更新宏库与宏绑定键；普通键和灯效草稿保留，可分别处理。灯效与设备设置写入仍未开放。

官方方式按每个绑定分别占用宏区，单个宏最多 762 个事件，总容量 3071 字节；同一宏绑定多个键会重复占用，未绑定宏仅保存本地。旧配置可点击“启用扩展宏编辑”，先转换草稿再核对写入。新存储范围仍待统一真机验收。

宏恢复记录同时保存可与写前硬件数据匹配的名称资料，恢复后再次核对；旧记录或资料缺失时仍可恢复原始硬件配置。

写入之前会保存完整备份和恢复记录，完成后完整读回核对。连续运行的宏需要按界面提示先停止。操作期间可点击“停止发送”；这会停止后续配置写包，不能代替停止键盘正在执行的宏。遇到断开或取消后，在“配置与备份”使用“恢复最近宏写入前配置”。

文本页可选择本型号官方 JSON，编辑按键绑定、多行文本、安装及解除绑定。文本定义与完整恢复记录保存在当前网站的本地数据库；安装前显示变更，写后完整读回。可导出定义与恢复记录，后者支持新版 Mac／网页互相导入，已有不同记录不覆盖。

跨应用文本输入需要配套 Mac 预览 App（此次 Mac 0.75.0 / 网页 0.74.0）。在客户端文本页点击“网页联动”，开启并复制联动码，在网页粘贴后连接。安装并保存相同定义后，点击“启用 Mac 文本服务”；网页先释放 USB，再提交定义。客户端需要辅助功能权限及开启的配置窗口。网页配置操作和宏录制前先等待 Mac 停止服务；联系失败时不开始操作。刷新后先核对旧联动状态，关闭网页请求解除；失联超过两分钟，客户端停止网页启动的文本服务。网页不能独立向其他应用输入文本。此流程尚待统一真机验收。

“配置与备份”可导入同时包含键位、宏和文本的 Windows 官方 JSON：键位和宏进入编辑区，文本定义进入文本页；文本键保留当前键盘功能，需要单独安装。“导出 Windows 配置草稿”会合并宏编辑和文本页当前定义，保留共享引用与附加字段。同一键若同时有普通键位修改和文本绑定，会提示先解除冲突；导入、导出都不会自动写入。

Windows 配置草稿导出会合并当前支持的灯效模式、亮度、速度、方向、全局颜色和逐键配色；需先导入官方模板；逐键配色需要原始 RGB 和实际 LED 映射；官方模板缺少颜色表时可补齐，已有表的隐藏颜色与未知字段保留。内置模式允许没有逐键表。隐藏颜色和未核对字段保留原值，设备设置继续沿用模板。导出文件不会向键盘写入。点击读取时会另外核对默认键位和 LED 索引；取得的映射随普通配置和读取备份保存，用于预览与配色。映射读取失败时保留按键、宏读取结果并显示原因。普通 CherryMac 配置导出已包含文本页选中的草稿，可在两端离线导入；安装版本与恢复记录仍需在文本页另行导出。导入只载入草稿，不写键盘、不覆盖安装记录、不启用输入服务。旧配置不含文本时会清空选中的文本草稿，已保存安装记录保留。

宏名称和录制偏好保存在当前浏览器的本地数据库；读取时只沿用与实际宏库和绑定相符的资料。建议导出配置、下载备份。清理网站数据或更换浏览器／网址会失去本地资料。“设备与诊断”可导出日志，文件不会上传。切换 USB 会话或启动 Mac 文本服务前，网页会等待浏览器真正关闭设备；关闭失败时停止交接，需要关闭旧页并重新连接。

本包不含研究测试页面，也没有启动真机测试。请等统一验收安排后再进行写入测试。

灯效页的“核对灯效写入”仅生成本地计划，不写入键盘。自定义配色核对和 Windows 草稿导出需要明确的官方原始 RGB；直接读回或来源未知的颜色不能直接转为原始配色。内置灯效遇到读回颜色时保留官方模板里的逐键配色。

在“设备与诊断”可编辑官方 USB 回报率草稿，支持 125、250、500、1000 Hz。先导入包含设备设置的 Windows 官方 JSON，保存草稿后在“配置与备份”导出。这里只更新文件，尚未写入键盘；无线回报率和其他设备设置沿用模板。

检查灯效恢复记录后，可以导出原始数据恢复计划。只接受记录中完整、可识别的读回状态；缺失读回或范围外变化会被拒绝。恢复计划只保存文件，尚未执行，实际恢复前仍需要重新读取键盘。
'''.encode()
contents['README.md'] += '\n读取实际 LED 映射后，在逐键配色页点击“新建逐键配色”，可从全熄灭开始编辑原始 RGB，无需先导入 Windows 文件。内置灯效读取后也可直接准备计划。草稿可导出 CherryMac JSON；导出 Windows 格式需要本型号的官方根模板。\n\n“保存本机配色”只保存与最近读回匹配的原始 RGB、灯效参数和实际映射。未写入的草稿请导出 JSON；此按钮不发送 USB 报告，不代表固件已保存。普通版灯效发送仍关闭。\n'.encode()
if lighting_acceptance:
    contents['start.command'] = contents['start.command'].replace(b'localhost:8770/', b'localhost:8771/lighting-test.php').replace(b'127.0.0.1:8770', b'127.0.0.1:8771').replace(b'CHERRY_MACRO_PRODUCT=1', b'CHERRY_LIGHTING_TEST=1 CHERRY_MACRO_PRODUCT=1')
    contents['README.md'] = '''# CherryMac 灯效独立验收版

这是准备统一真机验收的独立研究包，尚未完成验收。不会自动连接或写入键盘；普通配置页仍不提供灯效写入。

已有 PHP 时，解压后双击 start.command，用 Chrome 或 Edge 打开 http://localhost:8771/lighting-test.php 。无需 Node 或构建；启动脚本不会打开浏览器。手动运行时设置 CHERRY_LIGHTING_TEST=1、CHERRY_MACRO_PRODUCT=1、CHERRY_TEXT_PRODUCT=1，再启动 PHP 本机服务。退出其他配置程序及 Mac 文本服务。

先在 http://localhost:8771/ 读取配置、导入本型号官方 JSON、编辑并保存灯效，再点击“使用编辑区计划开始独立验收”。新标签页直接载入计划，原页面停止文本服务、关闭 USB 并保留编辑区，无需导出再导入。浏览器需允许新页面；交接计划只能取用一次，10 分钟后失效。也可保留“核对并导出计划”的文件流程。自定义配色需要官方原始 RGB 和读取到的 LED 映射；内置模式无需逐键表。

独立验收页按顺序载入计划、选择 USB、核对并确认写入。写前自动保存完整备份，每包保存日志，失败中止；可停止后续发送，已发送报告不能撤回。当前只允许已核对固件、配置 0 和完整开始／结束布局。连接、读取和载入文件不写入。

写入读回通过后观察灯光，拔 USB、关闭键盘电源并点击关电确认；至少 15 秒后开电、接 USB，重新选择键盘并核对读回。系统拔插记录和用户关电确认不能证明电池实际断电，灯光外观需要实际观察。

最后点击恢复原始数据并核对键盘功能。恢复会重新读取完整配置、拒绝范围外变化，原始颜色不重复缩放，不自动重试。超时或断开后用新会话载入独立恢复记录再核对。备份和记录存于当前网址的浏览器本地数据库，文件不上传；清理数据前分别下载本轮资料与独立恢复记录。日志保存失败时仍能下载现有资料，导出会标注日志缺失。

进入验收页前会等待原 USB 接口关闭，不能只凭旧会话失效就交接；关闭失败记录原因并停止，需关闭旧页重新连接。

本轮资料的 operations 包含每次操作开始、结束、完成／取消／失败及错误，首包前失败也能追踪。操作记录无法保存时，不开始下一项配置操作；已有资料仍可下载。

此包与旧灯效版本不同，名字和端口独立，不替换旧包。它包含实际发送入口，请按统一验收安排使用；打包过程没有运行网页服务、申请权限或访问键盘。
'''.encode()
contents['README.md'] += '\n灯效页可使用“仅导入官方灯效”，单独载入本型号官方 JSON 的灯效和原始配色，保留已有键位、宏、文本及设备设置草稿。此前没有模板时，不载入该文件的设备设置。LightOpenFlag 已在导入、草稿和导出之间同步；尚未确定其物理开关含义，没有新增开／关控件。此版本只编译与打包，未运行测试或访问键盘。\n'.encode()
contents['README.md'] += '\n按键页增加官方默认可见的 11 项多媒体功能，以及 Finder、邮件、音乐启动组合键。启动组合键需要先在 Mac 客户端手动安装对应系统快捷操作；网页不能安装 macOS 服务。安装与实体触发尚待验收。\n'.encode()
contents['README.md'] += ('\n独立灯效页成功写入或恢复后可“核对并返回原编辑器”：返回前再读回、关闭 USB，会按原计划核对完整记录。原编辑器保留全部草稿，重新连接要求读回一致。返回失败可重新读取后重试，不需重复写入。回传不证明外观、物理身份或断电保留。\n' if lighting_acceptance else '\n灯效主按钮仅核对并导出计划，不发送灯效；计划导出不停止文本服务或关闭 USB。\n').encode()

contents['README.md'] += '\n在“配置与备份”点击“检查默认配置操作记录”，可离线检查 CherryMac 默认配置事务 JSON，并导出原始备份和分析资料；无需连接键盘。记录有完整、可识别的读回时才能另行导出撤回计划。备份包含原始宏区，不补造宏名称；导入只载入草稿。记录读回不是当前键盘状态，也不能证明实体输出或断电保留；实际恢复仍需重新读取和核对。完整恢复默认写入尚未开放。\n'.encode()

contents['README.md'] += '\n内置灯效选项按本型号官方模式分别开放：不适用的速度、方向、单色／彩虹切换或内置单色会禁用，保存时保留这些参数原值。例如常亮不调速度，光谱不调单色；逐键颜色在逐键配色页设置。这是编辑选项对齐，灯效写入和外观仍待统一验收。\n'.encode()

manifest = {'format': 'CherryMacWebLightingAcceptance' if lighting_acceptance else 'CherryMacWebMacroPreview', 'version': version, 'sourceCommit': commit,
            'sourceVersion': source_version, 'hardwareAcceptance': 'pending',
            'features': {'defaultTemplateImport': True, 'defaultRestoreOfflineReview': True, 'defaultRecoveryOfflineReview': True, 'defaultTransactionStorage': True, 'defaultTransactionFileInspection': True, 'defaultResetWrite': False, 'defaultResearchEntryEnabled': False, 'defaultMacroSemanticsComplete': False, 'macros': True, 'officialMacroStorage': True, 'macroDraftIdentityStorage': True, 'macroRecoveryMetadata': True, 'macroEventLimit': 762, 'macroAcceptance': 'pending', 'hostText': True, 'webTextBridge': True, 'mixedOfficialImportExport': True, 'portableTextDraft': True, 'lightingDraftExport': True, 'lightingOnlyImport': True, 'lightingFlagDraftSync': True, 'mediaActionPicker': True, 'macApplicationShortcutPresets': True, 'macApplicationShortcutInstallation': False, 'lightingMainAction': True, 'lightingEditorReturn': lighting_acceptance, 'lightingMappingRead': True, 'lightingWrite': False, 'lightingOfflineReview': True, 'lightingModeOptions': True, 'lightingRecoveryRecords': True, 'lightingRestorePreparation': True, 'deviceSettingsPage': True, 'readDraftReplacementConfirmation': True, 'officialPollingDraft': True, 'awaitedUSBClose': True},
            'files': {name: hashlib.sha256(data).hexdigest() for name, data in sorted(contents.items())}}
contents['manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
if lighting_acceptance:
    manifest['features']['lightingResearchAcceptance'] = True
    manifest['features']['lightingResearchWrite'] = True
    manifest['features']['lightingEditorPlanHandoff'] = True
    manifest['features']['lightingOperationDiagnostics'] = True
    contents['manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
prefix = f'{package_name}-{version}/'
with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
    for name, data in sorted(contents.items()):
        info = zipfile.ZipInfo(prefix + name)
        info.create_system = 3
        info.external_attr = (0o100755 if name.endswith('.command') else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Preview archive is corrupt')
    for name, data in contents.items():
        if archive.read(prefix + name) != data:
            raise SystemExit('Preview archive content differs from source')
digest = hashlib.sha256(output.read_bytes()).hexdigest()
checksum_file.write_text(f'{digest}  {output.name}\n')
print(f'{digest}  {output} ({len(contents)} files; not started)')
