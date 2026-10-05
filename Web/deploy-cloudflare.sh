#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
git diff --quiet HEAD -- Web
python3 Web/build-cloudflare.py
wrangler deploy --config Web/wrangler.jsonc
