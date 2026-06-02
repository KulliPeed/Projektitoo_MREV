#!/usr/bin/env bash
# NB! See skript teeb tais-refreshi ja ehitab koik stage tabelid koigist RAW snapshotidest uuesti.
# Igapaevaseks kasutuseks eelista scripts/refresh_stage_incremental.sh
# voi scripts/refresh_stage_snapshot.sh YYYY-MM-DD.
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

cd "$PROJECT_DIR"
mkdir -p logs
LOG="logs/stage_refresh_$(date +%Y-%m-%d_%H%M%S).log"

run_sql() {
  local label="$1"
  local sql_file="$2"

  echo "[$(date --iso-8601=seconds)] $label: $sql_file"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$sql_file"
}

{
  echo "[$(date --iso-8601=seconds)] Stage refresh algas"
  run_sql "Loon MTA stage struktuuri" "db/migrations/010_create_stage_mta_maksuvolglased.sql"
  run_sql "Loon RIK ettevotete stage struktuuri" "db/migrations/020_create_stage_rik_ettevotted.sql"
  run_sql "Loon RIK isikute stage struktuuri" "db/migrations/030_create_stage_rik_kaardile_kantud_isikud.sql"
  run_sql "Laadin stage tabelid RAW andmetest" "db/migrations/090_refresh_stage_all.sql"
  run_sql "Käivitan stage kvaliteedikontrollid" "quality/010_stage_quality_checks.sql"
  echo "[$(date --iso-8601=seconds)] Stage refresh valmis"
} 2>&1 | tee "$LOG"
