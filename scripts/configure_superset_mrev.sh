#!/usr/bin/env bash
set -euo pipefail

cd /home/pi/kool/projekt

if [ ! -f ".env.superset" ]; then
  echo "Puudub .env.superset"
  exit 1
fi

set -a
source ".env.superset"
set +a

mkdir -p logs

TS=$(date +"%Y-%m-%d_%H%M%S")
LOG="logs/superset_mrev_config_${TS}.log"

PYTHON_BIN="python3"
if [ -x ".venv/bin/python" ]; then
  PYTHON_BIN=".venv/bin/python"
fi

"$PYTHON_BIN" scripts/configure_superset_mrev.py 2>&1 | tee "$LOG"
