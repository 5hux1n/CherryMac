"""Allowlisted PHP deployment files, shared by release and preview packaging."""
import pathlib
import re
import json


def preview_versions(root: pathlib.Path):
    path = root / 'preview-versions.json'
    if path.stat().st_size > 1024:
        raise ValueError('Preview version file exceeds bounds')
    value = json.loads(path.read_text())
    if (set(value) != {'format', 'version', 'product', 'lightingAcceptance'} or
            value['format'] != 'CherryMacWebPreviewVersions' or
            type(value['version']) is not int or value['version'] != 1):
        raise ValueError('Invalid preview version file')
    for key in ('product', 'lightingAcceptance'):
        if not isinstance(value[key], str) or not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value[key]):
            raise ValueError('Invalid preview release version')
    return value

RUNTIME_NAMES = ['index.php', 'README.md', 'start.command'] + [
    'assets/' + name for name in [
        'app.js', 'hid.js', 'layout.js', 'logs.js', 'model.js', 'safety.js',
        'page-operation.js', 'storage.js', 'style.css', 'tables.js', 'writer.js', 'macro-session.js',
        'macro-stop.js', 'product-macros.js', 'product-text.js', 'text-bridge.js', 'database.js', 'extended-backup-editor.js', 'extended-hardware-backup.js', 'extended-hardware-backup-store.js',
    ]
]


def runtime_files(root: pathlib.Path, version: str, lighting_acceptance=False):
    names = RUNTIME_NAMES + (['lighting-test.php', 'assets/lighting-test-entry.js', 'assets/lighting-test-plan.js'] if lighting_acceptance else [])
    files = [root / name for name in names]
    paths = {path.resolve() for path in files}
    for path in files:
        text = path.read_text()
        if path.suffix == '.js':
            for reference in re.findall(r"from\s+['\"]([^'\"]+)['\"]", text):
                dependency, _, query = reference.partition('?')
                if not dependency.startswith('./') or (path.parent / dependency).resolve() not in paths:
                    raise ValueError(f'Missing runtime dependency: {path.name}: {reference}')
                if query != 'v=' + version:
                    raise ValueError(f'Stale runtime version: {path.name}: {reference}')
    if f'CherryMac Web {version}' not in (root / 'index.php').read_text():
        raise ValueError('Version does not match PHP page')
    return files
