#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

cd "$PROJECT_DIR"
mkdir -p logs
LOG="logs/mart_star_refresh_$(date +%Y-%m-%d_%H%M%S).log"
START_EPOCH="$(date +%s)"

run_sql() {
  local label="$1"
  local sql_file="$2"

  echo "[$(date --iso-8601=seconds)] $label: $sql_file"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$sql_file"
}

print_summary() {
  echo "[$(date --iso-8601=seconds)] MART_STAR luhikokkuvote"
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL'
\pset pager off
\echo '=== MART_STAR refresh kokkuvote ==='
WITH summary AS (
    SELECT 'dim_ettevote_ridu' AS naitaja, count(*)::text AS vaartus
    FROM mart_star.dim_ettevote
    UNION ALL
    SELECT 'dim_aeg_ridu', count(*)::text
    FROM mart_star.dim_aeg
    UNION ALL
    SELECT 'dim_vanuse_grupp_ridu', count(*)::text
    FROM mart_star.dim_vanuse_grupp
    UNION ALL
    SELECT 'mta_kuupaevi_faktis', count(DISTINCT kuupaev)::text
    FROM mart_star.fact_maksuvolg
    UNION ALL
    SELECT 'fact_maksuvolg_ridu', count(*)::text
    FROM mart_star.fact_maksuvolg
    UNION ALL
    SELECT 'fact_maksuvola_summa', COALESCE(sum(maksuvola_summa), 0)::text
    FROM mart_star.fact_maksuvolg
    UNION ALL
    SELECT 'juhatuse_muutusega_faktiridu', count(*) FILTER (WHERE juhatuse_muutuse_fakt)::text
    FROM mart_star.fact_maksuvolg
    UNION ALL
    SELECT 'rik_vordluseta_mta_kuupaevi', count(DISTINCT mta_kuupaev) FILTER (WHERE rik_vordlus_olemas = false)::text
    FROM mart_star.v_juhatuse_muutus_paeviti
)
SELECT naitaja, vaartus
FROM summary
ORDER BY
    CASE naitaja
        WHEN 'dim_ettevote_ridu' THEN 1
        WHEN 'dim_aeg_ridu' THEN 2
        WHEN 'dim_vanuse_grupp_ridu' THEN 3
        WHEN 'mta_kuupaevi_faktis' THEN 4
        WHEN 'fact_maksuvolg_ridu' THEN 5
        WHEN 'fact_maksuvola_summa' THEN 6
        WHEN 'juhatuse_muutusega_faktiridu' THEN 7
        WHEN 'rik_vordluseta_mta_kuupaevi' THEN 8
        ELSE 99
    END;
SQL
}

perform_refresh() {
  set -e
  echo "[$(date --iso-8601=seconds)] MART_STAR refresh algas"
  run_sql "Loon ja varskendan MART_STAR tahtmudeli" "db/migrations/130_create_mart_star_schema.sql"
  run_sql "Kaivitan MART_STAR kvaliteedikontrollid" "quality/040_mart_star_quality_checks.sql"
  print_summary
}

set +e
perform_refresh 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

DURATION_SECONDS="$(($(date +%s) - START_EPOCH))"
if [ "$STATUS" -eq 0 ]; then
  {
    echo "[$(date --iso-8601=seconds)] MART_STAR refresh valmis"
    echo "kestus_sekundites=$DURATION_SECONDS"
    echo "log=$LOG"
    echo "tulemus=OK"
  } | tee -a "$LOG"
  exit 0
fi

{
  echo "[$(date --iso-8601=seconds)] MART_STAR refresh ebaonnestus"
  echo "kestus_sekundites=$DURATION_SECONDS"
  echo "log=$LOG"
  echo "tulemus=FAILED"
} | tee -a "$LOG" >&2
exit "$STATUS"
