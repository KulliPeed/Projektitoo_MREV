#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
LOG_DIR="$PROJECT_DIR/logs"
RUN_DATE="$(date +%F)"

mkdir -p "$LOG_DIR"
exec >> "$LOG_DIR/rik_snapshot_${RUN_DATE}.log" 2>&1

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

echo "[$(date --iso-8601=seconds)] Alustan RIK snapshoti allalaadimist kuupaevale $RUN_DATE"
"$PYTHON" "$PROJECT_DIR/scripts/laeAriregister.py" --date "$RUN_DATE" --overwrite

echo "[$(date --iso-8601=seconds)] Allalaadimine onnestus, alustan lahtipakkimist"
"$PYTHON" "$PROJECT_DIR/scripts/paki_Arigeg_lahti.py" --date "$RUN_DATE"

JSON_FILE="data/raw/rik/${RUN_DATE}/extracted/ettevotja_rekvisiidid__kaardile_kantud_isikud.json"
if [ ! -s "$JSON_FILE" ]; then
  echo "[$(date --iso-8601=seconds)] JSON faili ei leitud voi see on tyhi: $JSON_FILE"
  exit 1
fi

echo "[$(date --iso-8601=seconds)] Lahtipakkimine onnestus, alustan raw tabelisse laadimist"
"$PYTHON" "$PROJECT_DIR/scripts/lae_rik_json_raw.py" "$JSON_FILE" "$RUN_DATE"

echo "[$(date --iso-8601=seconds)] RIK snapshoti paevane too valmis"
