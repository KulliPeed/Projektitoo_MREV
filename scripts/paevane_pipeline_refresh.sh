#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"
LOCK_NAME="paevane_pipeline_refresh.sh"

cd "$PROJECT_DIR"
mkdir -p logs

TS="$(date +"%Y-%m-%d_%H%M%S")"
LOG="logs/paevane_pipeline_refresh_${TS}.log"
START_EPOCH="$(date +%s)"

exec 9<"$PROJECT_DIR/scripts/$LOCK_NAME"
if ! flock -n 9; then
  echo "[$(date --iso-8601=seconds)] Teine pipeline refresh juba kaib: $LOCK_NAME" | tee "$LOG"
  exit 1
fi

psql_exec() {
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"
}

show_layer_dates() {
  psql_exec <<'SQL'
\pset pager off
SELECT 'raw_mta' AS layer, max(snapshot_date) AS max_snapshot_date FROM raw.mta_maksuvolglased_csv
UNION ALL
SELECT 'raw_rik' AS layer, max(snapshot_date) FROM raw.rik_kaardile_kantud_isikud_json
UNION ALL
SELECT 'stage_mta' AS layer, max(snapshot_date) FROM stage.mta_maksuvolglased
UNION ALL
SELECT 'stage_rik_ettevotted' AS layer, max(snapshot_date) FROM stage.rik_ettevotted
UNION ALL
SELECT 'stage_rik_isikud' AS layer, max(snapshot_date) FROM stage.rik_kaardile_kantud_isikud
UNION ALL
SELECT 'mart_star_fact' AS layer, max(kuupaev) FROM mart_star.fact_maksuvolg
ORDER BY layer;
SQL
}

show_pipeline_freshness() {
  psql_exec <<'SQL'
\pset pager off
WITH raw_mta AS (
    SELECT max(snapshot_date) AS d FROM raw.mta_maksuvolglased_csv
),
stage_mta AS (
    SELECT max(snapshot_date) AS d FROM stage.mta_maksuvolglased
),
fact AS (
    SELECT max(kuupaev) AS d FROM mart_star.fact_maksuvolg
),
stage_dates AS (
    SELECT count(DISTINCT snapshot_date) AS cnt FROM stage.mta_maksuvolglased
),
fact_dates AS (
    SELECT count(DISTINCT kuupaev) AS cnt FROM mart_star.fact_maksuvolg
)
SELECT
    raw_mta.d AS raw_mta_max,
    stage_mta.d AS stage_mta_max,
    fact.d AS mart_star_fact_max,
    stage_dates.cnt AS stage_mta_snapshot_count,
    fact_dates.cnt AS mart_star_fact_snapshot_count,
    (raw_mta.d = stage_mta.d AND stage_mta.d = fact.d) AS pipeline_fresh,
    (stage_dates.cnt = fact_dates.cnt) AS snapshot_count_ok
FROM raw_mta, stage_mta, fact, stage_dates, fact_dates;
SQL
}

perform_refresh() {
  echo "=== MREV paevane pipeline refresh START ${TS} ==="
  echo "Tookoht: $(pwd)"
  echo "Kasutaja: $(whoami)"
  echo "Logi: $LOG"
  echo

  echo "1) Kontroll: kihid enne refreshi"
  show_layer_dates
  echo

  echo "2) STAGE incremental refresh"
  ./scripts/refresh_stage_incremental.sh
  echo

  echo "3) MART_STAR refresh"
  ./scripts/refresh_mart_star.sh
  echo

  echo "4) Kontroll: kihid parast refreshi"
  show_layer_dates
  echo

  echo "5) Kontroll: pipeline freshness"
  show_pipeline_freshness
  echo

  echo "=== MREV paevane pipeline refresh DONE $(date +"%Y-%m-%d_%H%M%S") ==="
}

set +e
perform_refresh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

DURATION_SECONDS="$(($(date +%s) - START_EPOCH))"
if [ "$STATUS" -eq 0 ]; then
  {
    echo "[$(date --iso-8601=seconds)] Pipeline refresh valmis"
    echo "kestus_sekundites=$DURATION_SECONDS"
    echo "log=$LOG"
    echo "tulemus=OK"
  } | tee -a "$LOG"
  exit 0
fi

{
  echo "[$(date --iso-8601=seconds)] Pipeline refresh ebaonnestus"
  echo "kestus_sekundites=$DURATION_SECONDS"
  echo "log=$LOG"
  echo "tulemus=FAILED"
} | tee -a "$LOG" >&2
exit "$STATUS"
