BEGIN;

TRUNCATE TABLE
    stage.mta_maksuvolglased,
    stage.rik_ettevotted,
    stage.rik_kaardile_kantud_isikud
RESTART IDENTITY;

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
parsed AS (
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
    JOIN latest_mta_sources latest
      ON latest.snapshot_date = r.snapshot_date
     AND latest.source_file = r.source_file
     AND latest.file_sha256 = r.file_sha256
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
FROM raw.rik_kaardile_kantud_isikud_json r;

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

COMMIT;
