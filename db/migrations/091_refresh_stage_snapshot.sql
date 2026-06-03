\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TEMP TABLE stage_refresh_target ON COMMIT DROP AS
SELECT :'snapshot_date'::date AS snapshot_date;

CREATE TEMP TABLE stage_refresh_mta_source ON COMMIT DROP AS
WITH sources AS (
    SELECT
        r.snapshot_date,
        r.source_file,
        r.file_sha256,
        max(r.loaded_at) AS loaded_at,
        max(r.data_as_of) AS data_as_of,
        count(*) AS rows
    FROM raw.mta_maksuvolglased_csv r
    JOIN stage_refresh_target p ON p.snapshot_date = r.snapshot_date
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

\echo '=== Snapshotipohine stage refresh: sisendallikad ==='
SELECT
    p.snapshot_date,
    EXISTS (
        SELECT 1 FROM raw.mta_maksuvolglased_csv r
        WHERE r.snapshot_date = p.snapshot_date
    ) AS has_mta_raw,
    m.source_file AS selected_mta_source_file,
    m.data_as_of AS selected_mta_data_as_of,
    m.rows AS selected_mta_rows,
    EXISTS (
        SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json r
        WHERE r.snapshot_date = p.snapshot_date
    ) AS has_rik_raw
FROM stage_refresh_target p
LEFT JOIN stage_refresh_mta_source m ON m.snapshot_date = p.snapshot_date;

DO $$
DECLARE
    v_snapshot_date date;
    v_has_mta boolean;
    v_has_rik boolean;
BEGIN
    SELECT snapshot_date INTO v_snapshot_date FROM stage_refresh_target;
    SELECT EXISTS (
        SELECT 1 FROM raw.mta_maksuvolglased_csv WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_mta;
    SELECT EXISTS (
        SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_rik;

    IF NOT v_has_mta AND NOT v_has_rik THEN
        RAISE EXCEPTION 'Snapshoti % kohta ei ole MTA ega RIK RAW andmeid.', v_snapshot_date;
    END IF;
END;
$$;

DELETE FROM stage.rik_ettevotted s
USING stage_refresh_target p
WHERE s.snapshot_date = p.snapshot_date
  AND EXISTS (
      SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json r
      WHERE r.snapshot_date = p.snapshot_date
  );

INSERT INTO stage.rik_ettevotted (
    raw_id,
    snapshot_date,
    source_file,
    row_no,
    registrikood,
    nimi,
    oiguslik_vorm,
    staatus,
    loaded_at
)
SELECT
    r.id,
    r.snapshot_date,
    r.source_file,
    r.row_no,
    NULLIF(btrim(r.record->>'ariregistri_kood'), ''),
    NULLIF(btrim(r.record->>'nimi'), ''),
    NULL::text,
    NULL::text,
    r.loaded_at
FROM raw.rik_kaardile_kantud_isikud_json r
JOIN stage_refresh_target p ON p.snapshot_date = r.snapshot_date;

DELETE FROM stage.rik_kaardile_kantud_isikud s
USING stage_refresh_target p
WHERE s.snapshot_date = p.snapshot_date
  AND EXISTS (
      SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json r
      WHERE r.snapshot_date = p.snapshot_date
  );

INSERT INTO stage.rik_kaardile_kantud_isikud (
    raw_id,
    snapshot_date,
    source_file,
    row_no,
    registrikood,
    ettevotte_nimi,
    isik_nimi,
    isikukood,
    roll,
    rolli_alguskuupaev,
    on_juhatuse_liige,
    loaded_at
)
SELECT
    r.id,
    r.snapshot_date,
    r.source_file,
    r.row_no,
    NULLIF(btrim(r.record->>'ariregistri_kood'), ''),
    NULLIF(btrim(r.record->>'nimi'), ''),
    COALESCE(
        NULLIF(btrim(person.value->>'nimi'), ''),
        NULLIF(btrim(concat_ws(
            ' ',
            NULLIF(btrim(person.value->>'eesnimi'), ''),
            NULLIF(btrim(person.value->>'nimi_arinimi'), '')
        )), '')
    ),
    COALESCE(
        NULLIF(btrim(person.value->>'isikukood_registrikood'), ''),
        NULLIF(btrim(person.value->>'valis_kood'), ''),
        NULLIF(btrim(person.value->>'isikukood_hash'), '')
    ),
    values_from_json.roll,
    stage.parse_et_date(person.value->>'algus_kpv'),
    (
        upper(COALESCE(person.value->>'isiku_roll', '')) = 'JUHL'
        OR lower(COALESCE(values_from_json.roll, '')) LIKE '%juhatus%'
    ),
    r.loaded_at
FROM raw.rik_kaardile_kantud_isikud_json r
JOIN stage_refresh_target p ON p.snapshot_date = r.snapshot_date
CROSS JOIN LATERAL jsonb_array_elements(
    CASE
        WHEN jsonb_typeof(r.record->'kaardile_kantud_isikud') = 'array'
            THEN r.record->'kaardile_kantud_isikud'
        ELSE '[]'::jsonb
    END
) AS person(value)
CROSS JOIN LATERAL (
    SELECT COALESCE(
        NULLIF(btrim(person.value->>'isiku_roll_tekstina'), ''),
        NULLIF(btrim(person.value->>'isiku_roll'), '')
    ) AS roll
) AS values_from_json;

DELETE FROM stage.mta_maksuvolglased s
USING stage_refresh_target p
WHERE s.snapshot_date = p.snapshot_date
  AND EXISTS (
      SELECT 1 FROM raw.mta_maksuvolglased_csv r
      WHERE r.snapshot_date = p.snapshot_date
  );

WITH parsed AS (
    SELECT
        r.id AS raw_id,
        r.snapshot_date,
        COALESCE(r.data_as_of, stage.parse_et_date(r.andmed_on_seisuga)) AS data_as_of,
        r.source_file,
        r.file_sha256,
        r.row_no,
        NULLIF(btrim(r.registrikood), '') AS registrikood,
        NULLIF(btrim(r.nimi), '') AS nimi,
        stage.parse_et_numeric(r.maksuvolg) AS maksuvolg,
        stage.parse_et_numeric(r.sh_vaidlustatud) AS sh_vaidlustatud,
        stage.parse_et_numeric(r.sh_tasumisgraafikus) AS sh_tasumisgraafikus,
        stage.parse_et_date(r.tasumisgraafiku_loppkuupaev) AS tasumisgraafiku_loppkuupaev,
        stage.parse_et_date(r.vanima_tasumata_noude_tasumise_tahtaeg)
            AS vanima_tasumata_noude_tasumise_tahtaeg,
        r.loaded_at
    FROM raw.mta_maksuvolglased_csv r
    JOIN stage_refresh_mta_source p
      ON p.snapshot_date = r.snapshot_date
     AND p.source_file = r.source_file
     AND p.file_sha256 = r.file_sha256
),
aged AS (
    SELECT
        p.*,
        CASE
            WHEN p.data_as_of IS NULL
              OR p.vanima_tasumata_noude_tasumise_tahtaeg IS NULL THEN NULL
            ELSE p.data_as_of - p.vanima_tasumata_noude_tasumise_tahtaeg
        END AS volg_vanus_paevades
    FROM parsed p
)
INSERT INTO stage.mta_maksuvolglased (
    raw_id,
    snapshot_date,
    data_as_of,
    source_file,
    file_sha256,
    row_no,
    registrikood,
    nimi,
    maksuvolg,
    sh_vaidlustatud,
    sh_tasumisgraafikus,
    tasumisgraafiku_loppkuupaev,
    vanima_tasumata_noude_tasumise_tahtaeg,
    volg_vanus_paevades,
    volg_vanuse_grupp,
    loaded_at
)
SELECT
    a.raw_id,
    a.snapshot_date,
    a.data_as_of,
    a.source_file,
    a.file_sha256,
    a.row_no,
    a.registrikood,
    a.nimi,
    a.maksuvolg,
    a.sh_vaidlustatud,
    a.sh_tasumisgraafikus,
    a.tasumisgraafiku_loppkuupaev,
    a.vanima_tasumata_noude_tasumise_tahtaeg,
    a.volg_vanus_paevades,
    CASE
        WHEN a.volg_vanus_paevades IS NULL OR a.volg_vanus_paevades < 1 THEN 'teadmata'
        WHEN a.volg_vanus_paevades BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
        WHEN a.volg_vanus_paevades BETWEEN 60 AND 179 THEN '2-5 kuud'
        WHEN a.volg_vanus_paevades BETWEEN 180 AND 364 THEN '6-11 kuud'
        ELSE '>= 1 aasta'
    END AS volg_vanuse_grupp,
    a.loaded_at
FROM aged a;

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
    SELECT snapshot_date INTO v_snapshot_date FROM stage_refresh_target;
    SELECT EXISTS (
        SELECT 1 FROM raw.mta_maksuvolglased_csv WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_mta;
    SELECT EXISTS (
        SELECT 1 FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = v_snapshot_date
    ) INTO v_has_rik;

    IF v_has_mta THEN
        SELECT count(*) INTO v_raw_count
        FROM raw.mta_maksuvolglased_csv r
        JOIN stage_refresh_mta_source m
          ON m.snapshot_date = r.snapshot_date
         AND m.source_file = r.source_file
         AND m.file_sha256 = r.file_sha256
        WHERE r.snapshot_date = v_snapshot_date;
        SELECT count(*) INTO v_stage_count
        FROM stage.mta_maksuvolglased WHERE snapshot_date = v_snapshot_date;
        IF v_raw_count <> v_stage_count THEN
            RAISE EXCEPTION 'MTA RAW/stage ridade arv ei klapi snapshotil %: raw=%, stage=%',
                v_snapshot_date, v_raw_count, v_stage_count;
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
            RAISE EXCEPTION 'MTA teisenduskontroll ebaonnestus snapshotil %: vigaseid ridu=%',
                v_snapshot_date, v_bad_count;
        END IF;
    END IF;

    IF v_has_rik THEN
        SELECT count(*) INTO v_raw_count
        FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = v_snapshot_date;
        SELECT count(*) INTO v_stage_count
        FROM stage.rik_ettevotted WHERE snapshot_date = v_snapshot_date;
        IF v_raw_count <> v_stage_count THEN
            RAISE EXCEPTION 'RIK RAW/ettevotete stage ridade arv ei klapi snapshotil %: raw=%, stage=%',
                v_snapshot_date, v_raw_count, v_stage_count;
        END IF;

        SELECT count(*) INTO v_bad_count
        FROM stage.rik_ettevotted
        WHERE snapshot_date = v_snapshot_date
          AND (registrikood IS NULL OR btrim(registrikood) = '');
        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'RIK ettevotete registrikoodi kontroll ebaonnestus snapshotil %: vigaseid ridu=%',
                v_snapshot_date, v_bad_count;
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
            RAISE EXCEPTION 'RIK ettevotete duplikaadikontroll ebaonnestus snapshotil %: grupid=%',
                v_snapshot_date, v_bad_count;
        END IF;

        SELECT
            count(*),
            count(*) FILTER (WHERE roll IS NULL),
            count(*) FILTER (WHERE on_juhatuse_liige = true)
        INTO v_stage_count, v_bad_count, v_juhatus_count
        FROM stage.rik_kaardile_kantud_isikud
        WHERE snapshot_date = v_snapshot_date;
        IF v_stage_count = 0 THEN
            RAISE EXCEPTION 'RIK isikute stage on tuhi snapshotil %.', v_snapshot_date;
        END IF;

        IF v_bad_count <> 0 THEN
            RAISE EXCEPTION 'RIK isikute rolli kontroll ebaonnestus snapshotil %: NULL ridu=%',
                v_snapshot_date, v_bad_count;
        END IF;

        IF v_juhatus_count = 0 THEN
            RAISE EXCEPTION 'RIK juhatuse liikmete kontroll ebaonnestus snapshotil %.', v_snapshot_date;
        END IF;
    END IF;
END;
$$;

COMMIT;
