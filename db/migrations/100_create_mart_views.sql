\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE SCHEMA IF NOT EXISTS mart;

CREATE OR REPLACE VIEW mart.v_latest_dates AS
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

CREATE OR REPLACE VIEW mart.v_maksuvolg_vanusegruppide_kaupa AS
SELECT
    m.data_as_of,
    m.volg_vanuse_grupp,
    count(*) AS ettevotete_arv,
    COALESCE(sum(m.maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(m.sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(m.sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM stage.mta_maksuvolglased m
JOIN mart.v_latest_dates d ON d.latest_mta_data_as_of = m.data_as_of
GROUP BY
    m.data_as_of,
    m.volg_vanuse_grupp;

CREATE OR REPLACE VIEW mart.v_viimased_maksuvolglased_rik_andmetega AS
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
JOIN mart.v_latest_dates d ON d.latest_mta_data_as_of = m.data_as_of
LEFT JOIN stage.rik_ettevotted r
       ON r.snapshot_date = d.latest_rik_snapshot_date
      AND r.registrikood = m.registrikood;

CREATE OR REPLACE VIEW mart.v_juhatuse_muutused_viimane_paev AS
WITH dates AS (
    SELECT
        latest_rik_snapshot_date AS rik_snapshot_date,
        previous_rik_snapshot_date
    FROM mart.v_latest_dates
    WHERE latest_rik_snapshot_date IS NOT NULL
      AND previous_rik_snapshot_date IS NOT NULL
),
current_board AS (
    SELECT DISTINCT
        NULLIF(btrim(i.registrikood), '') AS registrikood,
        COALESCE(
            NULLIF(btrim(i.isikukood), ''),
            'NAME:' || lower(COALESCE(NULLIF(btrim(i.isik_nimi), ''), '')) ||
            '|ROLE:' || COALESCE(NULLIF(btrim(i.roll), ''), '') ||
            '|START:' || COALESCE(i.rolli_alguskuupaev::text, '')
        ) AS isik_key
    FROM stage.rik_kaardile_kantud_isikud i
    JOIN dates d ON d.rik_snapshot_date = i.snapshot_date
    WHERE i.on_juhatuse_liige = true
      AND NULLIF(btrim(i.registrikood), '') IS NOT NULL
),
previous_board AS (
    SELECT DISTINCT
        NULLIF(btrim(i.registrikood), '') AS registrikood,
        COALESCE(
            NULLIF(btrim(i.isikukood), ''),
            'NAME:' || lower(COALESCE(NULLIF(btrim(i.isik_nimi), ''), '')) ||
            '|ROLE:' || COALESCE(NULLIF(btrim(i.roll), ''), '') ||
            '|START:' || COALESCE(i.rolli_alguskuupaev::text, '')
        ) AS isik_key
    FROM stage.rik_kaardile_kantud_isikud i
    JOIN dates d ON d.previous_rik_snapshot_date = i.snapshot_date
    WHERE i.on_juhatuse_liige = true
      AND NULLIF(btrim(i.registrikood), '') IS NOT NULL
),
added AS (
    SELECT
        c.registrikood,
        count(*) AS lisatud_juhatuse_liikmeid
    FROM current_board c
    LEFT JOIN previous_board p
           ON p.registrikood = c.registrikood
          AND p.isik_key = c.isik_key
    WHERE p.isik_key IS NULL
    GROUP BY c.registrikood
),
removed AS (
    SELECT
        p.registrikood,
        count(*) AS eemaldatud_juhatuse_liikmeid
    FROM previous_board p
    LEFT JOIN current_board c
           ON c.registrikood = p.registrikood
          AND c.isik_key = p.isik_key
    WHERE c.isik_key IS NULL
    GROUP BY p.registrikood
),
current_counts AS (
    SELECT
        registrikood,
        count(*) AS praegune_juhatuse_liikmete_arv
    FROM current_board
    GROUP BY registrikood
),
previous_counts AS (
    SELECT
        registrikood,
        count(*) AS eelmine_juhatuse_liikmete_arv
    FROM previous_board
    GROUP BY registrikood
),
all_companies AS (
    SELECT registrikood FROM current_counts
    UNION
    SELECT registrikood FROM previous_counts
),
final AS (
    SELECT
        d.rik_snapshot_date,
        d.previous_rik_snapshot_date,
        ac.registrikood,
        COALESCE(a.lisatud_juhatuse_liikmeid, 0) AS lisatud_juhatuse_liikmeid,
        COALESCE(r.eemaldatud_juhatuse_liikmeid, 0) AS eemaldatud_juhatuse_liikmeid,
        COALESCE(cc.praegune_juhatuse_liikmete_arv, 0) AS praegune_juhatuse_liikmete_arv,
        COALESCE(pc.eelmine_juhatuse_liikmete_arv, 0) AS eelmine_juhatuse_liikmete_arv
    FROM all_companies ac
    CROSS JOIN dates d
    LEFT JOIN added a ON a.registrikood = ac.registrikood
    LEFT JOIN removed r ON r.registrikood = ac.registrikood
    LEFT JOIN current_counts cc ON cc.registrikood = ac.registrikood
    LEFT JOIN previous_counts pc ON pc.registrikood = ac.registrikood
)
SELECT
    rik_snapshot_date,
    previous_rik_snapshot_date,
    registrikood,
    (lisatud_juhatuse_liikmeid > 0 OR eemaldatud_juhatuse_liikmeid > 0) AS juhatus_muutus,
    lisatud_juhatuse_liikmeid,
    eemaldatud_juhatuse_liikmeid,
    praegune_juhatuse_liikmete_arv,
    eelmine_juhatuse_liikmete_arv
FROM final;

CREATE OR REPLACE VIEW mart.v_maksuvolglased_juhatuse_muutusega AS
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
FROM mart.v_viimased_maksuvolglased_rik_andmetega m
JOIN mart.v_latest_dates d ON true
LEFT JOIN mart.v_juhatuse_muutused_viimane_paev j
       ON j.rik_snapshot_date = m.rik_snapshot_date
      AND j.registrikood = m.registrikood;

CREATE OR REPLACE VIEW mart.v_maksuvolg_juhatuse_muutus_vanusegrupp AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus,
    count(*) AS ettevotete_arv,
    COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM mart.v_maksuvolglased_juhatuse_muutusega
GROUP BY
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus;

CREATE OR REPLACE VIEW mart.v_dashboard_kpi AS
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
    FROM mart.v_maksuvolglased_juhatuse_muutusega
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
FROM mart.v_maksuvolglased_juhatuse_muutusega;

DO $$
DECLARE
    v_role name;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['andmeprojekt_readonly', 'read_only', 'readonly', 'superset']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('GRANT USAGE ON SCHEMA mart TO %I', v_role);
            EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA mart TO %I', v_role);
        END IF;
    END LOOP;
END;
$$;

COMMIT;
