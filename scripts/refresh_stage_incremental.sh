#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

cd "$PROJECT_DIR"
mkdir -p logs
LOG="logs/stage_incremental_refresh_$(date +%Y-%m-%d_%H%M%S).log"
START_EPOCH="$(date +%s)"

find_missing_snapshots() {
  docker exec "$CONTAINER" psql -X -At -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "
    WITH mta_raw_dates AS MATERIALIZED (
        SELECT DISTINCT snapshot_date
        FROM raw.mta_maksuvolglased_csv
    ),
    rik_raw_dates AS MATERIALIZED (
        SELECT DISTINCT snapshot_date
        FROM raw.rik_kaardile_kantud_isikud_json
    )
    SELECT snapshot_date
    FROM (
        SELECT r.snapshot_date
        FROM mta_raw_dates r
        WHERE NOT EXISTS (
            SELECT 1
            FROM stage.mta_maksuvolglased s
            WHERE s.snapshot_date = r.snapshot_date
        )
        UNION
        SELECT r.snapshot_date
        FROM rik_raw_dates r
        WHERE NOT EXISTS (
            SELECT 1
            FROM stage.rik_ettevotted s
            WHERE s.snapshot_date = r.snapshot_date
        )
           OR NOT EXISTS (
            SELECT 1
            FROM stage.rik_kaardile_kantud_isikud s
            WHERE s.snapshot_date = r.snapshot_date
        )
    ) missing
    ORDER BY snapshot_date;"
}

perform_refresh() {
  local missing_snapshots
  local snapshot_date

  set -e
  echo "[$(date --iso-8601=seconds)] Stage incremental refresh algas"
  missing_snapshots="$(find_missing_snapshots)"
  if [ -z "$missing_snapshots" ]; then
    echo "Uusi RAW snapshote stage jaoks ei leitud."
    return 0
  fi

  while IFS= read -r snapshot_date; do
    [ -z "$snapshot_date" ] && continue
    echo "Tootlen snapshoti: $snapshot_date"
    "$PROJECT_DIR/scripts/refresh_stage_snapshot.sh" "$snapshot_date"
  done <<< "$missing_snapshots"
}

set +e
perform_refresh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

DURATION_SECONDS="$(($(date +%s) - START_EPOCH))"
if [ "$STATUS" -eq 0 ]; then
  {
    echo "[$(date --iso-8601=seconds)] Stage incremental refresh valmis"
    echo "kestus_sekundites=$DURATION_SECONDS"
    echo "tulemus=OK"
  } | tee -a "$LOG"
  exit 0
fi

{
  echo "[$(date --iso-8601=seconds)] Stage incremental refresh ebaonnestus"
  echo "kestus_sekundites=$DURATION_SECONDS"
  echo "tulemus=FAILED"
} | tee -a "$LOG" >&2
exit "$STATUS"
