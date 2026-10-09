#!/usr/bin/env python3
"""Render the PHP product page and allowlisted assets for Workers hosting."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from package_runtime import runtime_files, preview_versions, RUNTIME_NAMES

root = Path(__file__).resolve().parent
out = root / 'cloudflare-dist'
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime-source-commit',help='Reuse a released runtime only when every packaged runtime file is unchanged')
args=parser.parse_args()
subprocess.run(['git', 'diff', '--quiet', 'HEAD', '--', 'Web'], cwd=root.parent, check=True)
site_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root.parent,text=True).strip()
runtime_commit=site_commit
if args.runtime_source_commit:
    if not re.fullmatch(r'[0-9a-f]{40}',args.runtime_source_commit):
        raise SystemExit('Runtime source must be a full lowercase commit SHA')
    runtime_commit=subprocess.check_output(['git','rev-parse','--verify',args.runtime_source_commit+'^{commit}'],cwd=root.parent,text=True).strip()
    subprocess.run(['git','diff','--quiet',runtime_commit,'--']+
                   ['Web/'+name for name in RUNTIME_NAMES]+
                   ['Web/preview-versions.json','Source/build-macro-product-preview.sh'],cwd=root.parent,check=True)
version = preview_versions(root)['product']
native_script=(root.parent/'Source/build-macro-product-preview.sh').read_text()
native_match=re.search(r'^TASK_PREVIEW_VERSION="(\d+\.\d+\.\d+)"$',native_script,re.M)
if not native_match:
    raise SystemExit('Cannot determine native preview version')
native_version=native_match.group(1)
match = re.search(r'CherryMac Web (\d+\.\d+\.\d+)', (root / 'index.php').read_text())
if not match:
    raise SystemExit('Cannot determine source version')
source = match.group(1)
files = runtime_files(root, source)
homepage_files = [root / 'homepage' / name for name in
                  ('index.html', 'site-assets/style.css', 'site-assets/keyboard.png')]
for path in files + homepage_files + [root / 'preview-versions.json', root / 'build-cloudflare.py', root / 'package_runtime.py']:
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
(out / 'app' / 'assets').mkdir(parents=True)
for path in homepage_files:
    target = out / path.relative_to(root / 'homepage')
    target.parent.mkdir(parents=True, exist_ok=True)
    if path.name=='index.html':
        homepage=path.read_text()
        for marker,value in [('__MAC_PREVIEW_VERSION__',native_version),('__WEB_PREVIEW_VERSION__',version)]:
            if homepage.count(marker)!=2:raise SystemExit('Homepage release placeholder count differs')
            homepage=homepage.replace(marker,value)
        target.write_text(homepage)
    else:target.write_bytes(path.read_bytes())
page = page.replace('?v=' + source, '?v=' + version)
page = page.replace('CherryMac Web ' + source, 'CherryMac Web ' + version + ' · 在线开发预览')
page = page.replace('<p id="compatibility"', '<p class="notice">在线开发预览，尚待统一真机验收。备份保存在当前浏览器与当前网址；与本地网页分别保存。跨应用文本输入仍需 Mac 客户端联动。</p><p id="compatibility"', 1)
(out / 'app' / 'index.html').write_text(page)
for path in files:
    if path.parent.name != 'assets':
        continue
    text = path.read_text().replace('?v=' + source, '?v=' + version)
    text = text.replace("webVersion:'" + source + "'", "webVersion:'" + version + "'")
    (out / 'app' / 'assets' / path.name).write_text(text)
commit = runtime_commit
manifest = {'format': 'CherryMacOnlineRelease', 'version': version, 'sourceCommit': commit,
            'siteSourceCommit':site_commit,'nativePreviewVersion':native_version,
            'hardwareAcceptance': 'pending',
            'features': {'macroProduct': True, 'officialMacroStorage': True,
                         'macroDraftIdentityStorage': True, 'macroRecoveryMetadata': True, 'macroEventLimit': 762, 'macroAcceptance': 'pending', 'textProduct': True,
                         'lightingModeOptions': True, 'lightingWrite': False, 'defaultResetWrite': False, 'defaultTransactionFileInspection': True},
            'files': {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(out.rglob('*')) if p.is_file()}}
(out / 'release.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(f'Prepared online preview {version} from {commit}: {out}')
