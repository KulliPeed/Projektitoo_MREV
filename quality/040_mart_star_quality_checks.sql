\set ON_ERROR_STOP on
\pset pager off

\echo '=== MART_STAR objektid olemas ==='
WITH expected(object_name) AS (
    VALUES
        ('mart_star.dim_aeg'),
        ('mart_star.dim_ettevote'),
        ('mart_star.dim_vanuse_grupp'),
        ('mart_star.fact_maksuvolg')
)
SELECT
    object_name,
    CASE WHEN to_regclass(object_name) IS NOT NULL THEN 'OK' ELSE 'ERROR' END AS status
FROM expected
ORDER BY object_name;

DO $$
DECLARE
    v_missing text;
BEGIN
    WITH expected(object_name) AS (
        VALUES
            ('mart_star.dim_aeg'),
            ('mart_star.dim_ettevote'),
            ('mart_star.dim_vanuse_grupp'),
            ('mart_star.fact_maksuvolg')
    )
    SELECT string_agg(object_name, ', ' ORDER BY object_name)
    INTO v_missing
    FROM expected
    WHERE to_regclass(object_name) IS NULL;

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Puuduvad MART_STAR objektid: %', v_missing;
    END IF;
END;
$$;

\echo '=== MART_STAR kvaliteedi ajutised koondid ==='
CREATE TEMP TABLE mart_star_quality_latest_snapshot AS
SELECT max(snapshot_date) AS latest_mta_snapshot_date
FROM stage.mta_maksuvolglased;

CREATE TEMP TABLE mart_star_quality_stage_by_company AS
WITH latest_rows AS (
    SELECT
        NULLIF(btrim(registrikood), '') AS registrikood,
        snapshot_date,
        data_as_of,
        COALESCE(maksuvolg, 0) AS maksuvolg,
        COALESCE(sh_vaidlustatud, 0) AS sh_vaidlustatud,
        COALESCE(sh_tasumisgraafikus, 0) AS sh_tasumisgraafikus,
        volg_vanus_paevades
    FROM stage.mta_maksuvolglased
    WHERE snapshot_date = (SELECT latest_mta_snapshot_date FROM mart_star_quality_latest_snapshot)
)
SELECT
    registrikood,
    max(snapshot_date) AS mta_snapshot_date,
    max(data_as_of) AS mta_data_as_of,
    COALESCE(sum(maksuvolg), 0)::numeric(18,2) AS maksuvola_summa,
    COALESCE(sum(sh_vaidlustatud), 0)::numeric(18,2) AS vaidlustatud_summa,
    COALESCE(sum(sh_tasumisgraafikus), 0)::numeric(18,2) AS tasumisgraafikus_summa,
    max(volg_vanus_paevades) AS volg_vanus_paevades,
    CASE
        WHEN max(volg_vanus_paevades) BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
        WHEN max(volg_vanus_paevades) BETWEEN 60 AND 179 THEN '2-5 kuud'
        WHEN max(volg_vanus_paevades) BETWEEN 180 AND 364 THEN '6-11 kuud'
        WHEN max(volg_vanus_paevades) >= 365 THEN '>= 1 aasta'
        ELSE NULL
    END AS maksuvola_vanuse_grupp
FROM latest_rows
WHERE registrikood IS NOT NULL
GROUP BY registrikood;

CREATE TEMP TABLE mart_star_quality_counts AS
SELECT 'mart_star.dim_aeg' AS object_name, count(*) AS row_count FROM mart_star.dim_aeg
UNION ALL
SELECT 'mart_star.dim_ettevote', count(*) FROM mart_star.dim_ettevote
UNION ALL
SELECT 'mart_star.dim_vanuse_grupp', count(*) FROM mart_star.dim_vanuse_grupp
UNION ALL
SELECT 'mart_star.fact_maksuvolg', count(*) FROM mart_star.fact_maksuvolg;

\echo '=== MART_STAR rea-arvud ==='
SELECT
    object_name,
    row_count,
    CASE
        WHEN object_name = 'mart_star.dim_vanuse_grupp' AND row_count = 4 THEN 'OK'
        WHEN object_name <> 'mart_star.dim_vanuse_grupp' AND row_count > 0 THEN 'OK'
        ELSE 'ERROR'
    END AS status
FROM mart_star_quality_counts
ORDER BY object_name;

DO $$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(object_name || '=' || row_count::text, ', ' ORDER BY object_name)
    INTO v_bad
    FROM mart_star_quality_counts
    WHERE (object_name = 'mart_star.dim_vanuse_grupp' AND row_count <> 4)
       OR (object_name <> 'mart_star.dim_vanuse_grupp' AND row_count <= 0);

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MART_STAR rea-arvude kontroll ebaonnestus: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR FK terviklikkus ==='
WITH checks AS (
    SELECT 'fact -> dim_ettevote' AS check_name, count(*) AS bad_rows
    FROM mart_star.fact_maksuvolg f
    LEFT JOIN mart_star.dim_ettevote d ON d.ettevote_id = f.dim_ettevote_id
    WHERE d.ettevote_id IS NULL
    UNION ALL
    SELECT 'fact -> dim_aeg', count(*)
    FROM mart_star.fact_maksuvolg f
    LEFT JOIN mart_star.dim_aeg d ON d.kuupaev = f.kuupaev
    WHERE d.kuupaev IS NULL
    UNION ALL
    SELECT 'fact -> dim_vanuse_grupp', count(*)
    FROM mart_star.fact_maksuvolg f
    LEFT JOIN mart_star.dim_vanuse_grupp d ON d.maksuvola_vanuse_grupp = f.maksuvola_vanuse_grupp
    WHERE d.maksuvola_vanuse_grupp IS NULL
)
SELECT
    check_name,
    bad_rows,
    CASE WHEN bad_rows = 0 THEN 'OK' ELSE 'ERROR' END AS status
FROM checks
ORDER BY check_name;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    WITH checks AS (
        SELECT count(*) AS bad_rows
        FROM mart_star.fact_maksuvolg f
        LEFT JOIN mart_star.dim_ettevote d ON d.ettevote_id = f.dim_ettevote_id
        WHERE d.ettevote_id IS NULL
        UNION ALL
        SELECT count(*)
        FROM mart_star.fact_maksuvolg f
        LEFT JOIN mart_star.dim_aeg d ON d.kuupaev = f.kuupaev
        WHERE d.kuupaev IS NULL
        UNION ALL
        SELECT count(*)
        FROM mart_star.fact_maksuvolg f
        LEFT JOIN mart_star.dim_vanuse_grupp d ON d.maksuvola_vanuse_grupp = f.maksuvola_vanuse_grupp
        WHERE d.maksuvola_vanuse_grupp IS NULL
    )
    SELECT COALESCE(sum(bad_rows), 0) INTO v_bad FROM checks;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR FK kontroll leidis vigaseid ridu: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR faktisumma pariteet latest STAGE snapshotiga ==='
WITH stage_sum AS (
    SELECT COALESCE(sum(maksuvola_summa), 0) AS total_sum
    FROM mart_star_quality_stage_by_company
),
fact_sum AS (
    SELECT COALESCE(sum(maksuvola_summa), 0) AS total_sum
    FROM mart_star.fact_maksuvolg
)
SELECT
    stage_sum.total_sum AS stage_sum,
    fact_sum.total_sum AS fact_sum,
    abs(stage_sum.total_sum - fact_sum.total_sum) < 0.01 AS ok
FROM stage_sum, fact_sum;

DO $$
DECLARE
    v_stage_sum numeric;
    v_fact_sum numeric;
BEGIN
    SELECT s.total_sum, f.total_sum
    INTO v_stage_sum, v_fact_sum
    FROM (
        SELECT COALESCE(sum(maksuvola_summa), 0) AS total_sum
        FROM mart_star_quality_stage_by_company
    ) s
    CROSS JOIN (
        SELECT COALESCE(sum(maksuvola_summa), 0) AS total_sum
        FROM mart_star.fact_maksuvolg
    ) f;

    IF abs(v_stage_sum - v_fact_sum) >= 0.01 THEN
        RAISE EXCEPTION 'MART_STAR summa ei klapi: stage=%, fact=%', v_stage_sum, v_fact_sum;
    END IF;
END;
$$;

\echo '=== MART_STAR faktiridade pariteet latest STAGE unikaalsete registrikoodidega ==='
WITH stage_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star_quality_stage_by_company
),
fact_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star.fact_maksuvolg
)
SELECT
    stage_cnt.cnt AS stage_distinct_registrikoodid,
    fact_cnt.cnt AS fact_rows,
    stage_cnt.cnt = fact_cnt.cnt AS ok
FROM stage_cnt, fact_cnt;

DO $$
DECLARE
    v_stage_cnt bigint;
    v_fact_cnt bigint;
BEGIN
    SELECT s.cnt, f.cnt
    INTO v_stage_cnt, v_fact_cnt
    FROM (SELECT count(*) AS cnt FROM mart_star_quality_stage_by_company) s
    CROSS JOIN (SELECT count(*) AS cnt FROM mart_star.fact_maksuvolg) f;

    IF v_stage_cnt <> v_fact_cnt THEN
        RAISE EXCEPTION 'MART_STAR faktiridade arv ei klapi: stage=%, fact=%', v_stage_cnt, v_fact_cnt;
    END IF;
END;
$$;

\echo '=== MART_STAR juhatuse muutuse kontroll ==='
SELECT
    count(*) AS rows_checked,
    count(*) FILTER (WHERE juhatuse_muutuse_fakt IS NULL) AS null_flag_rows,
    count(*) FILTER (
        WHERE lisatud_juhatuse_liikmeid < 0
           OR eemaldatud_juhatuse_liikmeid < 0
           OR praegune_juhatuse_liikmete_arv < 0
           OR eelmine_juhatuse_liikmete_arv < 0
    ) AS negative_count_rows,
    CASE
        WHEN count(*) FILTER (WHERE juhatuse_muutuse_fakt IS NULL) = 0
         AND count(*) FILTER (
             WHERE lisatud_juhatuse_liikmeid < 0
                OR eemaldatud_juhatuse_liikmeid < 0
                OR praegune_juhatuse_liikmete_arv < 0
                OR eelmine_juhatuse_liikmete_arv < 0
         ) = 0 THEN 'OK'
        ELSE 'ERROR'
    END AS status
FROM mart_star.fact_maksuvolg;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*)
    INTO v_bad
    FROM mart_star.fact_maksuvolg
    WHERE juhatuse_muutuse_fakt IS NULL
       OR lisatud_juhatuse_liikmeid < 0
       OR eemaldatud_juhatuse_liikmeid < 0
       OR praegune_juhatuse_liikmete_arv < 0
       OR eelmine_juhatuse_liikmete_arv < 0;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR juhatuse muutuse kontroll leidis vigaseid ridu: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR vanusegrupi kontroll ==='
SELECT
    count(*) AS invalid_group_rows,
    CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ERROR' END AS status
FROM mart_star.fact_maksuvolg f
LEFT JOIN mart_star.dim_vanuse_grupp d
       ON d.maksuvola_vanuse_grupp = f.maksuvola_vanuse_grupp
WHERE d.maksuvola_vanuse_grupp IS NULL;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*)
    INTO v_bad
    FROM mart_star.fact_maksuvolg f
    LEFT JOIN mart_star.dim_vanuse_grupp d
           ON d.maksuvola_vanuse_grupp = f.maksuvola_vanuse_grupp
    WHERE d.maksuvola_vanuse_grupp IS NULL;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR faktis on tundmatuid vanusegruppe: %', v_bad;
    END IF;
END;
$$;

\echo '=== README1 vastavus ==='
SELECT *
FROM (
    VALUES
        ('DIM_AEG', 'mart_star.dim_aeg'),
        ('DIM_ETTEVOTE', 'mart_star.dim_ettevote'),
        ('DIM_VANUSE_GRUPP', 'mart_star.dim_vanuse_grupp'),
        ('FACT_MAKSUVOLG', 'mart_star.fact_maksuvolg')
) AS mapping(readme1_objekt, fuusiline_objekt)
ORDER BY readme1_objekt;
