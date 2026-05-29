\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE SCHEMA IF NOT EXISTS mart;

CREATE TEMP TABLE superset_cache_latest_dates_tmp AS
WITH latest_mta AS (
    SELECT
        max(snapshot_date) AS latest_mta_snapshot_date,
        max(data_as_of) AS latest_mta_data_as_of
    FROM stage.mta_maksuvolglased
),
latest_rik AS (
    SELECT max(snapshot_date) AS latest_rik_snapshot_date
    FROM stage.rik_ettevotted
),
previous_rik AS (
    SELECT e.snapshot_date AS previous_rik_snapshot_date
    FROM stage.rik_ettevotted e
    CROSS JOIN latest_rik lr
    WHERE e.snapshot_date < lr.latest_rik_snapshot_date
    ORDER BY e.snapshot_date DESC
    LIMIT 1
)
SELECT
    lm.latest_mta_snapshot_date,
    lm.latest_mta_data_as_of,
    lr.latest_rik_snapshot_date,
    pr.previous_rik_snapshot_date
FROM latest_mta lm
CROSS JOIN latest_rik lr
CROSS JOIN previous_rik pr;

CREATE TEMP TABLE superset_cache_maksuvolg_vanusegruppide_tmp AS
SELECT
    m.data_as_of,
    m.volg_vanuse_grupp,
    count(*) AS ettevotete_arv,
    COALESCE(sum(m.maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(m.sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(m.sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM stage.mta_maksuvolglased m
JOIN superset_cache_latest_dates_tmp d ON d.latest_mta_data_as_of = m.data_as_of
GROUP BY
    m.data_as_of,
    m.volg_vanuse_grupp;

CREATE TEMP TABLE superset_cache_viimased_tmp AS
SELECT
    m.snapshot_date AS mta_snapshot_date,
    m.data_as_of AS mta_data_as_of,
    d.latest_rik_snapshot_date AS rik_snapshot_date,
    m.registrikood,
    m.nimi AS mta_nimi,
    r.nimi AS rik_nimi,
    COALESCE(NULLIF(r.nimi, ''), NULLIF(m.nimi, '')) AS nimi,
    m.maksuvolg,
    m.sh_vaidlustatud,
    m.sh_tasumisgraafikus,
    m.vanima_tasumata_noude_tasumise_tahtaeg,
    m.volg_vanus_paevades,
    m.volg_vanuse_grupp,
    (r.registrikood IS NOT NULL) AS leitud_rikist
FROM stage.mta_maksuvolglased m
JOIN superset_cache_latest_dates_tmp d ON d.latest_mta_data_as_of = m.data_as_of
LEFT JOIN stage.rik_ettevotted r
       ON r.snapshot_date = d.latest_rik_snapshot_date
      AND r.registrikood = m.registrikood;

CREATE INDEX ON superset_cache_viimased_tmp (rik_snapshot_date, registrikood);

CREATE TEMP TABLE superset_cache_current_board_tmp AS
SELECT DISTINCT
    NULLIF(btrim(i.registrikood), '') AS registrikood,
    COALESCE(
        NULLIF(btrim(i.isikukood), ''),
        'NAME:' || lower(COALESCE(NULLIF(btrim(i.isik_nimi), ''), '')) ||
        '|ROLE:' || COALESCE(NULLIF(btrim(i.roll), ''), '') ||
        '|START:' || COALESCE(i.rolli_alguskuupaev::text, '')
    ) AS isik_key
FROM stage.rik_kaardile_kantud_isikud i
JOIN superset_cache_latest_dates_tmp d ON d.latest_rik_snapshot_date = i.snapshot_date
WHERE i.on_juhatuse_liige = true
  AND NULLIF(btrim(i.registrikood), '') IS NOT NULL;

CREATE TEMP TABLE superset_cache_previous_board_tmp AS
SELECT DISTINCT
    NULLIF(btrim(i.registrikood), '') AS registrikood,
    COALESCE(
        NULLIF(btrim(i.isikukood), ''),
        'NAME:' || lower(COALESCE(NULLIF(btrim(i.isik_nimi), ''), '')) ||
        '|ROLE:' || COALESCE(NULLIF(btrim(i.roll), ''), '') ||
        '|START:' || COALESCE(i.rolli_alguskuupaev::text, '')
    ) AS isik_key
FROM stage.rik_kaardile_kantud_isikud i
JOIN superset_cache_latest_dates_tmp d ON d.previous_rik_snapshot_date = i.snapshot_date
WHERE i.on_juhatuse_liige = true
  AND NULLIF(btrim(i.registrikood), '') IS NOT NULL;

CREATE INDEX ON superset_cache_current_board_tmp (registrikood, isik_key);
CREATE INDEX ON superset_cache_previous_board_tmp (registrikood, isik_key);

CREATE TEMP TABLE superset_cache_added_tmp AS
SELECT
    c.registrikood,
    count(*) AS lisatud_juhatuse_liikmeid
FROM superset_cache_current_board_tmp c
LEFT JOIN superset_cache_previous_board_tmp p
       ON p.registrikood = c.registrikood
      AND p.isik_key = c.isik_key
WHERE p.isik_key IS NULL
GROUP BY c.registrikood;

CREATE TEMP TABLE superset_cache_removed_tmp AS
SELECT
    p.registrikood,
    count(*) AS eemaldatud_juhatuse_liikmeid
FROM superset_cache_previous_board_tmp p
LEFT JOIN superset_cache_current_board_tmp c
       ON c.registrikood = p.registrikood
      AND c.isik_key = p.isik_key
WHERE c.isik_key IS NULL
GROUP BY p.registrikood;

CREATE TEMP TABLE superset_cache_current_counts_tmp AS
SELECT
    registrikood,
    count(*) AS praegune_juhatuse_liikmete_arv
FROM superset_cache_current_board_tmp
GROUP BY registrikood;

CREATE TEMP TABLE superset_cache_previous_counts_tmp AS
SELECT
    registrikood,
    count(*) AS eelmine_juhatuse_liikmete_arv
FROM superset_cache_previous_board_tmp
GROUP BY registrikood;

CREATE INDEX ON superset_cache_added_tmp (registrikood);
CREATE INDEX ON superset_cache_removed_tmp (registrikood);
CREATE INDEX ON superset_cache_current_counts_tmp (registrikood);
CREATE INDEX ON superset_cache_previous_counts_tmp (registrikood);

CREATE TEMP TABLE superset_cache_juhatus_tmp AS
WITH all_companies AS (
    SELECT registrikood FROM superset_cache_current_counts_tmp
    UNION
    SELECT registrikood FROM superset_cache_previous_counts_tmp
)
SELECT
    d.latest_rik_snapshot_date AS rik_snapshot_date,
    d.previous_rik_snapshot_date,
    ac.registrikood,
    (
        COALESCE(a.lisatud_juhatuse_liikmeid, 0) > 0
        OR COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) > 0
    ) AS juhatus_muutus,
    COALESCE(a.lisatud_juhatuse_liikmeid, 0) AS lisatud_juhatuse_liikmeid,
    COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) AS eemaldatud_juhatuse_liikmeid,
    COALESCE(cc.praegune_juhatuse_liikmete_arv, 0) AS praegune_juhatuse_liikmete_arv,
    COALESCE(pc.eelmine_juhatuse_liikmete_arv, 0) AS eelmine_juhatuse_liikmete_arv
FROM all_companies ac
CROSS JOIN superset_cache_latest_dates_tmp d
LEFT JOIN superset_cache_added_tmp a ON a.registrikood = ac.registrikood
LEFT JOIN superset_cache_removed_tmp r ON r.registrikood = ac.registrikood
LEFT JOIN superset_cache_current_counts_tmp cc ON cc.registrikood = ac.registrikood
LEFT JOIN superset_cache_previous_counts_tmp pc ON pc.registrikood = ac.registrikood;

CREATE INDEX ON superset_cache_juhatus_tmp (rik_snapshot_date, registrikood);

CREATE TEMP TABLE superset_cache_maksuvolglased_juhatuse_tmp AS
SELECT
    m.mta_data_as_of,
    m.rik_snapshot_date,
    d.previous_rik_snapshot_date,
    m.registrikood,
    m.nimi,
    m.maksuvolg,
    m.sh_vaidlustatud,
    m.sh_tasumisgraafikus,
    m.volg_vanus_paevades,
    m.volg_vanuse_grupp,
    COALESCE(j.juhatus_muutus, false) AS juhatus_muutus,
    COALESCE(j.lisatud_juhatuse_liikmeid, 0) AS lisatud_juhatuse_liikmeid,
    COALESCE(j.eemaldatud_juhatuse_liikmeid, 0) AS eemaldatud_juhatuse_liikmeid,
    COALESCE(j.praegune_juhatuse_liikmete_arv, 0) AS praegune_juhatuse_liikmete_arv,
    COALESCE(j.eelmine_juhatuse_liikmete_arv, 0) AS eelmine_juhatuse_liikmete_arv,
    m.leitud_rikist
FROM superset_cache_viimased_tmp m
CROSS JOIN superset_cache_latest_dates_tmp d
LEFT JOIN superset_cache_juhatus_tmp j
       ON j.rik_snapshot_date = m.rik_snapshot_date
      AND j.registrikood = m.registrikood;

CREATE INDEX ON superset_cache_maksuvolglased_juhatuse_tmp (registrikood);
CREATE INDEX ON superset_cache_maksuvolglased_juhatuse_tmp (maksuvolg DESC);
CREATE INDEX ON superset_cache_maksuvolglased_juhatuse_tmp (volg_vanuse_grupp, juhatus_muutus);

CREATE TEMP TABLE superset_cache_juhatus_vanusegrupp_tmp AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus,
    count(*) AS ettevotete_arv,
    COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM superset_cache_maksuvolglased_juhatuse_tmp
GROUP BY
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus;

CREATE TEMP TABLE superset_cache_kpi_tmp AS
WITH agg AS (
    SELECT
        max(mta_data_as_of) AS mta_data_as_of,
        max(rik_snapshot_date) AS rik_snapshot_date,
        count(*) AS mta_ettevotteid,
        count(*) FILTER (WHERE leitud_rikist = true) AS rikiga_uhildunud,
        count(*) FILTER (WHERE leitud_rikist = false) AS rikita,
        COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa,
        count(*) FILTER (WHERE juhatus_muutus = true) AS juhatus_muutunud_ettevotteid,
        COALESCE(sum(maksuvolg) FILTER (WHERE juhatus_muutus = true), 0) AS juhatus_muutunud_maksuvolg_summa
    FROM superset_cache_maksuvolglased_juhatuse_tmp
)
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    mta_ettevotteid,
    rikiga_uhildunud,
    rikita,
    COALESCE(round(100.0 * rikiga_uhildunud::numeric / NULLIF(mta_ettevotteid, 0), 2), 0) AS uhildumise_maar_pct,
    maksuvolg_summa,
    juhatus_muutunud_ettevotteid,
    juhatus_muutunud_maksuvolg_summa,
    COALESCE(round(100.0 * juhatus_muutunud_ettevotteid::numeric / NULLIF(mta_ettevotteid, 0), 2), 0) AS juhatus_muutunud_osakaal_pct
FROM agg;

CREATE TEMP TABLE superset_cache_top_tmp AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    registrikood,
    nimi,
    maksuvolg,
    volg_vanuse_grupp,
    juhatus_muutus,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    leitud_rikist
FROM superset_cache_maksuvolglased_juhatuse_tmp;

CREATE TABLE IF NOT EXISTS mart.superset_cache_latest_dates
    (LIKE superset_cache_latest_dates_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_maksuvolg_vanusegruppide_kaupa
    (LIKE superset_cache_maksuvolg_vanusegruppide_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_viimased_maksuvolglased_rik_andmetega
    (LIKE superset_cache_viimased_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_juhatuse_muutused_viimane_paev
    (LIKE superset_cache_juhatus_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_maksuvolglased_juhatuse_muutusega
    (LIKE superset_cache_maksuvolglased_juhatuse_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp
    (LIKE superset_cache_juhatus_vanusegrupp_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_dashboard_kpi
    (LIKE superset_cache_kpi_tmp INCLUDING ALL);
CREATE TABLE IF NOT EXISTS mart.superset_cache_top_maksuvolglased
    (LIKE superset_cache_top_tmp INCLUDING ALL);

TRUNCATE
    mart.superset_cache_latest_dates,
    mart.superset_cache_maksuvolg_vanusegruppide_kaupa,
    mart.superset_cache_viimased_maksuvolglased_rik_andmetega,
    mart.superset_cache_juhatuse_muutused_viimane_paev,
    mart.superset_cache_maksuvolglased_juhatuse_muutusega,
    mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp,
    mart.superset_cache_dashboard_kpi,
    mart.superset_cache_top_maksuvolglased;

INSERT INTO mart.superset_cache_latest_dates
SELECT * FROM superset_cache_latest_dates_tmp;

INSERT INTO mart.superset_cache_maksuvolg_vanusegruppide_kaupa
SELECT * FROM superset_cache_maksuvolg_vanusegruppide_tmp;

INSERT INTO mart.superset_cache_viimased_maksuvolglased_rik_andmetega
SELECT * FROM superset_cache_viimased_tmp;

INSERT INTO mart.superset_cache_juhatuse_muutused_viimane_paev
SELECT * FROM superset_cache_juhatus_tmp;

INSERT INTO mart.superset_cache_maksuvolglased_juhatuse_muutusega
SELECT * FROM superset_cache_maksuvolglased_juhatuse_tmp;

INSERT INTO mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp
SELECT * FROM superset_cache_juhatus_vanusegrupp_tmp;

INSERT INTO mart.superset_cache_dashboard_kpi
SELECT * FROM superset_cache_kpi_tmp;

INSERT INTO mart.superset_cache_top_maksuvolglased
SELECT * FROM superset_cache_top_tmp;

CREATE INDEX IF NOT EXISTS idx_superset_cache_viimased_reg
    ON mart.superset_cache_viimased_maksuvolglased_rik_andmetega (rik_snapshot_date, registrikood);
CREATE INDEX IF NOT EXISTS idx_superset_cache_juhatus_reg
    ON mart.superset_cache_juhatuse_muutused_viimane_paev (rik_snapshot_date, registrikood);
CREATE INDEX IF NOT EXISTS idx_superset_cache_maksuvolglased_reg
    ON mart.superset_cache_maksuvolglased_juhatuse_muutusega (registrikood);
CREATE INDEX IF NOT EXISTS idx_superset_cache_maksuvolglased_maksuvolg
    ON mart.superset_cache_maksuvolglased_juhatuse_muutusega (maksuvolg DESC);
CREATE INDEX IF NOT EXISTS idx_superset_cache_maksuvolglased_grupp_muutus
    ON mart.superset_cache_maksuvolglased_juhatuse_muutusega (volg_vanuse_grupp, juhatus_muutus);
CREATE INDEX IF NOT EXISTS idx_superset_cache_top_maksuvolg
    ON mart.superset_cache_top_maksuvolglased (maksuvolg DESC);

CREATE OR REPLACE VIEW mart.v_latest_dates AS
SELECT
    latest_mta_snapshot_date,
    latest_mta_data_as_of,
    latest_rik_snapshot_date,
    previous_rik_snapshot_date
FROM mart.superset_cache_latest_dates;

CREATE OR REPLACE VIEW mart.v_maksuvolg_vanusegruppide_kaupa AS
SELECT
    data_as_of,
    volg_vanuse_grupp,
    ettevotete_arv,
    maksuvolg_summa,
    vaidlustatud_summa,
    tasumisgraafikus_summa
FROM mart.superset_cache_maksuvolg_vanusegruppide_kaupa;

CREATE OR REPLACE VIEW mart.v_viimased_maksuvolglased_rik_andmetega AS
SELECT
    mta_snapshot_date,
    mta_data_as_of,
    rik_snapshot_date,
    registrikood,
    mta_nimi,
    rik_nimi,
    nimi,
    maksuvolg,
    sh_vaidlustatud,
    sh_tasumisgraafikus,
    vanima_tasumata_noude_tasumise_tahtaeg,
    volg_vanus_paevades,
    volg_vanuse_grupp,
    leitud_rikist
FROM mart.superset_cache_viimased_maksuvolglased_rik_andmetega;

CREATE OR REPLACE VIEW mart.v_juhatuse_muutused_viimane_paev AS
SELECT
    rik_snapshot_date,
    previous_rik_snapshot_date,
    registrikood,
    juhatus_muutus,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv
FROM mart.superset_cache_juhatuse_muutused_viimane_paev;

CREATE OR REPLACE VIEW mart.v_maksuvolglased_juhatuse_muutusega AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    previous_rik_snapshot_date,
    registrikood,
    nimi,
    maksuvolg,
    sh_vaidlustatud,
    sh_tasumisgraafikus,
    volg_vanus_paevades,
    volg_vanuse_grupp,
    juhatus_muutus,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv,
    leitud_rikist
FROM mart.superset_cache_maksuvolglased_juhatuse_muutusega;

CREATE OR REPLACE VIEW mart.v_maksuvolg_juhatuse_muutus_vanusegrupp AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus,
    ettevotete_arv,
    maksuvolg_summa,
    vaidlustatud_summa,
    tasumisgraafikus_summa
FROM mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp;

CREATE OR REPLACE VIEW mart.v_dashboard_kpi AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    mta_ettevotteid,
    rikiga_uhildunud,
    rikita,
    uhildumise_maar_pct,
    maksuvolg_summa,
    juhatus_muutunud_ettevotteid,
    juhatus_muutunud_maksuvolg_summa,
    juhatus_muutunud_osakaal_pct
FROM mart.superset_cache_dashboard_kpi;

CREATE OR REPLACE VIEW mart.v_top_maksuvolglased AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    registrikood,
    nimi,
    maksuvolg,
    volg_vanuse_grupp,
    juhatus_muutus,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    leitud_rikist
FROM mart.superset_cache_top_maksuvolglased;

ANALYZE mart.superset_cache_latest_dates;
ANALYZE mart.superset_cache_maksuvolg_vanusegruppide_kaupa;
ANALYZE mart.superset_cache_viimased_maksuvolglased_rik_andmetega;
ANALYZE mart.superset_cache_juhatuse_muutused_viimane_paev;
ANALYZE mart.superset_cache_maksuvolglased_juhatuse_muutusega;
ANALYZE mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp;
ANALYZE mart.superset_cache_dashboard_kpi;
ANALYZE mart.superset_cache_top_maksuvolglased;

GRANT USAGE ON SCHEMA mart TO superset_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO superset_readonly;

COMMIT;
