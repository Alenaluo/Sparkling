#!/bin/zsh
# 开发运行：根目录放 ~/IdeaNotes-dev（避开 ~/Documents 的授权弹窗），跳过首次引导可设 SPARKLING_SKIP_ONBOARDING=1
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x Sparkling 2>/dev/null || true
scripts/bundle.sh debug
export SPARKLING_ROOT=${SPARKLING_ROOT:-$HOME/IdeaNotes-dev}
# open 不传环境变量，直接启动可执行文件并放到后台
nohup build/Sparkling.app/Contents/MacOS/Sparkling > build/run.log 2>&1 &
echo "running pid $! root=$SPARKLING_ROOT (log: build/run.log; 系统日志: /usr/bin/log stream --predicate 'subsystem == \"local.sparkling\"')"
