#!/usr/bin/env python3
"""Package the no-build PHP product; omit development/research entry points."""
import hashlib
import pathlib
import re
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parent
version = sys.argv[1] if len(sys.argv) == 2 else ''
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('Usage: python3 Web/package-release.py VERSION')
files = [root / name for name in ['index.php', 'README.md', 'start.command']]
files += [root / 'assets' / name for name in
          ['app.js', 'hid.js', 'layout.js', 'logs.js', 'model.js', 'safety.js',
           'storage.js', 'style.css', 'tables.js', 'writer.js']]
paths = {path.resolve() for path in files}
for path in files:
    text = path.read_text()
    if path.suffix == '.js':
        for reference in re.findall(r"from\s+['\"]([^'\"]+)['\"]", text):
            dependency, _, query = reference.partition('?')
            if not dependency.startswith('./') or (path.parent / dependency).resolve() not in paths:
                raise SystemExit(f'Missing runtime dependency: {path.name}: {reference}')
            if query != 'v=' + version:
                raise SystemExit(f'Stale runtime version: {path.name}: {reference}')
if f'CherryMac Web {version}' not in (root / 'index.php').read_text():
    raise SystemExit('Version does not match PHP page')
output = root.parent / f'CherryMac-Web-{version}.zip'
if output.exists():
    raise SystemExit('Refusing to overwrite an existing versioned package')
with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        archive.write(path, f'CherryMac-Web-{version}/{path.relative_to(root).as_posix()}')
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    for path in files:
        assert archive.read(f'CherryMac-Web-{version}/{path.relative_to(root).as_posix()}') == path.read_bytes()
print(f'{hashlib.sha256(output.read_bytes()).hexdigest()}  {output.name} ({len(files)} files)')
