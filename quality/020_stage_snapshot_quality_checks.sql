\set ON_ERROR_STOP on
\pset pager off

CREATE TEMP TABLE snapshot_quality_target AS
SELECT :'snapshot_date'::date AS snapshot_date;

CREATE TEMP TABLE snapshot_quality_mta_source AS
WITH sources AS (
    SELECT
        r.snapshot_date,
        r.source_file,
        r.file_sha256,
        max(r.loaded_at) AS loaded_at,
        max(r.data_as_of) AS data_as_of,
        count(*) AS rows
    FROM raw.mta_maksuvolglased_csv r
    JOIN snapshot_quality_target p ON p.snapshot_date = r.snapshot_date
    GROUP BY
        r.snapshot_date,
        r.source_file,
        r.file_sha256
),
ranked AS (
    SELECT
        s.*,
        row_number() OVER (
            PARTITION BY s.snapshot_date
            ORDER BY s.loaded_at DESC, s.source_file DESC, s.file_sha256 DESC
        ) AS rn
    FROM sources s
)
SELECT
    snapshot_date,
    source_file,
    file_sha256,
    loaded_at,
    data_as_of,
    rows
FROM ranked
WHERE rn = 1;

\echo '=== Snapshotipohine stage kvaliteedikontroll ==='
SELECT snapshot_date FROM snapshot_quality_target;

\echo '=== Valitud MTA RAW allikas ==='
SELECT snapshot_date, source_file, data_as_of, rows
FROM snapshot_quality_mta_source;

\echo '=== MTA RAW/stage ==='
SELECT
    p.snapshot_date,
    raw.rows AS raw_rows,
    stage.rows AS stage_rows,
    CASE
        WHEN raw.rows IS NULL THEN 'SKIPPED: RAW puudub'
        WHEN raw.rows = stage.rows THEN 'OK'
        ELSE 'ERROR'
    END AS status
FROM snapshot_quality_target p
LEFT JOIN (
    SELECT r.snapshot_date, count(*) AS rows
    FROM raw.mta_maksuvolglased_csv r
    JOIN snapshot_quality_mta_source target
      ON target.snapshot_date = r.snapshot_date
     AND target.source_file = r.source_file
     AND target.file_sha256 = r.file_sha256
    GROUP BY r.snapshot_date
) raw ON raw.snapshot_date = p.snapshot_date
LEFT JOIN (
    SELECT s.snapshot_date, count(*) AS rows
    FROM stage.mta_maksuvolglased s
    JOIN snapshot_quality_target target ON target.snapshot_date = s.snapshot_date
    GROUP BY s.snapshot_date
) stage ON stage.snapshot_date = p.snapshot_date;

SELECT
    count(*) FILTER (WHERE maksuvolg IS NULL) AS null_maksuvolg,
    count(*) FILTER (WHERE maksuvolg < 0) AS negative_maksuvolg,
    count(*) FILTER (WHERE data_as_of IS NULL) AS null_data_as_of,
    count(*) FILTER (WHERE vanima_tasumata_noude_tasumise_tahtaeg IS NULL) AS null_oldest_due_date
FROM stage.mta_maksuvolglased s
JOIN snapshot_quality_target p ON p.snapshot_date = s.snapshot_date;

\echo '=== RIK ettevotted RAW/stage ==='
SELECT
    p.snapshot_date,
    raw.rows AS raw_rows,
    stage.rows AS stage_rows,
    CASE
        WHEN raw.rows IS NULL THEN 'SKIPPED: RAW puudub'
        WHEN raw.rows = stage.rows THEN 'OK'
        ELSE 'ERROR'
    END AS status
FROM snapshot_quality_target p
LEFT JOIN (
    SELECT r.snapshot_date, count(*) AS rows
    FROM raw.rik_kaardile_kantud_isikud_json r
    JOIN snapshot_quality_target target ON target.snapshot_date = r.snapshot_date
    GROUP BY r.snapshot_date
) raw ON raw.snapshot_date = p.snapshot_date
LEFT JOIN (
    SELECT s.snapshot_date, count(*) AS rows
    FROM stage.rik_ettevotted s
    JOIN snapshot_quality_target target ON target.snapshot_date = s.snapshot_date
    GROUP BY s.snapshot_date
) stage ON stage.snapshot_date = p.snapshot_date;

SELECT
    count(*) FILTER (WHERE registrikood IS NULL OR btrim(registrikood) = '') AS missing_registrikood,
    (
        SELECT count(*)
        FROM (
            SELECT e.registrikood
            FROM stage.rik_ettevotted e
            JOIN snapshot_quality_target p ON p.snapshot_date = e.snapshot_date
            GROUP BY e.registrikood
            HAVING count(*) > 1
        ) duplicates
    ) AS duplicate_registrikood_groups
FROM stage.rik_ettevotted s
JOIN snapshot_quality_target p ON p.snapshot_date = s.snapshot_date;

\echo '=== RIK kaardile kantud isikud ==='
CREATE TEMP TABLE snapshot_quality_rik_isikud AS
SELECT
    count(*) AS isik_rows,
    count(*) FILTER (WHERE roll IS NULL) AS null_roll,
    count(*) FILTER (WHERE on_juhatuse_liige = true) AS juhatuse_liikme_read
FROM stage.rik_kaardile_kantud_isikud s
JOIN snapshot_quality_target p ON p.snapshot_date = s.snapshot_date;

SELECT
    isik_rows AS rows,
    null_roll,
    juhatuse_liikme_read
FROM snapshot_quality_rik_isikud;

DO $$
DECLARE
    v_snapshot_date date;
    v_has_mta boolean;
    v_has_rik boolean;
    v_raw_count bigint;
    v_stage_count bigint;
    v_bad_count bigint;
    v_juhatus_count bigint;
BEGIN
    SELECT snapshot_date INTO v_snapshot_date FROM snapshot_quality_target;
    SELECT EXISTS (
        SELECT 1 FROM raw.mta_maksuvolglased_csv WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_mta;
    SELECT EXISTS (
        SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_rik;

    IF NOT v_has_mta AND NOT v_has_rik THEN
        RAISE EXCEPTION 'Snapshoti % kohta ei ole RAW andmeid.', v_snapshot_date;
    END IF;

    IF v_has_mta THEN
        SELECT count(*) INTO v_raw_count
        FROM raw.mta_maksuvolglased_csv r
        JOIN snapshot_quality_mta_source m
          ON m.snapshot_date = r.snapshot_date
         AND m.source_file = r.source_file
         AND m.file_sha256 = r.file_sha256
        WHERE r.snapshot_date = v_snapshot_date;
        SELECT count(*) INTO v_stage_count
        FROM stage.mta_maksuvolglased WHERE snapshot_date = v_snapshot_date;
        IF v_raw_count <> v_stage_count THEN
            RAISE EXCEPTION 'MTA RAW/stage ridade arv ei klapi: raw=%, stage=%',
                v_raw_count, v_stage_count;
        END IF;
        SELECT count(*) INTO v_bad_count
        FROM stage.mta_maksuvolglased
        WHERE snapshot_date = v_snapshot_date
          AND (
              maksuvolg IS NULL
              OR maksuvolg < 0
              OR data_as_of IS NULL
              OR vanima_tasumata_noude_tasumise_tahtaeg IS NULL
          );
        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'MTA snapshoti teisenduskontrollis on vigaseid ridu: %', v_bad_count;
        END IF;
    END IF;

    IF v_has_rik THEN
        SELECT count(*) INTO v_raw_count
        FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = v_snapshot_date;
        SELECT count(*) INTO v_stage_count
        FROM stage.rik_ettevotted WHERE snapshot_date = v_snapshot_date;
        IF v_raw_count <> v_stage_count THEN
            RAISE EXCEPTION 'RIK RAW/stage ridade arv ei klapi: raw=%, stage=%',
                v_raw_count, v_stage_count;
        END IF;
        SELECT count(*) INTO v_bad_count
        FROM stage.rik_ettevotted
        WHERE snapshot_date = v_snapshot_date
          AND (registrikood IS NULL OR btrim(registrikood) = '');
        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'RIK ettevotete registrikood puudub: % rida', v_bad_count;
        END IF;
        SELECT count(*) INTO v_bad_count
        FROM (
            SELECT registrikood
            FROM stage.rik_ettevotted
            WHERE snapshot_date = v_snapshot_date
            GROUP BY registrikood
            HAVING count(*) > 1
        ) duplicates;
        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'RIK ettevotete duplikaatgruppe: %', v_bad_count;
        END IF;
        SELECT isik_rows, null_roll, juhatuse_liikme_read
        INTO v_stage_count, v_bad_count, v_juhatus_count
        FROM snapshot_quality_rik_isikud;
        IF v_stage_count = 0 THEN
            RAISE EXCEPTION 'RIK isikute stage on tuhi.';
        END IF;
        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'RIK isikute NULL roll: % rida', v_bad_count;
        END IF;
        IF v_juhatus_count = 0 THEN
            RAISE EXCEPTION 'RIK juhatuse liikmete ridu ei leitud.';
        END IF;
    END IF;
END;
$$;

DROP TABLE snapshot_quality_rik_isikud;
DROP TABLE snapshot_quality_mta_source;
DROP TABLE snapshot_quality_target;
