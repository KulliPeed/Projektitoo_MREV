\set ON_ERROR_STOP on
\pset pager off

\echo '=== MART objektid ==='
SELECT table_schema, table_name
FROM information_schema.views
WHERE table_schema = 'mart'
ORDER BY table_name;

DO $$
DECLARE
    v_missing text;
BEGIN
    WITH expected(view_name) AS (
        VALUES
            ('v_latest_dates'),
            ('v_maksuvolg_vanusegruppide_kaupa'),
            ('v_viimased_maksuvolglased_rik_andmetega'),
            ('v_juhatuse_muutused_viimane_paev'),
            ('v_maksuvolglased_juhatuse_muutusega'),
            ('v_maksuvolg_juhatuse_muutus_vanusegrupp'),
            ('v_dashboard_kpi'),
            ('v_top_maksuvolglased')
    )
    SELECT string_agg(e.view_name, ', ' ORDER BY e.view_name)
    INTO v_missing
    FROM expected e
    LEFT JOIN information_schema.views v
           ON v.table_schema = 'mart'
          AND v.table_name = e.view_name
    WHERE v.table_name IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Puuduvad MART vaated: %', v_missing;
    END IF;
END;
$$;

\echo '=== MART kvaliteedi ajutised koondid ==='
CREATE TEMP TABLE mart_quality_latest AS
SELECT * FROM mart.v_latest_dates;

CREATE TEMP TABLE mart_quality_maksuvolglased AS
SELECT * FROM mart.v_viimased_maksuvolglased_rik_andmetega;

CREATE TEMP TABLE mart_quality_juhatus AS
SELECT * FROM mart.v_juhatuse_muutused_viimane_paev;

CREATE TEMP TABLE mart_quality_maksuvolglased_juhatus AS
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
FROM mart_quality_maksuvolglased m
CROSS JOIN mart_quality_latest d
LEFT JOIN mart_quality_juhatus j
       ON j.rik_snapshot_date = m.rik_snapshot_date
      AND j.registrikood = m.registrikood;

CREATE TEMP TABLE mart_quality_vanusegrupp AS
SELECT
    m.data_as_of,
    m.volg_vanuse_grupp,
    count(*) AS ettevotete_arv,
    COALESCE(sum(m.maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(m.sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(m.sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM stage.mta_maksuvolglased m
JOIN mart_quality_latest d ON d.latest_mta_data_as_of = m.data_as_of
GROUP BY
    m.data_as_of,
    m.volg_vanuse_grupp;

CREATE TEMP TABLE mart_quality_juhatus_vanusegrupp AS
SELECT
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus,
    count(*) AS ettevotete_arv,
    COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa,
    COALESCE(sum(sh_vaidlustatud), 0) AS vaidlustatud_summa,
    COALESCE(sum(sh_tasumisgraafikus), 0) AS tasumisgraafikus_summa
FROM mart_quality_maksuvolglased_juhatus
GROUP BY
    mta_data_as_of,
    rik_snapshot_date,
    volg_vanuse_grupp,
    juhatus_muutus;

CREATE TEMP TABLE mart_quality_kpi AS
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
    FROM mart_quality_maksuvolglased_juhatus
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

CREATE TEMP TABLE mart_quality_top AS
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
FROM mart_quality_maksuvolglased_juhatus;

\echo '=== MART vaadete rea-arvud ==='
WITH view_counts AS (
    SELECT 'mart.v_latest_dates' AS view_name, count(*) AS row_count FROM mart_quality_latest
    UNION ALL
    SELECT 'mart.v_maksuvolg_vanusegruppide_kaupa', count(*) FROM mart_quality_vanusegrupp
    UNION ALL
    SELECT 'mart.v_viimased_maksuvolglased_rik_andmetega', count(*) FROM mart_quality_maksuvolglased
    UNION ALL
    SELECT 'mart.v_juhatuse_muutused_viimane_paev', count(*) FROM mart_quality_juhatus
    UNION ALL
    SELECT 'mart.v_maksuvolglased_juhatuse_muutusega', count(*) FROM mart_quality_maksuvolglased_juhatus
    UNION ALL
    SELECT 'mart.v_maksuvolg_juhatuse_muutus_vanusegrupp', count(*) FROM mart_quality_juhatus_vanusegrupp
    UNION ALL
    SELECT 'mart.v_dashboard_kpi', count(*) FROM mart_quality_kpi
    UNION ALL
    SELECT 'mart.v_top_maksuvolglased', count(*) FROM mart_quality_top
)
SELECT
    view_name,
    row_count,
    CASE
        WHEN view_name IN ('mart.v_latest_dates', 'mart.v_dashboard_kpi') AND row_count = 1 THEN 'OK'
        WHEN view_name NOT IN ('mart.v_latest_dates', 'mart.v_dashboard_kpi') AND row_count > 0 THEN 'OK'
        ELSE 'ERROR'
    END AS status
FROM view_counts
ORDER BY view_name;

DO $$
DECLARE
    v_cnt bigint;
BEGIN
    SELECT count(*) INTO v_cnt FROM mart_quality_latest;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'mart.v_latest_dates peab tagastama 1 rea, tegelik=%', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_kpi;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'mart.v_dashboard_kpi peab tagastama 1 rea, tegelik=%', v_cnt;
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_vanusegrupp;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_maksuvolg_vanusegruppide_kaupa ei tagastanud ridu';
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_maksuvolglased;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_viimased_maksuvolglased_rik_andmetega ei tagastanud ridu';
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_juhatus;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_juhatuse_muutused_viimane_paev ei tagastanud ridu';
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_maksuvolglased_juhatus;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_maksuvolglased_juhatuse_muutusega ei tagastanud ridu';
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_juhatus_vanusegrupp;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_maksuvolg_juhatuse_muutus_vanusegrupp ei tagastanud ridu';
    END IF;

    SELECT count(*) INTO v_cnt FROM mart_quality_top;
    IF v_cnt = 0 THEN
        RAISE EXCEPTION 'mart.v_top_maksuvolglased ei tagastanud ridu';
    END IF;
END;
$$;

\echo '=== MTA ridade pariteet viimases seisus ==='
WITH stage_latest AS (
    SELECT count(*) AS cnt
    FROM stage.mta_maksuvolglased
    WHERE data_as_of = (SELECT latest_mta_data_as_of FROM mart_quality_latest)
),
mart_latest AS (
    SELECT count(*) AS cnt
    FROM mart_quality_maksuvolglased
)
SELECT
    stage_latest.cnt AS stage_cnt,
    mart_latest.cnt AS mart_cnt,
    stage_latest.cnt = mart_latest.cnt AS ok
FROM stage_latest, mart_latest;

DO $$
DECLARE
    v_stage_cnt bigint;
    v_mart_cnt bigint;
BEGIN
    SELECT s.cnt, m.cnt
    INTO v_stage_cnt, v_mart_cnt
    FROM (
        SELECT count(*) AS cnt
        FROM stage.mta_maksuvolglased
        WHERE data_as_of = (SELECT latest_mta_data_as_of FROM mart_quality_latest)
    ) s
    CROSS JOIN (
        SELECT count(*) AS cnt
        FROM mart_quality_maksuvolglased
    ) m;

    IF v_stage_cnt <> v_mart_cnt THEN
        RAISE EXCEPTION 'MTA ridade pariteet ei klapi: stage=%, mart=%', v_stage_cnt, v_mart_cnt;
    END IF;
END;
$$;

\echo '=== Maksuvola summa pariteet ==='
WITH stage_latest AS (
    SELECT COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa
    FROM stage.mta_maksuvolglased
    WHERE data_as_of = (SELECT latest_mta_data_as_of FROM mart_quality_latest)
),
mart_latest AS (
    SELECT COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa
    FROM mart_quality_maksuvolglased
)
SELECT
    stage_latest.maksuvolg_summa AS stage_maksuvolg_summa,
    mart_latest.maksuvolg_summa AS mart_maksuvolg_summa,
    stage_latest.maksuvolg_summa = mart_latest.maksuvolg_summa AS ok
FROM stage_latest, mart_latest;

DO $$
DECLARE
    v_stage_sum numeric;
    v_mart_sum numeric;
BEGIN
    SELECT s.maksuvolg_summa, m.maksuvolg_summa
    INTO v_stage_sum, v_mart_sum
    FROM (
        SELECT COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa
        FROM stage.mta_maksuvolglased
        WHERE data_as_of = (SELECT latest_mta_data_as_of FROM mart_quality_latest)
    ) s
    CROSS JOIN (
        SELECT COALESCE(sum(maksuvolg), 0) AS maksuvolg_summa
        FROM mart_quality_maksuvolglased
    ) m;

    IF v_stage_sum <> v_mart_sum THEN
        RAISE EXCEPTION 'Maksuvola summa pariteet ei klapi: stage=%, mart=%', v_stage_sum, v_mart_sum;
    END IF;
END;
$$;

\echo '=== RIK uhildumise maar ==='
SELECT
    mta_ettevotteid,
    rikiga_uhildunud,
    rikita,
    uhildumise_maar_pct,
    CASE WHEN uhildumise_maar_pct < 95 THEN 'WARN' ELSE 'OK' END AS status
FROM mart_quality_kpi;

\echo '=== Juhatuse muutuse loogika ==='
SELECT
    count(*) AS rows_checked,
    count(*) FILTER (
        WHERE lisatud_juhatuse_liikmeid < 0
           OR eemaldatud_juhatuse_liikmeid < 0
           OR praegune_juhatuse_liikmete_arv < 0
           OR eelmine_juhatuse_liikmete_arv < 0
    ) AS negative_count_rows,
    count(*) FILTER (
        WHERE juhatus_muutus IS DISTINCT FROM (
            lisatud_juhatuse_liikmeid > 0
            OR eemaldatud_juhatuse_liikmeid > 0
        )
    ) AS inconsistent_logic_rows
FROM mart_quality_juhatus;

DO $$
DECLARE
    v_negative_count_rows bigint;
    v_inconsistent_logic_rows bigint;
BEGIN
    SELECT
        count(*) FILTER (
            WHERE lisatud_juhatuse_liikmeid < 0
               OR eemaldatud_juhatuse_liikmeid < 0
               OR praegune_juhatuse_liikmete_arv < 0
               OR eelmine_juhatuse_liikmete_arv < 0
        ),
        count(*) FILTER (
            WHERE juhatus_muutus IS DISTINCT FROM (
                lisatud_juhatuse_liikmeid > 0
                OR eemaldatud_juhatuse_liikmeid > 0
            )
        )
    INTO v_negative_count_rows, v_inconsistent_logic_rows
    FROM mart_quality_juhatus;

    IF v_negative_count_rows <> 0 THEN
        RAISE EXCEPTION 'Juhatuse muutuse vaates on negatiivseid arve: %', v_negative_count_rows;
    END IF;

    IF v_inconsistent_logic_rows <> 0 THEN
        RAISE EXCEPTION 'Juhatuse muutuse loogika ei klapi: % rida', v_inconsistent_logic_rows;
    END IF;
END;
$$;

\echo '=== Dashboard KPI kontroll ==='
SELECT
    *,
    CASE
        WHEN mta_ettevotteid < 0
          OR rikiga_uhildunud < 0
          OR rikita < 0
          OR uhildumise_maar_pct < 0
          OR maksuvolg_summa < 0
          OR juhatus_muutunud_ettevotteid < 0
          OR juhatus_muutunud_maksuvolg_summa < 0
          OR juhatus_muutunud_osakaal_pct < 0
        THEN 'ERROR'
        ELSE 'OK'
    END AS status
FROM mart_quality_kpi;

DO $$
DECLARE
    v_bad_rows bigint;
BEGIN
    SELECT count(*)
    INTO v_bad_rows
    FROM mart_quality_kpi
    WHERE mta_ettevotteid < 0
       OR rikiga_uhildunud < 0
       OR rikita < 0
       OR uhildumise_maar_pct < 0
       OR maksuvolg_summa < 0
       OR juhatus_muutunud_ettevotteid < 0
       OR juhatus_muutunud_maksuvolg_summa < 0
       OR juhatus_muutunud_osakaal_pct < 0;

    IF v_bad_rows <> 0 THEN
        RAISE EXCEPTION 'Dashboard KPI vaates on vigaseid ridu: %', v_bad_rows;
    END IF;
END;
$$;
