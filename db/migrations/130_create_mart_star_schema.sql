\set ON_ERROR_STOP on
\pset pager off

-- MART_STAR grain:
-- one fact row = one company for one MTA snapshot_date.
-- Board-change flags are calculated directly from STAGE RIK board-member snapshots:
-- for every MTA date D, compare RIK board members on D with RIK board members on D - 1.

BEGIN;

CREATE SCHEMA IF NOT EXISTS mart_star;

CREATE TABLE IF NOT EXISTS mart_star.dim_aeg (
    kuupaev date PRIMARY KEY,
    paev integer NOT NULL,
    kuu integer NOT NULL,
    aasta integer NOT NULL,
    kvartal integer NOT NULL,
    nadal integer NOT NULL,
    kuu_nimi text NOT NULL,
    paeva_nimi text NOT NULL,
    is_weekend boolean NOT NULL
);

CREATE TABLE IF NOT EXISTS mart_star.dim_vanuse_grupp (
    maksuvola_vanuse_grupp text PRIMARY KEY,
    min_paevi integer,
    max_paevi integer,
    jarjestus integer NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS mart_star.dim_ettevote (
    ettevote_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registrikood text NOT NULL UNIQUE,
    nimi text,
    mta_nimi text,
    rik_nimi text,
    oiguslik_vorm text,
    staatus text,
    leitud_rikist boolean NOT NULL DEFAULT false,
    latest_mta_snapshot_date date,
    latest_mta_data_as_of date,
    latest_rik_snapshot_date date,
    created_at timestamp without time zone NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS mart_star.juhatuse_muutus_paeviti (
    mta_kuupaev date NOT NULL,
    registrikood text NOT NULL,
    rik_snapshot_date date,
    previous_rik_snapshot_date date,
    juhatuse_muutuse_fakt boolean NOT NULL DEFAULT false,
    lisatud_juhatuse_liikmeid integer NOT NULL DEFAULT 0 CHECK (lisatud_juhatuse_liikmeid >= 0),
    eemaldatud_juhatuse_liikmeid integer NOT NULL DEFAULT 0 CHECK (eemaldatud_juhatuse_liikmeid >= 0),
    praegune_juhatuse_liikmete_arv integer NOT NULL DEFAULT 0 CHECK (praegune_juhatuse_liikmete_arv >= 0),
    eelmine_juhatuse_liikmete_arv integer NOT NULL DEFAULT 0 CHECK (eelmine_juhatuse_liikmete_arv >= 0),
    rik_vordlus_olemas boolean NOT NULL DEFAULT false,
    created_at timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT pk_juhatuse_muutus_paeviti PRIMARY KEY (mta_kuupaev, registrikood)
);

CREATE OR REPLACE VIEW mart_star.v_juhatuse_muutus_paeviti AS
SELECT
    mta_kuupaev,
    registrikood,
    rik_snapshot_date,
    previous_rik_snapshot_date,
    juhatuse_muutuse_fakt,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv,
    rik_vordlus_olemas
FROM mart_star.juhatuse_muutus_paeviti;

CREATE TABLE IF NOT EXISTS mart_star.fact_maksuvolg (
    fact_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dim_ettevote_id bigint NOT NULL REFERENCES mart_star.dim_ettevote(ettevote_id),
    kuupaev date NOT NULL REFERENCES mart_star.dim_aeg(kuupaev),
    maksuvola_summa numeric(18,2) NOT NULL CHECK (maksuvola_summa >= 0),
    maksuvola_vanuse_grupp text NOT NULL REFERENCES mart_star.dim_vanuse_grupp(maksuvola_vanuse_grupp),
    juhatuse_muutuse_fakt boolean NOT NULL DEFAULT false,
    mta_snapshot_date date NOT NULL,
    mta_data_as_of date NOT NULL,
    rik_snapshot_date date,
    previous_rik_snapshot_date date,
    registrikood text NOT NULL,
    vaidlustatud_summa numeric(18,2) NOT NULL DEFAULT 0 CHECK (vaidlustatud_summa >= 0),
    tasumisgraafikus_summa numeric(18,2) NOT NULL DEFAULT 0 CHECK (tasumisgraafikus_summa >= 0),
    volg_vanus_paevades integer,
    lisatud_juhatuse_liikmeid integer NOT NULL DEFAULT 0 CHECK (lisatud_juhatuse_liikmeid >= 0),
    eemaldatud_juhatuse_liikmeid integer NOT NULL DEFAULT 0 CHECK (eemaldatud_juhatuse_liikmeid >= 0),
    praegune_juhatuse_liikmete_arv integer CHECK (praegune_juhatuse_liikmete_arv IS NULL OR praegune_juhatuse_liikmete_arv >= 0),
    eelmine_juhatuse_liikmete_arv integer CHECK (eelmine_juhatuse_liikmete_arv IS NULL OR eelmine_juhatuse_liikmete_arv >= 0),
    leitud_rikist boolean NOT NULL DEFAULT false,
    created_at timestamp without time zone NOT NULL DEFAULT now(),
    CONSTRAINT uq_fact_maksuvolg_ettevote_kuupaev UNIQUE (dim_ettevote_id, kuupaev)
);

TRUNCATE TABLE
    mart_star.fact_maksuvolg,
    mart_star.juhatuse_muutus_paeviti,
    mart_star.dim_ettevote,
    mart_star.dim_aeg,
    mart_star.dim_vanuse_grupp
RESTART IDENTITY CASCADE;

INSERT INTO mart_star.dim_vanuse_grupp (
    maksuvola_vanuse_grupp,
    min_paevi,
    max_paevi,
    jarjestus
)
VALUES
    ('kuni 2 kuud', 1, 59, 1),
    ('2-5 kuud', 60, 179, 2),
    ('6-11 kuud', 180, 364, 3),
    ('>= 1 aasta', 365, NULL, 4);

INSERT INTO mart_star.dim_aeg (
    kuupaev,
    paev,
    kuu,
    aasta,
    kvartal,
    nadal,
    kuu_nimi,
    paeva_nimi,
    is_weekend
)
WITH date_bounds AS (
    SELECT
        min(kuupaev) AS min_kuupaev,
        max(kuupaev) AS max_kuupaev
    FROM (
        SELECT snapshot_date AS kuupaev FROM stage.mta_maksuvolglased
        UNION
        SELECT data_as_of AS kuupaev FROM stage.mta_maksuvolglased
        UNION
        SELECT snapshot_date AS kuupaev FROM stage.rik_ettevotted
        UNION
        SELECT snapshot_date AS kuupaev FROM stage.rik_kaardile_kantud_isikud
    ) d
    WHERE kuupaev IS NOT NULL
)
SELECT
    gs.kuupaev::date,
    extract(day FROM gs.kuupaev)::integer AS paev,
    extract(month FROM gs.kuupaev)::integer AS kuu,
    extract(year FROM gs.kuupaev)::integer AS aasta,
    extract(quarter FROM gs.kuupaev)::integer AS kvartal,
    extract(week FROM gs.kuupaev)::integer AS nadal,
    to_char(gs.kuupaev, 'TMMonth') AS kuu_nimi,
    to_char(gs.kuupaev, 'TMDay') AS paeva_nimi,
    extract(isodow FROM gs.kuupaev)::integer IN (6, 7) AS is_weekend
FROM date_bounds b
CROSS JOIN LATERAL generate_series(b.min_kuupaev, b.max_kuupaev, interval '1 day') AS gs(kuupaev)
WHERE b.min_kuupaev IS NOT NULL
  AND b.max_kuupaev IS NOT NULL;

CREATE TEMP TABLE mart_star_mta_company_dates_tmp ON COMMIT DROP AS
SELECT
    NULLIF(btrim(m.registrikood), '') AS registrikood,
    m.snapshot_date AS mta_snapshot_date,
    m.data_as_of AS mta_data_as_of,
    (array_agg(NULLIF(btrim(m.nimi), '') ORDER BY COALESCE(m.maksuvolg, 0) DESC, m.row_no DESC)
        FILTER (WHERE NULLIF(btrim(m.nimi), '') IS NOT NULL))[1] AS mta_nimi,
    COALESCE(sum(COALESCE(m.maksuvolg, 0)), 0)::numeric(18,2) AS maksuvola_summa,
    COALESCE(sum(COALESCE(m.sh_vaidlustatud, 0)), 0)::numeric(18,2) AS vaidlustatud_summa,
    COALESCE(sum(COALESCE(m.sh_tasumisgraafikus, 0)), 0)::numeric(18,2) AS tasumisgraafikus_summa,
    max(m.volg_vanus_paevades) AS volg_vanus_paevades
FROM stage.mta_maksuvolglased m
WHERE NULLIF(btrim(m.registrikood), '') IS NOT NULL
GROUP BY
    NULLIF(btrim(m.registrikood), ''),
    m.snapshot_date,
    m.data_as_of;

CREATE INDEX mart_star_mta_company_dates_reg_idx ON mart_star_mta_company_dates_tmp(registrikood);
CREATE INDEX mart_star_mta_company_dates_date_reg_idx ON mart_star_mta_company_dates_tmp(mta_snapshot_date, registrikood);

INSERT INTO mart_star.dim_ettevote (
    registrikood,
    nimi,
    mta_nimi,
    rik_nimi,
    oiguslik_vorm,
    staatus,
    leitud_rikist,
    latest_mta_snapshot_date,
    latest_mta_data_as_of,
    latest_rik_snapshot_date
)
WITH latest_rik_snapshot AS (
    SELECT max(snapshot_date) AS snapshot_date
    FROM stage.rik_ettevotted
),
latest_mta_name_by_company AS (
    SELECT DISTINCT ON (registrikood)
        registrikood,
        mta_nimi,
        mta_snapshot_date AS latest_mta_snapshot_date,
        mta_data_as_of AS latest_mta_data_as_of
    FROM mart_star_mta_company_dates_tmp
    ORDER BY
        registrikood,
        mta_snapshot_date DESC,
        mta_data_as_of DESC,
        maksuvola_summa DESC
),
rik_latest AS (
    SELECT DISTINCT ON (NULLIF(btrim(registrikood), ''))
        NULLIF(btrim(registrikood), '') AS registrikood,
        NULLIF(btrim(nimi), '') AS rik_nimi,
        NULLIF(btrim(oiguslik_vorm), '') AS oiguslik_vorm,
        NULLIF(btrim(staatus), '') AS staatus
    FROM stage.rik_ettevotted
    WHERE snapshot_date = (SELECT snapshot_date FROM latest_rik_snapshot)
      AND NULLIF(btrim(registrikood), '') IS NOT NULL
    ORDER BY NULLIF(btrim(registrikood), ''), row_no DESC
)
SELECT
    m.registrikood,
    COALESCE(r.rik_nimi, m.mta_nimi) AS nimi,
    m.mta_nimi,
    r.rik_nimi,
    r.oiguslik_vorm,
    r.staatus,
    (r.registrikood IS NOT NULL) AS leitud_rikist,
    m.latest_mta_snapshot_date,
    m.latest_mta_data_as_of,
    (SELECT snapshot_date FROM latest_rik_snapshot) AS latest_rik_snapshot_date
FROM latest_mta_name_by_company m
LEFT JOIN rik_latest r ON r.registrikood = m.registrikood;

CREATE TEMP TABLE mart_star_mta_dates_tmp ON COMMIT DROP AS
WITH mta_dates AS (
    SELECT DISTINCT mta_snapshot_date AS mta_kuupaev
    FROM mart_star_mta_company_dates_tmp
),
rik_dates AS (
    SELECT DISTINCT snapshot_date AS rik_kuupaev
    FROM stage.rik_kaardile_kantud_isikud
)
SELECT
    m.mta_kuupaev,
    (d.rik_kuupaev IS NOT NULL) AS has_rik_same_day,
    (p.rik_kuupaev IS NOT NULL) AS has_rik_previous_day,
    (d.rik_kuupaev IS NOT NULL AND p.rik_kuupaev IS NOT NULL) AS rik_vordlus_olemas
FROM mta_dates m
LEFT JOIN rik_dates d ON d.rik_kuupaev = m.mta_kuupaev
LEFT JOIN rik_dates p ON p.rik_kuupaev = m.mta_kuupaev - interval '1 day';

CREATE INDEX mart_star_mta_dates_date_idx ON mart_star_mta_dates_tmp(mta_kuupaev);

CREATE TEMP TABLE mart_star_mta_companies_tmp ON COMMIT DROP AS
SELECT DISTINCT registrikood
FROM mart_star_mta_company_dates_tmp;

CREATE INDEX mart_star_mta_companies_reg_idx ON mart_star_mta_companies_tmp(registrikood);

CREATE TEMP TABLE mart_star_needed_rik_dates_tmp ON COMMIT DROP AS
SELECT mta_kuupaev AS snapshot_date
FROM mart_star_mta_dates_tmp
UNION
SELECT (mta_kuupaev - interval '1 day')::date AS snapshot_date
FROM mart_star_mta_dates_tmp;

CREATE INDEX mart_star_needed_rik_dates_date_idx ON mart_star_needed_rik_dates_tmp(snapshot_date);

CREATE TEMP TABLE mart_star_board_members_tmp ON COMMIT DROP AS
SELECT DISTINCT
    i.snapshot_date,
    NULLIF(btrim(i.registrikood), '') AS registrikood,
    COALESCE(
        NULLIF(btrim(i.isikukood), ''),
        'NAME:' || lower(COALESCE(NULLIF(btrim(i.isik_nimi), ''), '')) ||
        '|ROLE:' || COALESCE(NULLIF(btrim(i.roll), ''), '') ||
        '|START:' || COALESCE(i.rolli_alguskuupaev::text, '')
    ) AS isik_key
FROM stage.rik_kaardile_kantud_isikud i
JOIN mart_star_needed_rik_dates_tmp d ON d.snapshot_date = i.snapshot_date
JOIN mart_star_mta_companies_tmp c ON c.registrikood = NULLIF(btrim(i.registrikood), '')
WHERE i.on_juhatuse_liige = true
  AND NULLIF(btrim(i.registrikood), '') IS NOT NULL;

CREATE INDEX mart_star_board_members_date_reg_key_idx
    ON mart_star_board_members_tmp(snapshot_date, registrikood, isik_key);

CREATE TEMP TABLE mart_star_current_board_tmp ON COMMIT DROP AS
SELECT
    d.mta_kuupaev,
    b.registrikood,
    b.isik_key
FROM mart_star_mta_dates_tmp d
JOIN mart_star_board_members_tmp b ON b.snapshot_date = d.mta_kuupaev
WHERE d.rik_vordlus_olemas = true;

CREATE TEMP TABLE mart_star_previous_board_tmp ON COMMIT DROP AS
SELECT
    d.mta_kuupaev,
    b.registrikood,
    b.isik_key
FROM mart_star_mta_dates_tmp d
JOIN mart_star_board_members_tmp b ON b.snapshot_date = d.mta_kuupaev - interval '1 day'
WHERE d.rik_vordlus_olemas = true;

CREATE INDEX mart_star_current_board_date_reg_key_idx
    ON mart_star_current_board_tmp(mta_kuupaev, registrikood, isik_key);
CREATE INDEX mart_star_previous_board_date_reg_key_idx
    ON mart_star_previous_board_tmp(mta_kuupaev, registrikood, isik_key);

CREATE TEMP TABLE mart_star_added_board_tmp ON COMMIT DROP AS
SELECT
    c.mta_kuupaev,
    c.registrikood,
    count(*)::integer AS lisatud_juhatuse_liikmeid
FROM mart_star_current_board_tmp c
LEFT JOIN mart_star_previous_board_tmp p
       ON p.mta_kuupaev = c.mta_kuupaev
      AND p.registrikood = c.registrikood
      AND p.isik_key = c.isik_key
WHERE p.isik_key IS NULL
GROUP BY c.mta_kuupaev, c.registrikood;

CREATE TEMP TABLE mart_star_removed_board_tmp ON COMMIT DROP AS
SELECT
    p.mta_kuupaev,
    p.registrikood,
    count(*)::integer AS eemaldatud_juhatuse_liikmeid
FROM mart_star_previous_board_tmp p
LEFT JOIN mart_star_current_board_tmp c
       ON c.mta_kuupaev = p.mta_kuupaev
      AND c.registrikood = p.registrikood
      AND c.isik_key = p.isik_key
WHERE c.isik_key IS NULL
GROUP BY p.mta_kuupaev, p.registrikood;

CREATE TEMP TABLE mart_star_current_board_counts_tmp ON COMMIT DROP AS
SELECT
    mta_kuupaev,
    registrikood,
    count(*)::integer AS praegune_juhatuse_liikmete_arv
FROM mart_star_current_board_tmp
GROUP BY mta_kuupaev, registrikood;

CREATE TEMP TABLE mart_star_previous_board_counts_tmp ON COMMIT DROP AS
SELECT
    mta_kuupaev,
    registrikood,
    count(*)::integer AS eelmine_juhatuse_liikmete_arv
FROM mart_star_previous_board_tmp
GROUP BY mta_kuupaev, registrikood;

CREATE INDEX mart_star_added_board_date_reg_idx ON mart_star_added_board_tmp(mta_kuupaev, registrikood);
CREATE INDEX mart_star_removed_board_date_reg_idx ON mart_star_removed_board_tmp(mta_kuupaev, registrikood);
CREATE INDEX mart_star_current_board_counts_date_reg_idx ON mart_star_current_board_counts_tmp(mta_kuupaev, registrikood);
CREATE INDEX mart_star_previous_board_counts_date_reg_idx ON mart_star_previous_board_counts_tmp(mta_kuupaev, registrikood);

INSERT INTO mart_star.juhatuse_muutus_paeviti (
    mta_kuupaev,
    registrikood,
    rik_snapshot_date,
    previous_rik_snapshot_date,
    juhatuse_muutuse_fakt,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv,
    rik_vordlus_olemas
)
SELECT
    m.mta_snapshot_date AS mta_kuupaev,
    m.registrikood,
    CASE WHEN d.has_rik_same_day THEN m.mta_snapshot_date ELSE NULL END AS rik_snapshot_date,
    CASE WHEN d.has_rik_previous_day THEN (m.mta_snapshot_date - interval '1 day')::date ELSE NULL END AS previous_rik_snapshot_date,
    CASE
        WHEN d.rik_vordlus_olemas = true THEN
            COALESCE(a.lisatud_juhatuse_liikmeid, 0) > 0
            OR COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) > 0
        ELSE false
    END AS juhatuse_muutuse_fakt,
    COALESCE(a.lisatud_juhatuse_liikmeid, 0) AS lisatud_juhatuse_liikmeid,
    COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) AS eemaldatud_juhatuse_liikmeid,
    COALESCE(cc.praegune_juhatuse_liikmete_arv, 0) AS praegune_juhatuse_liikmete_arv,
    COALESCE(pc.eelmine_juhatuse_liikmete_arv, 0) AS eelmine_juhatuse_liikmete_arv,
    d.rik_vordlus_olemas
FROM mart_star_mta_company_dates_tmp m
JOIN mart_star_mta_dates_tmp d ON d.mta_kuupaev = m.mta_snapshot_date
LEFT JOIN mart_star_added_board_tmp a
       ON a.mta_kuupaev = m.mta_snapshot_date
      AND a.registrikood = m.registrikood
LEFT JOIN mart_star_removed_board_tmp r
       ON r.mta_kuupaev = m.mta_snapshot_date
      AND r.registrikood = m.registrikood
LEFT JOIN mart_star_current_board_counts_tmp cc
       ON cc.mta_kuupaev = m.mta_snapshot_date
      AND cc.registrikood = m.registrikood
LEFT JOIN mart_star_previous_board_counts_tmp pc
       ON pc.mta_kuupaev = m.mta_snapshot_date
      AND pc.registrikood = m.registrikood;

CREATE TEMP TABLE mart_star_rik_company_dates_tmp ON COMMIT DROP AS
SELECT DISTINCT
    r.snapshot_date AS mta_kuupaev,
    NULLIF(btrim(r.registrikood), '') AS registrikood
FROM stage.rik_ettevotted r
JOIN mart_star_mta_dates_tmp d ON d.mta_kuupaev = r.snapshot_date
JOIN mart_star_mta_companies_tmp c ON c.registrikood = NULLIF(btrim(r.registrikood), '')
WHERE NULLIF(btrim(r.registrikood), '') IS NOT NULL;

CREATE INDEX mart_star_rik_company_dates_date_reg_idx
    ON mart_star_rik_company_dates_tmp(mta_kuupaev, registrikood);

INSERT INTO mart_star.fact_maksuvolg (
    dim_ettevote_id,
    kuupaev,
    maksuvola_summa,
    maksuvola_vanuse_grupp,
    juhatuse_muutuse_fakt,
    mta_snapshot_date,
    mta_data_as_of,
    rik_snapshot_date,
    previous_rik_snapshot_date,
    registrikood,
    vaidlustatud_summa,
    tasumisgraafikus_summa,
    volg_vanus_paevades,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv,
    leitud_rikist
)
SELECT
    e.ettevote_id AS dim_ettevote_id,
    m.mta_snapshot_date AS kuupaev,
    m.maksuvola_summa,
    CASE
        WHEN m.volg_vanus_paevades BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
        WHEN m.volg_vanus_paevades BETWEEN 60 AND 179 THEN '2-5 kuud'
        WHEN m.volg_vanus_paevades BETWEEN 180 AND 364 THEN '6-11 kuud'
        WHEN m.volg_vanus_paevades >= 365 THEN '>= 1 aasta'
        ELSE NULL
    END AS maksuvola_vanuse_grupp,
    COALESCE(jm.juhatuse_muutuse_fakt, false) AS juhatuse_muutuse_fakt,
    m.mta_snapshot_date,
    m.mta_data_as_of,
    jm.rik_snapshot_date,
    jm.previous_rik_snapshot_date,
    m.registrikood,
    m.vaidlustatud_summa,
    m.tasumisgraafikus_summa,
    m.volg_vanus_paevades,
    COALESCE(jm.lisatud_juhatuse_liikmeid, 0)::integer AS lisatud_juhatuse_liikmeid,
    COALESCE(jm.eemaldatud_juhatuse_liikmeid, 0)::integer AS eemaldatud_juhatuse_liikmeid,
    COALESCE(jm.praegune_juhatuse_liikmete_arv, 0)::integer AS praegune_juhatuse_liikmete_arv,
    COALESCE(jm.eelmine_juhatuse_liikmete_arv, 0)::integer AS eelmine_juhatuse_liikmete_arv,
    (r.registrikood IS NOT NULL) AS leitud_rikist
FROM mart_star_mta_company_dates_tmp m
JOIN mart_star.dim_ettevote e ON e.registrikood = m.registrikood
LEFT JOIN mart_star.juhatuse_muutus_paeviti jm
       ON jm.mta_kuupaev = m.mta_snapshot_date
      AND jm.registrikood = m.registrikood
LEFT JOIN mart_star_rik_company_dates_tmp r
       ON r.mta_kuupaev = m.mta_snapshot_date
      AND r.registrikood = m.registrikood;

CREATE INDEX IF NOT EXISTS idx_mart_star_fact_ettevote
    ON mart_star.fact_maksuvolg(dim_ettevote_id);
CREATE INDEX IF NOT EXISTS idx_mart_star_fact_kuupaev
    ON mart_star.fact_maksuvolg(kuupaev);
CREATE INDEX IF NOT EXISTS idx_mart_star_fact_vanuse_grupp
    ON mart_star.fact_maksuvolg(maksuvola_vanuse_grupp);
CREATE INDEX IF NOT EXISTS idx_mart_star_fact_juhatuse_muutus
    ON mart_star.fact_maksuvolg(juhatuse_muutuse_fakt);
CREATE INDEX IF NOT EXISTS idx_mart_star_dim_ettevote_registrikood
    ON mart_star.dim_ettevote(registrikood);
CREATE INDEX IF NOT EXISTS idx_mart_star_juhatus_kuupaev
    ON mart_star.juhatuse_muutus_paeviti(mta_kuupaev);
CREATE INDEX IF NOT EXISTS idx_mart_star_juhatus_muutus
    ON mart_star.juhatuse_muutus_paeviti(juhatuse_muutuse_fakt);
CREATE INDEX IF NOT EXISTS idx_mart_star_juhatus_vordlus
    ON mart_star.juhatuse_muutus_paeviti(rik_vordlus_olemas);

ANALYZE mart_star.dim_aeg;
ANALYZE mart_star.dim_vanuse_grupp;
ANALYZE mart_star.dim_ettevote;
ANALYZE mart_star.juhatuse_muutus_paeviti;
ANALYZE mart_star.fact_maksuvolg;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_readonly') THEN
        GRANT USAGE ON SCHEMA mart_star TO superset_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA mart_star TO superset_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA mart_star
            GRANT SELECT ON TABLES TO superset_readonly;
    END IF;
END;
$$;

COMMIT;
