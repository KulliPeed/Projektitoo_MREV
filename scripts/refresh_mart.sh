#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

cd "$PROJECT_DIR"
mkdir -p logs
LOG="logs/mart_refresh_$(date +%Y-%m-%d_%H%M%S).log"
START_EPOCH="$(date +%s)"

run_sql() {
  local label="$1"
  local sql_file="$2"

  echo "[$(date --iso-8601=seconds)] $label: $sql_file"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$sql_file"
}

print_summary() {
  echo "[$(date --iso-8601=seconds)] MART luhikokkuvote"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL'
\pset pager off
\echo '=== MART refresh kokkuvote ==='
WITH latest_mta_rows AS (
    SELECT count(*) AS rows
    FROM stage.mta_maksuvolglased
    WHERE data_as_of = (SELECT latest_mta_data_as_of FROM mart.v_latest_dates)
),
kpi AS (
    SELECT * FROM mart.v_dashboard_kpi
),
kpi_rows AS (
    SELECT count(*) AS rows FROM mart.v_dashboard_kpi
)
SELECT 'vaated loodud' AS naitaja, 'OK' AS vaartus
UNION ALL
SELECT 'kvaliteedikontrollid', 'OK'
UNION ALL
SELECT 'kpi_vaate_ridu', rows::text FROM kpi_rows
UNION ALL
SELECT 'viimase_mta_seisu_ridu', rows::text FROM latest_mta_rows
UNION ALL
SELECT 'rik_uhildumise_maar_pct', uhildumise_maar_pct::text FROM kpi
UNION ALL
SELECT 'juhatuse_muutusega_maksuvolglasi', juhatus_muutunud_ettevotteid::text FROM kpi
UNION ALL
SELECT 'maksuvolg_kokku', maksuvolg_summa::text FROM kpi;
SQL
}

perform_refresh() {
  set -e
  echo "[$(date --iso-8601=seconds)] MART refresh algas"
  run_sql "Loon MART vaated" "db/migrations/100_create_mart_views.sql"
  run_sql "Varskendan Superseti MART cache" "db/migrations/110_create_mart_superset_cache.sql"
  run_sql "Kaivitan MART kvaliteedikontrollid" "quality/030_mart_quality_checks.sql"
  print_summary
}

set +e
perform_refresh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

DURATION_SECONDS="$(($(date +%s) - START_EPOCH))"
if [ "$STATUS" -eq 0 ]; then
  {
    echo "[$(date --iso-8601=seconds)] MART refresh valmis"
    echo "kestus_sekundites=$DURATION_SECONDS"
    echo "log=$LOG"
    echo "tulemus=OK"
  } | tee -a "$LOG"
  exit 0
fi

{
  echo "[$(date --iso-8601=seconds)] MART refresh ebaonnestus"
  echo "kestus_sekundites=$DURATION_SECONDS"
  echo "log=$LOG"
  echo "tulemus=FAILED"
} | tee -a "$LOG" >&2
exit "$STATUS"
