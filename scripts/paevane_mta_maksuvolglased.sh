#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
LOG_DIR="$PROJECT_DIR/logs"
RUN_DATE="$(date +%F)"

mkdir -p "$LOG_DIR"
exec >> "$LOG_DIR/maksuvolglased_${RUN_DATE}.log" 2>&1

cd "$PROJECT_DIR"

if [ -f "$PROJECT_DIR/.env" ]; then
  set -a
  . "$PROJECT_DIR/.env"
  set +a
fi

if [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
  PYTHON="$PROJECT_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  PYTHON="$(command -v python)"
fi

echo "[$(date --iso-8601=seconds)] Alustan MTA maksuvõlglaste CSV allalaadimist kuupaevale $RUN_DATE"
"$PYTHON" "$PROJECT_DIR/scripts/download_maksuvolglased.py" --keep-latest-copy

CSV_FILE="data/raw/maksuvolglased/maksuvolglased_latest.csv"
if [ ! -s "$CSV_FILE" ]; then
  echo "[$(date --iso-8601=seconds)] CSV faili ei leitud voi see on tyhi: $CSV_FILE"
  exit 1
fi

echo "[$(date --iso-8601=seconds)] Allalaadimine onnestus, alustan MTA raw tabelisse importi"
"$PYTHON" "$PROJECT_DIR/scripts/lae_mta_maksuvolglased_raw.py"

echo "[$(date --iso-8601=seconds)] MTA maksuvõlglaste paevane too valmis"
