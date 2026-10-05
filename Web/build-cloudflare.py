#!/usr/bin/env python3
"""Render the PHP product page and allowlisted assets for Workers hosting."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from package_runtime import runtime_files, preview_versions

root = Path(__file__).resolve().parent
out = root / 'cloudflare-dist'
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'Web'], cwd=root.parent, check=True)
version = preview_versions(root)['product']
match = re.search(r'CherryMac Web (\d+\.\d+\.\d+)', (root / 'index.php').read_text())
if not match:
    raise SystemExit('Cannot determine source version')
source = match.group(1)
files = runtime_files(root, source)
for path in files + [root / 'preview-versions.json', root / 'build-cloudflare.py', root / 'package_runtime.py']:
    subprocess.run(['git', 'ls-files', '--error-unmatch', str(path.relative_to(root.parent))],
                   cwd=root.parent, check=True, stdout=subprocess.DEVNULL)
environment = dict(os.environ, CHERRY_MACRO_PRODUCT='1', CHERRY_TEXT_PRODUCT='1',
                   CHERRY_LIGHTING_TEST='0', CHERRY_MACRO_TEST='0')
page = subprocess.check_output(['php', str(root / 'index.php')], env=environment, text=True)
if '<?php' in page or '<?=' in page or 'open-lighting-acceptance' in page:
    raise SystemExit('Unexpected PHP or research entry in rendered product page')
if out.exists():
    if out.is_symlink():
        raise SystemExit('Refusing a symlink output directory')
    shutil.rmtree(out)
(out / 'assets').mkdir(parents=True)
page = page.replace('?v=' + source, '?v=' + version)
page = page.replace('CherryMac Web ' + source, 'CherryMac Web ' + version + ' · 在线开发预览')
page = page.replace('<p id="compatibility"', '<p class="notice">在线开发预览，尚待统一真机验收。备份保存在当前浏览器与当前网址；与本地网页分别保存。跨应用文本输入仍需 Mac 客户端联动。</p><p id="compatibility"', 1)
(out / 'index.html').write_text(page)
for path in files:
    if path.parent.name != 'assets':
        continue
    text = path.read_text().replace('?v=' + source, '?v=' + version)
    text = text.replace("webVersion:'" + source + "'", "webVersion:'" + version + "'")
    (out / 'assets' / path.name).write_text(text)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
manifest = {'format': 'CherryMacOnlineRelease', 'version': version, 'sourceCommit': commit,
            'hardwareAcceptance': 'pending',
            'features': {'macroProduct': True, 'textProduct': True,
                         'lightingWrite': False, 'defaultResetWrite': False},
            'files': {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(out.rglob('*')) if p.is_file()}}
(out / 'release.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(f'Prepared online preview {version} from {commit}: {out}')
