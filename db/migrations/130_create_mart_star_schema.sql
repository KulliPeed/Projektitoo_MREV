\set ON_ERROR_STOP on
\pset pager off

-- MART_STAR grain:
-- one fact row = one company for one MTA data_as_of date,
-- using the latest available MTA snapshot for each data_as_of date.
-- Source rows are aggregated by registrikood inside each selected snapshot.

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
WITH selected_mta_snapshots AS (
    SELECT
        data_as_of,
        max(snapshot_date) AS snapshot_date
    FROM stage.mta_maksuvolglased
    WHERE data_as_of IS NOT NULL
    GROUP BY data_as_of
),
latest_rik_snapshot AS (
    SELECT max(snapshot_date) AS snapshot_date
    FROM stage.rik_ettevotted
),
selected_mta_rows AS (
    SELECT
        NULLIF(btrim(m.registrikood), '') AS registrikood,
        NULLIF(btrim(m.nimi), '') AS nimi,
        COALESCE(m.maksuvolg, 0) AS maksuvolg,
        m.snapshot_date,
        m.data_as_of,
        m.row_no
    FROM stage.mta_maksuvolglased m
    JOIN selected_mta_snapshots s
      ON s.data_as_of = m.data_as_of
     AND s.snapshot_date = m.snapshot_date
),
latest_mta_name_by_company AS (
    SELECT DISTINCT ON (registrikood)
        registrikood,
        nimi AS mta_nimi,
        snapshot_date AS latest_mta_snapshot_date,
        data_as_of AS latest_mta_data_as_of
    FROM selected_mta_rows
    WHERE registrikood IS NOT NULL
    ORDER BY
        registrikood,
        data_as_of DESC,
        snapshot_date DESC,
        maksuvolg DESC NULLS LAST,
        row_no DESC
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
WITH selected_mta_snapshots AS (
    SELECT
        data_as_of,
        max(snapshot_date) AS snapshot_date
    FROM stage.mta_maksuvolglased
    WHERE data_as_of IS NOT NULL
    GROUP BY data_as_of
),
latest_mta_rows AS (
    SELECT
        NULLIF(btrim(m.registrikood), '') AS registrikood,
        m.snapshot_date,
        m.data_as_of,
        COALESCE(m.maksuvolg, 0) AS maksuvolg,
        COALESCE(m.sh_vaidlustatud, 0) AS sh_vaidlustatud,
        COALESCE(m.sh_tasumisgraafikus, 0) AS sh_tasumisgraafikus,
        m.volg_vanus_paevades
    FROM stage.mta_maksuvolglased m
    JOIN selected_mta_snapshots s
      ON s.data_as_of = m.data_as_of
     AND s.snapshot_date = m.snapshot_date
),
mta_by_company AS (
    SELECT
        registrikood,
        max(snapshot_date) AS mta_snapshot_date,
        data_as_of AS mta_data_as_of,
        COALESCE(sum(maksuvolg), 0)::numeric(18,2) AS maksuvola_summa,
        COALESCE(sum(sh_vaidlustatud), 0)::numeric(18,2) AS vaidlustatud_summa,
        COALESCE(sum(sh_tasumisgraafikus), 0)::numeric(18,2) AS tasumisgraafikus_summa,
        max(volg_vanus_paevades) AS volg_vanus_paevades
    FROM latest_mta_rows
    WHERE registrikood IS NOT NULL
    GROUP BY registrikood, data_as_of
),
mta_with_group AS (
    SELECT
        *,
        CASE
            WHEN volg_vanus_paevades BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
            WHEN volg_vanus_paevades BETWEEN 60 AND 179 THEN '2-5 kuud'
            WHEN volg_vanus_paevades BETWEEN 180 AND 364 THEN '6-11 kuud'
            WHEN volg_vanus_paevades >= 365 THEN '>= 1 aasta'
            ELSE NULL
        END AS maksuvola_vanuse_grupp
    FROM mta_by_company
),
latest_dates AS (
    SELECT
        latest_rik_snapshot_date,
        previous_rik_snapshot_date
    FROM mart.v_latest_dates
),
rik_latest AS (
    SELECT DISTINCT
        NULLIF(btrim(r.registrikood), '') AS registrikood
    FROM stage.rik_ettevotted r
    JOIN latest_dates d ON d.latest_rik_snapshot_date = r.snapshot_date
    WHERE NULLIF(btrim(r.registrikood), '') IS NOT NULL
)
SELECT
    e.ettevote_id AS dim_ettevote_id,
    m.mta_data_as_of AS kuupaev,
    m.maksuvola_summa,
    m.maksuvola_vanuse_grupp,
    COALESCE(j.juhatus_muutus, false) AS juhatuse_muutuse_fakt,
    m.mta_snapshot_date,
    m.mta_data_as_of,
    d.latest_rik_snapshot_date AS rik_snapshot_date,
    d.previous_rik_snapshot_date,
    m.registrikood,
    m.vaidlustatud_summa,
    m.tasumisgraafikus_summa,
    m.volg_vanus_paevades,
    COALESCE(j.lisatud_juhatuse_liikmeid, 0)::integer AS lisatud_juhatuse_liikmeid,
    COALESCE(j.eemaldatud_juhatuse_liikmeid, 0)::integer AS eemaldatud_juhatuse_liikmeid,
    COALESCE(j.praegune_juhatuse_liikmete_arv, 0)::integer AS praegune_juhatuse_liikmete_arv,
    COALESCE(j.eelmine_juhatuse_liikmete_arv, 0)::integer AS eelmine_juhatuse_liikmete_arv,
    (r.registrikood IS NOT NULL) AS leitud_rikist
FROM mta_with_group m
JOIN mart_star.dim_ettevote e ON e.registrikood = m.registrikood
CROSS JOIN latest_dates d
LEFT JOIN mart.v_juhatuse_muutused_viimane_paev j
       ON j.rik_snapshot_date = d.latest_rik_snapshot_date
      AND j.registrikood = m.registrikood
LEFT JOIN rik_latest r ON r.registrikood = m.registrikood;

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

ANALYZE mart_star.dim_aeg;
ANALYZE mart_star.dim_vanuse_grupp;
ANALYZE mart_star.dim_ettevote;
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
