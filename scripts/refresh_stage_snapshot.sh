#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

usage() {
  echo "Kasutus: $0 YYYY-MM-DD" >&2
}

if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  usage
  exit 2
fi

SNAPSHOT_DATE="$1"
if [ "$(date -d "$SNAPSHOT_DATE" +%F 2>/dev/null || true)" != "$SNAPSHOT_DATE" ]; then
  usage
  exit 2
fi

if [ ! -d "$PROJECT_DIR/db/migrations" ] || [ ! -d "$PROJECT_DIR/quality" ]; then
  echo "Projektikausta stage SQL faile ei leitud: $PROJECT_DIR" >&2
  exit 1
fi

cd "$PROJECT_DIR"
mkdir -p logs
LOG="logs/stage_snapshot_refresh_${SNAPSHOT_DATE}_$(date +%Y%m%d_%H%M%S).log"
START_EPOCH="$(date +%s)"

run_sql() {
  local label="$1"
  local sql_file="$2"

  echo "[$(date --iso-8601=seconds)] $label: $sql_file"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 \
    -v snapshot_date="$SNAPSHOT_DATE" -U "$DB_USER" -d "$DB_NAME" < "$sql_file"
}

perform_refresh() {
  set -e
  echo "[$(date --iso-8601=seconds)] Stage snapshot refresh algas: snapshot_date=$SNAPSHOT_DATE"
  run_sql "Loon MTA stage struktuuri" "db/migrations/010_create_stage_mta_maksuvolglased.sql"
  run_sql "Loon RIK ettevotete stage struktuuri" "db/migrations/020_create_stage_rik_ettevotted.sql"
  run_sql "Loon RIK isikute stage struktuuri" "db/migrations/030_create_stage_rik_kaardile_kantud_isikud.sql"
  run_sql "Laadin valitud snapshoti stage tabelitesse" "db/migrations/091_refresh_stage_snapshot.sql"
  run_sql "Kontrollin valitud snapshoti" "quality/020_stage_snapshot_quality_checks.sql"
}

set +e
perform_refresh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

DURATION_SECONDS="$(($(date +%s) - START_EPOCH))"
if [ "$STATUS" -eq 0 ]; then
  {
    echo "[$(date --iso-8601=seconds)] Stage snapshot refresh valmis"
    echo "snapshot_date=$SNAPSHOT_DATE"
    echo "kestus_sekundites=$DURATION_SECONDS"
    echo "tulemus=OK"
  } | tee -a "$LOG"
  exit 0
fi

{
  echo "[$(date --iso-8601=seconds)] Stage snapshot refresh ebaonnestus"
  echo "snapshot_date=$SNAPSHOT_DATE"
  echo "kestus_sekundites=$DURATION_SECONDS"
  echo "tulemus=FAILED"
} | tee -a "$LOG" >&2
exit "$STATUS"
