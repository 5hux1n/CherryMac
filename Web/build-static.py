"""Render the existing PHP UI for static hosting; no PHP needed at runtime."""
from pathlib import Path
import subprocess, shutil
root = Path(__file__).resolve().parent
out = root / 'static-dist'
if out.exists(): shutil.rmtree(out)
out.mkdir()
page = subprocess.check_output(['php', str(root / 'index.php')], text=True)
assert '<?php' not in page and '<?=' not in page
# GitHub Pages cannot send custom headers; retain the applicable policy as HTML metadata.
policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' http://127.0.0.1:32247; object-src 'none'; base-uri 'none'"
page = page.replace('<head>', '<head><meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="' + policy + '">', 1)
(out / 'index.html').write_text(page)
shutil.copytree(root / 'assets', out / 'assets')
(out / '.nojekyll').touch()
(out / 'CNAME').write_text('cherrymac.goforit.si\n')
print(out)
