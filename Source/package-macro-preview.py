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

if len(sys.argv) != 2:
    raise SystemExit('Usage: python3 Source/package-macro-preview.py OUTPUT_DIRECTORY')
root = pathlib.Path(__file__).resolve().parent
output_dir = pathlib.Path(sys.argv[1]).resolve()
app = output_dir / 'CherryMacMacroPreview.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'local.cherrymac.macro-product-preview':
    raise SystemExit('Refusing to package a different app identity')
version = info['CFBundleShortVersionString']
prefix = f'CherryMac-MacroPreview-{version}'
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
manifest = {'format': 'CherryMacNativeMacroPreview', 'version': version,
            'build': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
            'sourceCommit': commit, 'hardwareAcceptance': 'pending', 'signing': 'ad-hoc', 'architectures': architectures,
            'minimumMacOS': info.get('LSMinimumSystemVersion', '13.0'),
            'features': {'macros': True, 'hostText': True, 'webTextBridge': True, 'mixedOfficialImportExport': True, 'lightingWrite': False}, 'files': files}
manifest_data = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
readme = '''# CherryMac 宏与文本预览

适用于 Apple Silicon Mac，macOS 13 或更新版本。此包用于宏与文本模块统一验收，尚未通过完整成品验收，也尚未经过 Apple 公证。

解压后将 CherryMacMacroPreview.app 放入应用程序，退出其他 CherryMac 再打开。本次打包不会打开 App、申请权限或连接键盘；请等统一验收安排后再进行写入。

使用 USB 数据线连接键盘并切换有线模式，先读取配置，再进入“宏”。可以录制、点选编辑步骤、排序、复制、改名、删除、清空、分配和单独解除绑定。录制片段可替换、追加或插入指定步骤前后。默认只录制窗口内区域；可勾选其他应用录制，需要辅助功能权限，只有点击开始后才监听，停止或取消后移除。操作仍会在原应用正常执行。支持键盘及五个鼠标按钮，滚轮尚未支持。启用鼠标录制时遇到滚轮会取消本次录制，保留原步骤。

宏页显示存储占用及设定等待总量。保存宏保留原按键各自的执行方式；“分配到所选键”才应用当前方式。解除绑定把所选键设为禁用，宏库保留。这些操作只改编辑区，点击写入后才改变键盘。

宏写入只更新宏库与宏绑定，普通键和灯效草稿保留。写入前自动保存完整备份和操作记录，写后完整读回。持续执行的宏需按提示先停止；所需输入监控权限按界面处理。取消发送不会停止键盘内部正在执行的宏。遇到错误可使用“配置与备份”中的宏恢复入口，断线后需重新连接。

“文本”页面可以选择本型号官方 JSON，编辑文字、分配到按键、安装和解除绑定。文本内容保存在 Mac，键盘保存触发键；输入需要 CherryMac 持续运行及辅助功能权限。选择或编辑不会写入，安装前显示变更，写后完整读回。已保存配置和恢复记录可导出；恢复记录可在新版 Mac／网页两端导入，已有不同记录不会被覆盖。

网页联动默认关闭。在文本页点击“网页联动”，开启并复制临时联动码，粘贴到网页文本页并连接。网页启用服务会把已安装定义交给 Mac，无需手动搬文件；配置操作和宏录制前等待服务释放 USB。关闭客户端配置窗口或关闭联动会停用文本服务。联动码仅本次运行有效。文本实体触发、实际输入及两端新流程仍待统一验收。

“配置与备份”可导入同时包含键位、宏和文本的 Windows 官方 JSON：键位和宏进入编辑区，文本定义进入文本页；文本键保留当前键盘功能，需要单独安装。“导出 Windows 键位、宏与文本”会合并宏编辑和文本页当前定义，保留共享引用与附加字段。同一键若同时有普通键位修改和文本绑定，会提示先解除冲突；导入、导出都不会自动写入。

灯效和设备设置在 Windows 导出中沿用最初导入模板。普通 CherryMac 配置导出不包含完整主机文本状态；请同时保存文本定义与恢复记录，或使用上述 Windows 合并导出保存编辑结果。

宏名称、录制偏好与官方模板保存在本机，读取时仅沿用与实际宏库相符的资料。建议导出 JSON 保存。灯效及设备参数写入尚未开放。本包不包含官方软件、用户配置或真机日志。
'''.encode()
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
