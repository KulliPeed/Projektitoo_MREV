\set ON_ERROR_STOP on
\pset pager off

-- Final MART_STAR model:
-- one fact row = one company for one MTA snapshot_date.
-- The old mart dashboard/cache schema is intentionally removed here.

BEGIN;

DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS mart_star CASCADE;

CREATE SCHEMA mart_star;

CREATE TABLE mart_star.dim_ettevote (
    ettevote_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registrikood text NOT NULL UNIQUE,
    nimi text
);

CREATE TABLE mart_star.dim_aeg (
    kuupaev date PRIMARY KEY,
    paev integer NOT NULL,
    kuu integer NOT NULL,
    aasta integer NOT NULL
);

CREATE TABLE mart_star.dim_vanuse_grupp (
    maksuvola_vanuse_grupp text PRIMARY KEY,
    min_paevi integer,
    max_paevi integer,
    jarjestus integer NOT NULL
);

CREATE TABLE mart_star.fact_maksuvolg (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dim_ettevote_id bigint NOT NULL REFERENCES mart_star.dim_ettevote(ettevote_id),
    kuupaev date NOT NULL REFERENCES mart_star.dim_aeg(kuupaev),
    maksuvola_summa numeric(18,2) NOT NULL,
    maksuvola_vanuse_grupp text NOT NULL REFERENCES mart_star.dim_vanuse_grupp(maksuvola_vanuse_grupp),
    juhatuse_muutuse_fakt boolean NOT NULL DEFAULT false,
    CONSTRAINT uq_fact_maksuvolg_ettevote_kuupaev UNIQUE (dim_ettevote_id, kuupaev)
);

CREATE TEMP TABLE mart_star_mta_company_snapshot_tmp ON COMMIT DROP AS
SELECT
    NULLIF(btrim(m.registrikood), '') AS registrikood,
    m.snapshot_date AS kuupaev,
    (array_agg(NULLIF(btrim(m.nimi), '') ORDER BY COALESCE(m.maksuvolg, 0) DESC, m.row_no DESC)
        FILTER (WHERE NULLIF(btrim(m.nimi), '') IS NOT NULL))[1] AS mta_nimi,
    COALESCE(sum(COALESCE(m.maksuvolg, 0)), 0)::numeric(18,2) AS maksuvola_summa,
    max(m.volg_vanus_paevades) AS max_volg_vanus_paevades
FROM stage.mta_maksuvolglased m
WHERE NULLIF(btrim(m.registrikood), '') IS NOT NULL
  AND m.snapshot_date IS NOT NULL
GROUP BY
    NULLIF(btrim(m.registrikood), ''),
    m.snapshot_date;

CREATE INDEX mart_star_mta_company_snapshot_reg_idx
    ON mart_star_mta_company_snapshot_tmp(registrikood);
CREATE INDEX mart_star_mta_company_snapshot_date_reg_idx
    ON mart_star_mta_company_snapshot_tmp(kuupaev, registrikood);

INSERT INTO mart_star.dim_aeg (kuupaev, paev, kuu, aasta)
SELECT DISTINCT
    m.kuupaev,
    extract(day FROM m.kuupaev)::integer AS paev,
    extract(month FROM m.kuupaev)::integer AS kuu,
    extract(year FROM m.kuupaev)::integer AS aasta
FROM mart_star_mta_company_snapshot_tmp m
ORDER BY m.kuupaev;

WITH actual_groups AS (
    SELECT DISTINCT NULLIF(btrim(volg_vanuse_grupp), '') AS maksuvola_vanuse_grupp
    FROM stage.mta_maksuvolglased
    WHERE NULLIF(btrim(volg_vanuse_grupp), '') IS NOT NULL
),
known_groups AS (
    SELECT *
    FROM (
        VALUES
            ('kuni 2 kuud', 1, 59, 1),
            ('2-5 kuud', 60, 179, 2),
            ('6-11 kuud', 180, 364, 3),
            ('>= 1 aasta', 365, NULL::integer, 4)
    ) AS g(maksuvola_vanuse_grupp, min_paevi, max_paevi, jarjestus)
)
INSERT INTO mart_star.dim_vanuse_grupp (
    maksuvola_vanuse_grupp,
    min_paevi,
    max_paevi,
    jarjestus
)
SELECT
    k.maksuvola_vanuse_grupp,
    k.min_paevi,
    k.max_paevi,
    k.jarjestus
FROM known_groups k
JOIN actual_groups a
  ON a.maksuvola_vanuse_grupp = k.maksuvola_vanuse_grupp
ORDER BY k.jarjestus;

WITH latest_mta_name_by_company AS (
    SELECT DISTINCT ON (registrikood)
        registrikood,
        mta_nimi
    FROM mart_star_mta_company_snapshot_tmp
    ORDER BY
        registrikood,
        kuupaev DESC,
        maksuvola_summa DESC
),
latest_rik_snapshot AS (
    SELECT max(snapshot_date) AS snapshot_date
    FROM stage.rik_ettevotted
),
latest_rik_name_by_company AS (
    SELECT DISTINCT ON (NULLIF(btrim(r.registrikood), ''))
        NULLIF(btrim(r.registrikood), '') AS registrikood,
        NULLIF(btrim(r.nimi), '') AS rik_nimi
    FROM stage.rik_ettevotted r
    WHERE r.snapshot_date = (SELECT snapshot_date FROM latest_rik_snapshot)
      AND NULLIF(btrim(r.registrikood), '') IS NOT NULL
    ORDER BY NULLIF(btrim(r.registrikood), ''), r.row_no DESC
)
INSERT INTO mart_star.dim_ettevote (registrikood, nimi)
SELECT
    m.registrikood,
    COALESCE(r.rik_nimi, m.mta_nimi) AS nimi
FROM latest_mta_name_by_company m
LEFT JOIN latest_rik_name_by_company r
  ON r.registrikood = m.registrikood
ORDER BY m.registrikood;

CREATE TEMP TABLE mart_star_mta_dates_tmp ON COMMIT DROP AS
SELECT DISTINCT kuupaev AS mta_kuupaev
FROM mart_star_mta_company_snapshot_tmp;

CREATE TEMP TABLE mart_star_mta_companies_tmp ON COMMIT DROP AS
SELECT DISTINCT registrikood
FROM mart_star_mta_company_snapshot_tmp;

CREATE INDEX mart_star_mta_dates_date_idx ON mart_star_mta_dates_tmp(mta_kuupaev);
CREATE INDEX mart_star_mta_companies_reg_idx ON mart_star_mta_companies_tmp(registrikood);

CREATE TEMP TABLE mart_star_rik_dates_tmp ON COMMIT DROP AS
SELECT DISTINCT snapshot_date
FROM stage.rik_kaardile_kantud_isikud
WHERE snapshot_date IS NOT NULL;

CREATE INDEX mart_star_rik_dates_date_idx ON mart_star_rik_dates_tmp(snapshot_date);

CREATE TEMP TABLE mart_star_mta_rik_dates_tmp ON COMMIT DROP AS
WITH current_rik AS (
    SELECT
        m.mta_kuupaev,
        max(r.snapshot_date) AS rik_snapshot_date
    FROM mart_star_mta_dates_tmp m
    LEFT JOIN mart_star_rik_dates_tmp r
      ON r.snapshot_date <= m.mta_kuupaev
    GROUP BY m.mta_kuupaev
)
SELECT
    c.mta_kuupaev,
    c.rik_snapshot_date,
    max(p.snapshot_date) AS previous_rik_snapshot_date,
    (c.rik_snapshot_date IS NOT NULL AND max(p.snapshot_date) IS NOT NULL) AS rik_vordlus_olemas
FROM current_rik c
LEFT JOIN mart_star_rik_dates_tmp p
  ON p.snapshot_date < c.rik_snapshot_date
GROUP BY c.mta_kuupaev, c.rik_snapshot_date;

CREATE INDEX mart_star_mta_rik_dates_mta_idx
    ON mart_star_mta_rik_dates_tmp(mta_kuupaev);

CREATE TEMP TABLE mart_star_needed_rik_dates_tmp ON COMMIT DROP AS
SELECT rik_snapshot_date AS snapshot_date
FROM mart_star_mta_rik_dates_tmp
WHERE rik_snapshot_date IS NOT NULL
UNION
SELECT previous_rik_snapshot_date
FROM mart_star_mta_rik_dates_tmp
WHERE previous_rik_snapshot_date IS NOT NULL;

CREATE INDEX mart_star_needed_rik_dates_date_idx
    ON mart_star_needed_rik_dates_tmp(snapshot_date);

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
JOIN mart_star_needed_rik_dates_tmp d
  ON d.snapshot_date = i.snapshot_date
JOIN mart_star_mta_companies_tmp c
  ON c.registrikood = NULLIF(btrim(i.registrikood), '')
WHERE i.on_juhatuse_liige = true
  AND NULLIF(btrim(i.registrikood), '') IS NOT NULL;

CREATE INDEX mart_star_board_members_date_reg_key_idx
    ON mart_star_board_members_tmp(snapshot_date, registrikood, isik_key);

CREATE TEMP TABLE mart_star_current_board_tmp ON COMMIT DROP AS
SELECT
    d.mta_kuupaev,
    b.registrikood,
    b.isik_key
FROM mart_star_mta_rik_dates_tmp d
JOIN mart_star_board_members_tmp b
  ON b.snapshot_date = d.rik_snapshot_date
WHERE d.rik_vordlus_olemas = true;

CREATE TEMP TABLE mart_star_previous_board_tmp ON COMMIT DROP AS
SELECT
    d.mta_kuupaev,
    b.registrikood,
    b.isik_key
FROM mart_star_mta_rik_dates_tmp d
JOIN mart_star_board_members_tmp b
  ON b.snapshot_date = d.previous_rik_snapshot_date
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

CREATE INDEX mart_star_added_board_date_reg_idx
    ON mart_star_added_board_tmp(mta_kuupaev, registrikood);
CREATE INDEX mart_star_removed_board_date_reg_idx
    ON mart_star_removed_board_tmp(mta_kuupaev, registrikood);

CREATE TEMP TABLE mart_star_juhatuse_muutus_tmp ON COMMIT DROP AS
SELECT
    m.kuupaev,
    m.registrikood,
    CASE
        WHEN d.rik_vordlus_olemas = true THEN
            COALESCE(a.lisatud_juhatuse_liikmeid, 0) > 0
            OR COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) > 0
        ELSE false
    END AS juhatuse_muutuse_fakt
FROM mart_star_mta_company_snapshot_tmp m
JOIN mart_star_mta_rik_dates_tmp d
  ON d.mta_kuupaev = m.kuupaev
LEFT JOIN mart_star_added_board_tmp a
       ON a.mta_kuupaev = m.kuupaev
      AND a.registrikood = m.registrikood
LEFT JOIN mart_star_removed_board_tmp r
       ON r.mta_kuupaev = m.kuupaev
      AND r.registrikood = m.registrikood;

CREATE INDEX mart_star_juhatuse_muutus_date_reg_idx
    ON mart_star_juhatuse_muutus_tmp(kuupaev, registrikood);

INSERT INTO mart_star.fact_maksuvolg (
    dim_ettevote_id,
    kuupaev,
    maksuvola_summa,
    maksuvola_vanuse_grupp,
    juhatuse_muutuse_fakt
)
SELECT
    e.ettevote_id AS dim_ettevote_id,
    m.kuupaev,
    m.maksuvola_summa,
    CASE
        WHEN m.max_volg_vanus_paevades BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
        WHEN m.max_volg_vanus_paevades BETWEEN 60 AND 179 THEN '2-5 kuud'
        WHEN m.max_volg_vanus_paevades BETWEEN 180 AND 364 THEN '6-11 kuud'
        WHEN m.max_volg_vanus_paevades >= 365 THEN '>= 1 aasta'
        ELSE NULL
    END AS maksuvola_vanuse_grupp,
    COALESCE(jm.juhatuse_muutuse_fakt, false) AS juhatuse_muutuse_fakt
FROM mart_star_mta_company_snapshot_tmp m
JOIN mart_star.dim_ettevote e
  ON e.registrikood = m.registrikood
LEFT JOIN mart_star_juhatuse_muutus_tmp jm
       ON jm.kuupaev = m.kuupaev
      AND jm.registrikood = m.registrikood;

CREATE INDEX idx_mart_star_fact_ettevote
    ON mart_star.fact_maksuvolg(dim_ettevote_id);
CREATE INDEX idx_mart_star_fact_kuupaev
    ON mart_star.fact_maksuvolg(kuupaev);
CREATE INDEX idx_mart_star_fact_vanuse_grupp
    ON mart_star.fact_maksuvolg(maksuvola_vanuse_grupp);
CREATE INDEX idx_mart_star_fact_juhatuse_muutus
    ON mart_star.fact_maksuvolg(juhatuse_muutuse_fakt);
CREATE INDEX idx_mart_star_dim_ettevote_registrikood
    ON mart_star.dim_ettevote(registrikood);
CREATE INDEX idx_mart_star_dim_vanuse_grupp_jarjestus
    ON mart_star.dim_vanuse_grupp(jarjestus);

ANALYZE mart_star.dim_ettevote;
ANALYZE mart_star.dim_aeg;
ANALYZE mart_star.dim_vanuse_grupp;
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
