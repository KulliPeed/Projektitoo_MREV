#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
DB_NAME="andmeprojekt"
DB_USER="andrus"

cd "$PROJECT_DIR"

docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL'
\pset pager off
\echo '=== Pipeline kihtide viimased kuupaevad ==='
SELECT 'raw_mta' AS layer, max(snapshot_date) AS max_date FROM raw.mta_maksuvolglased_csv
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

\echo '=== Pipeline freshness ==='
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
