"""Allowlisted PHP deployment files, shared by release and preview packaging."""
import pathlib
import re

RUNTIME_NAMES = ['index.php', 'README.md', 'start.command'] + [
    'assets/' + name for name in [
        'app.js', 'hid.js', 'layout.js', 'logs.js', 'model.js', 'safety.js',
        'storage.js', 'style.css', 'tables.js', 'writer.js', 'macro-session.js',
        'macro-stop.js', 'product-macros.js', 'product-text.js', 'text-bridge.js',
    ]
]


def runtime_files(root: pathlib.Path, version: str):
    files = [root / name for name in RUNTIME_NAMES]
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
