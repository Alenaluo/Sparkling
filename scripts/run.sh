#!/bin/zsh
# Dev run: data root is ~/IdeaNotes-dev (avoids the ~/Documents permission prompt); to skip onboarding set SPARKLING_SKIP_ONBOARDING=1
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x Sparkling 2>/dev/null || true
scripts/bundle.sh debug
export SPARKLING_ROOT=${SPARKLING_ROOT:-$HOME/IdeaNotes-dev}
# `open` does not pass environment variables, so launch the executable directly in the background
nohup build/Sparkling.app/Contents/MacOS/Sparkling > build/run.log 2>&1 &
echo "running pid $! root=$SPARKLING_ROOT (log: build/run.log; system log: /usr/bin/log stream --predicate 'subsystem == \"local.sparkling\"')"
