#!/usr/bin/env python3
"""Build a local, no-Node macro acceptance ZIP without starting a server."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import zipfile
from package_runtime import runtime_files

root = pathlib.Path(__file__).resolve().parent
if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 Web/package-macro-preview.py OUTPUT_DIRECTORY')
output_dir = pathlib.Path(sys.argv[1]).resolve()
version = '0.15.0'
source_version_match = re.search(r'CherryMac Web (\d+\.\d+\.\d+)', (root / 'index.php').read_text())
if not source_version_match:
    raise SystemExit('Cannot determine source version')
source_version = source_version_match.group(1)
try:
    files = runtime_files(root, source_version)
except ValueError as error:
    raise SystemExit(str(error))
output_dir.mkdir(parents=True, exist_ok=True)
output = output_dir / f'CherryMac-Web-MacroPreview-{version}.zip'
checksum_file = output.with_suffix('.zip.sha256')
if output.exists() or checksum_file.exists():
    raise SystemExit('Refusing to overwrite an existing preview artifact')
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'Web'], cwd=root.parent, check=True)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
contents = {}
for path in files:
    text = path.read_text().replace('?v=' + source_version, '?v=' + version)
    text = text.replace('CherryMac Web ' + source_version, 'CherryMac Web ' + version + ' · 宏与文本预览')
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

这是宏与文本模块统一验收用的预览包，还未通过完整成品验收。不会自动连接或修改键盘。

电脑已有 PHP 时，解压后双击 `start.command`，用 Chrome 或 Edge 打开 http://localhost:8770/ 。无需 Node、安装依赖或构建。Linux／Windows 可在解压目录设置环境变量 `CHERRY_MACRO_PRODUCT=1` 与 `CHERRY_TEXT_PRODUCT=1` 后运行 `php -S 127.0.0.1:8770 -t .`。

按键、灯效、宏、配置与备份、设备与诊断、文本分成不同页面。宏支持录制片段替换／追加／插入、步骤编辑与排序、复制、删除、清空、单独解绑，以及单次／指定次数、按住持续、再次按键停止。编辑时显示宏容量和设定等待总量；等待总量不是实际固件执行时间。保存宏不会改动已有按键的执行方式；选择执行方式后点击“分配到所选键”才更改对应绑定。解除绑定会把所选键设为禁用，宏库保留，仍需写入。滚轮尚未支持；启用鼠标录制时遇到滚轮会取消本次录制，保留原步骤。连接与读取不会自动写入。宏页写入只更新宏库与宏绑定键；普通键和灯效草稿保留，可分别处理。灯效与设备设置写入仍未开放。

写入之前会保存完整备份和恢复记录，完成后完整读回核对。连续运行的宏需要按界面提示先停止。操作期间可点击“停止发送”；这会停止后续配置写包，不能代替停止键盘正在执行的宏。遇到断开或取消后，在“配置与备份”使用“恢复最近宏写入前配置”。

文本页可选择本型号官方 JSON，编辑按键绑定、多行文本、安装及解除绑定。文本定义与完整恢复记录保存在当前网站的本地数据库；安装前显示变更，写后完整读回。可导出定义与恢复记录，后者支持新版 Mac／网页互相导入，已有不同记录不覆盖。

跨应用文本输入需要同版本 Mac 预览 App。在客户端文本页点击“网页联动”，开启并复制联动码，在网页粘贴后连接。安装并保存相同定义后，点击“启用 Mac 文本服务”；网页先释放 USB，再提交定义。客户端需要辅助功能权限及开启的配置窗口。网页配置操作和宏录制前先等待 Mac 停止服务；联系失败时不开始操作。刷新后先核对旧联动状态，关闭网页请求解除；失联超过两分钟，客户端停止网页启动的文本服务。网页不能独立向其他应用输入文本。此流程尚待统一真机验收。

“配置与备份”可导入同时包含键位、宏和文本的 Windows 官方 JSON：键位和宏进入编辑区，文本定义进入文本页；文本键保留当前键盘功能，需要单独安装。“导出 Windows 配置草稿”会合并宏编辑和文本页当前定义，保留共享引用与附加字段。同一键若同时有普通键位修改和文本绑定，会提示先解除冲突；导入、导出都不会自动写入。

Windows 配置草稿导出会合并当前支持的灯效模式、亮度、速度、方向、全局颜色和逐键配色；需先导入包含完整颜色表的官方模板。隐藏颜色和未核对字段保留原值，设备设置继续沿用模板。导出文件不会向键盘写入。点击读取时会另外核对默认键位和 LED 索引；取得的映射随普通配置和读取备份保存，用于预览与配色。映射读取失败时保留按键、宏读取结果并显示原因。普通 CherryMac 配置导出已包含文本页选中的草稿，可在两端离线导入；安装版本与恢复记录仍需在文本页另行导出。导入只载入草稿，不写键盘、不覆盖安装记录、不启用输入服务。旧配置不含文本时会清空选中的文本草稿，已保存安装记录保留。

宏名称和录制偏好保存在当前浏览器的本地数据库；读取时只沿用与实际宏库和绑定相符的资料。建议导出配置、下载备份。清理网站数据或更换浏览器／网址会失去本地资料。“设备与诊断”可导出日志，文件不会上传。

本包不含研究测试页面，也没有启动真机测试。请等统一验收安排后再进行写入测试。
'''.encode()
manifest = {'format': 'CherryMacWebMacroPreview', 'version': version, 'sourceCommit': commit,
            'sourceVersion': source_version, 'hardwareAcceptance': 'pending',
            'features': {'macros': True, 'hostText': True, 'webTextBridge': True, 'mixedOfficialImportExport': True, 'portableTextDraft': True, 'lightingDraftExport': True, 'lightingMappingRead': True, 'lightingWrite': False, 'lightingOfflineReview': True},
            'files': {name: hashlib.sha256(data).hexdigest() for name, data in sorted(contents.items())}}
contents['manifest.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
prefix = f'CherryMac-Web-MacroPreview-{version}/'
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
