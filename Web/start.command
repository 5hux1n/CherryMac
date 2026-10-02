#!/bin/zsh
set -eu
cd -- "$(dirname -- "$0")"
command -v php >/dev/null || { print '请先安装 PHP，再运行此脚本。'; exit 1; }
print 'CherryMac 网页版：http://localhost:8768/'
print '请用 Chrome 或 Edge 打开；按 Control+C 停止本机服务。'
exec php -S 127.0.0.1:8768 -t .
