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
version = '0.7.0'
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
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
contents = {}
for path in files:
    text = path.read_text().replace('?v=' + source_version, '?v=' + version)
    text = text.replace('CherryMac Web ' + source_version, 'CherryMac Web ' + version + ' · 宏预览')
    text = text.replace("webVersion:'" + source_version + "'", "webVersion:'" + version + "'")
    contents[path.relative_to(root).as_posix()] = text.encode()
contents['start.command'] = '''#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
command -v php >/dev/null || { print '请先安装 PHP，再运行此脚本。'; exit 1; }
print 'CherryMac 宏预览：http://localhost:8770/'
print '请用 Chrome 或 Edge 打开；按 Control+C 停止本机服务。'
exec env CHERRY_MACRO_PRODUCT=1 php -S 127.0.0.1:8770 -t .
'''.encode()
contents['README.md'] = '''# CherryMac 网页宏预览

这是宏模块统一验收用的预览包，还未通过完整成品验收。不会自动连接或修改键盘。

电脑已有 PHP 时，解压后双击 `start.command`，用 Chrome 或 Edge 打开 http://localhost:8770/ 。无需 Node、安装依赖或构建。Linux／Windows 可在解压目录设置环境变量 `CHERRY_MACRO_PRODUCT=1` 后运行 `php -S 127.0.0.1:8770 -t .`。

按键、灯效、宏、配置与备份分成不同页面。宏支持录制、步骤编辑、复制、删除、清空，以及单次／指定次数、按住持续、再次按键停止。连接与读取不会自动写入。宏页写入只更新宏库与宏绑定键；普通键和灯效草稿保留，可分别处理。灯效与设备设置写入仍未开放。

写入之前会保存完整备份和恢复记录，完成后完整读回核对。连续运行的宏需要按界面提示先停止。操作期间可点击“停止发送”；这会停止后续配置写包，不能代替停止键盘正在执行的宏。遇到断开或取消后，在“配置与备份”使用“恢复最近宏写入前配置”。

宏名称和录制偏好保存在当前浏览器的本地数据库；读取时只沿用与实际宏库和绑定相符的资料。建议导出配置、下载备份。清理网站数据或更换浏览器／网址会失去本地资料。“设备与诊断”可导出日志，文件不会上传。

本包不含研究测试页面，也没有启动真机测试。请等统一验收安排后再进行写入测试。
'''.encode()
manifest = {'format': 'CherryMacWebMacroPreview', 'version': version, 'sourceCommit': commit,
            'sourceVersion': source_version, 'hardwareAcceptance': 'pending',
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
