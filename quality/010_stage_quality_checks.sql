\set ON_ERROR_STOP on
\pset pager off

\echo '=== RAW ja stage rea-arvude kontroll ==='
WITH mta_sources AS (
    SELECT
        r.snapshot_date,
        r.source_file,
        r.file_sha256,
        max(r.loaded_at) AS loaded_at
    FROM raw.mta_maksuvolglased_csv r
    GROUP BY
        r.snapshot_date,
        r.source_file,
        r.file_sha256
),
latest_mta_sources AS (
    SELECT snapshot_date, source_file, file_sha256
    FROM (
        SELECT
            s.*,
            row_number() OVER (
                PARTITION BY s.snapshot_date
                ORDER BY s.loaded_at DESC, s.source_file DESC, s.file_sha256 DESC
            ) AS rn
        FROM mta_sources s
    ) ranked
    WHERE rn = 1
),
counts AS (
    SELECT
        (
            SELECT count(*)
            FROM raw.mta_maksuvolglased_csv r
            JOIN latest_mta_sources latest
              ON latest.snapshot_date = r.snapshot_date
             AND latest.source_file = r.source_file
             AND latest.file_sha256 = r.file_sha256
        ) AS raw_mta,
        (SELECT count(*) FROM stage.mta_maksuvolglased) AS stage_mta,
        (SELECT count(*) FROM raw.rik_kaardile_kantud_isikud_json) AS raw_rik,
        (SELECT count(*) FROM stage.rik_ettevotted) AS stage_rik
)
SELECT
    'mta_raw_to_stage_parity' AS check_name,
    raw_mta AS raw_rows,
    stage_mta AS stage_rows,
    CASE WHEN raw_mta = stage_mta THEN 'OK' ELSE 'ERROR' END AS status
FROM counts
UNION ALL
SELECT
    'rik_raw_to_ettevotted_parity',
    raw_rik,
    stage_rik,
    CASE WHEN raw_rik = stage_rik THEN 'OK' ELSE 'ERROR' END
FROM counts;

SELECT 'raw_rik_rows' AS check_name, count(*) AS value
FROM raw.rik_kaardile_kantud_isikud_json
UNION ALL
SELECT 'raw_mta_rows', count(*)
FROM raw.mta_maksuvolglased_csv;

\echo '=== MTA snapshotid ==='
SELECT snapshot_date, data_as_of, count(*) AS rows
FROM stage.mta_maksuvolglased
GROUP BY snapshot_date, data_as_of
ORDER BY snapshot_date, data_as_of;

\echo '=== MTA registrikood ja teisendused ==='
SELECT 'bad_registrikood_count' AS check_name, count(*) AS value
FROM stage.mta_maksuvolglased
WHERE registrikood IS NULL OR registrikood !~ '^[0-9]{8}$'
UNION ALL
SELECT 'rows_with_null_maksuvolg', count(*)
FROM stage.mta_maksuvolglased
WHERE maksuvolg IS NULL
UNION ALL
SELECT 'negative_maksuvolg_count', count(*)
FROM stage.mta_maksuvolglased
WHERE maksuvolg < 0
UNION ALL
SELECT 'null_data_as_of_count', count(*)
FROM stage.mta_maksuvolglased
WHERE data_as_of IS NULL
UNION ALL
SELECT 'null_oldest_due_date_count', count(*)
FROM stage.mta_maksuvolglased
WHERE vanima_tasumata_noude_tasumise_tahtaeg IS NULL;

SELECT volg_vanuse_grupp, count(*) AS rows, sum(maksuvolg) AS maksuvolg_sum
FROM stage.mta_maksuvolglased
GROUP BY volg_vanuse_grupp
ORDER BY volg_vanuse_grupp;

\echo '=== RIK ettevotted ==='
SELECT snapshot_date, count(*) AS rows
FROM stage.rik_ettevotted
GROUP BY snapshot_date
ORDER BY snapshot_date;

SELECT 'bad_registrikood_count' AS check_name, count(*) AS value
FROM stage.rik_ettevotted
WHERE registrikood IS NULL OR registrikood !~ '^[0-9]{8}$'
UNION ALL
SELECT 'duplicate_snapshot_registrikood_count', count(*)
FROM (
    SELECT snapshot_date, registrikood
    FROM stage.rik_ettevotted
    GROUP BY snapshot_date, registrikood
    HAVING count(*) > 1
) duplicates;

\echo '=== RIK kaardile kantud isikud ==='
SELECT snapshot_date, count(*) AS rows
FROM stage.rik_kaardile_kantud_isikud
GROUP BY snapshot_date
ORDER BY snapshot_date;

SELECT snapshot_date, count(*) AS juhatuse_liikme_read
FROM stage.rik_kaardile_kantud_isikud
WHERE on_juhatuse_liige = true
GROUP BY snapshot_date
ORDER BY snapshot_date;

\echo '=== Viimase MTA ja viimase RIK snapshoti uhildumine ==='
WITH latest_mta AS (
    SELECT max(data_as_of) AS data_as_of FROM stage.mta_maksuvolglased
),
latest_rik AS (
    SELECT max(snapshot_date) AS snapshot_date FROM stage.rik_ettevotted
)
SELECT
    count(*) AS mta_rows,
    count(e.registrikood) AS matched_rik_rows,
    count(*) - count(e.registrikood) AS unmatched_rik_rows
FROM stage.mta_maksuvolglased m
JOIN latest_mta lm ON m.data_as_of = lm.data_as_of
LEFT JOIN latest_rik lr ON true
LEFT JOIN stage.rik_ettevotted e
       ON e.snapshot_date = lr.snapshot_date
      AND e.registrikood = m.registrikood;
