\set ON_ERROR_STOP on
\pset pager off

\echo '=== MART_STAR objektid olemas ==='
WITH expected(object_name) AS (
    VALUES
        ('mart_star.dim_aeg'),
        ('mart_star.dim_ettevote'),
        ('mart_star.dim_vanuse_grupp'),
        ('mart_star.juhatuse_muutus_paeviti'),
        ('mart_star.v_juhatuse_muutus_paeviti'),
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
            ('mart_star.juhatuse_muutus_paeviti'),
            ('mart_star.v_juhatuse_muutus_paeviti'),
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
CREATE TEMP TABLE mart_star_quality_stage_by_company AS
SELECT
    NULLIF(btrim(m.registrikood), '') AS registrikood,
    m.snapshot_date AS mta_snapshot_date,
    m.data_as_of AS mta_data_as_of,
    COALESCE(sum(COALESCE(m.maksuvolg, 0)), 0)::numeric(18,2) AS maksuvola_summa,
    COALESCE(sum(COALESCE(m.sh_vaidlustatud, 0)), 0)::numeric(18,2) AS vaidlustatud_summa,
    COALESCE(sum(COALESCE(m.sh_tasumisgraafikus, 0)), 0)::numeric(18,2) AS tasumisgraafikus_summa,
    max(m.volg_vanus_paevades) AS volg_vanus_paevades,
    CASE
        WHEN max(m.volg_vanus_paevades) BETWEEN 1 AND 59 THEN 'kuni 2 kuud'
        WHEN max(m.volg_vanus_paevades) BETWEEN 60 AND 179 THEN '2-5 kuud'
        WHEN max(m.volg_vanus_paevades) BETWEEN 180 AND 364 THEN '6-11 kuud'
        WHEN max(m.volg_vanus_paevades) >= 365 THEN '>= 1 aasta'
        ELSE NULL
    END AS maksuvola_vanuse_grupp
FROM stage.mta_maksuvolglased m
WHERE NULLIF(btrim(m.registrikood), '') IS NOT NULL
GROUP BY
    NULLIF(btrim(m.registrikood), ''),
    m.snapshot_date,
    m.data_as_of;

CREATE TEMP TABLE mart_star_quality_counts AS
SELECT 'mart_star.dim_aeg' AS object_name, count(*) AS row_count FROM mart_star.dim_aeg
UNION ALL
SELECT 'mart_star.dim_ettevote', count(*) FROM mart_star.dim_ettevote
UNION ALL
SELECT 'mart_star.dim_vanuse_grupp', count(*) FROM mart_star.dim_vanuse_grupp
UNION ALL
SELECT 'mart_star.juhatuse_muutus_paeviti', count(*) FROM mart_star.juhatuse_muutus_paeviti
UNION ALL
SELECT 'mart_star.v_juhatuse_muutus_paeviti', count(*) FROM mart_star.v_juhatuse_muutus_paeviti
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

\echo '=== MART_STAR dim_ettevote pariteet MTA snapshotitega ==='
WITH stage_dim AS (
    SELECT count(DISTINCT registrikood) AS cnt
    FROM mart_star_quality_stage_by_company
),
dim_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star.dim_ettevote
)
SELECT
    stage_dim.cnt AS stage_distinct_registrikoodid,
    dim_cnt.cnt AS dim_ettevote_rows,
    stage_dim.cnt = dim_cnt.cnt AS ok
FROM stage_dim, dim_cnt;

DO $$
DECLARE
    v_stage_cnt bigint;
    v_dim_cnt bigint;
BEGIN
    SELECT s.cnt, d.cnt
    INTO v_stage_cnt, v_dim_cnt
    FROM (SELECT count(DISTINCT registrikood) AS cnt FROM mart_star_quality_stage_by_company) s
    CROSS JOIN (SELECT count(*) AS cnt FROM mart_star.dim_ettevote) d;

    IF v_stage_cnt <> v_dim_cnt THEN
        RAISE EXCEPTION 'MART_STAR dim_ettevote pariteet ei klapi: stage=%, dim=%', v_stage_cnt, v_dim_cnt;
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

\echo '=== MART_STAR MTA snapshot kuupaevade kontroll ==='
WITH stage_dates AS (
    SELECT count(DISTINCT snapshot_date) AS cnt, min(snapshot_date) AS min_date, max(snapshot_date) AS max_date
    FROM stage.mta_maksuvolglased
),
fact_dates AS (
    SELECT count(DISTINCT kuupaev) AS cnt, min(kuupaev) AS min_date, max(kuupaev) AS max_date
    FROM mart_star.fact_maksuvolg
)
SELECT
    stage_dates.cnt AS stage_mta_dates,
    fact_dates.cnt AS fact_dates,
    stage_dates.min_date AS stage_min_date,
    stage_dates.max_date AS stage_max_date,
    fact_dates.min_date AS fact_min_date,
    fact_dates.max_date AS fact_max_date,
    stage_dates.cnt = fact_dates.cnt
        AND stage_dates.min_date = fact_dates.min_date
        AND stage_dates.max_date = fact_dates.max_date AS ok
FROM stage_dates, fact_dates;

DO $$
DECLARE
    v_stage_cnt bigint;
    v_fact_cnt bigint;
    v_stage_min date;
    v_stage_max date;
    v_fact_min date;
    v_fact_max date;
BEGIN
    SELECT s.cnt, f.cnt, s.min_date, s.max_date, f.min_date, f.max_date
    INTO v_stage_cnt, v_fact_cnt, v_stage_min, v_stage_max, v_fact_min, v_fact_max
    FROM (
        SELECT count(DISTINCT snapshot_date) AS cnt, min(snapshot_date) AS min_date, max(snapshot_date) AS max_date
        FROM stage.mta_maksuvolglased
    ) s
    CROSS JOIN (
        SELECT count(DISTINCT kuupaev) AS cnt, min(kuupaev) AS min_date, max(kuupaev) AS max_date
        FROM mart_star.fact_maksuvolg
    ) f;

    IF v_stage_cnt <> v_fact_cnt OR v_stage_min <> v_fact_min OR v_stage_max <> v_fact_max THEN
        RAISE EXCEPTION 'MART_STAR MTA kuupaevade kontroll ei klapi: stage cnt/min/max=%/%/%, fact cnt/min/max=%/%/%',
            v_stage_cnt, v_stage_min, v_stage_max, v_fact_cnt, v_fact_min, v_fact_max;
    END IF;
END;
$$;

\echo '=== MART_STAR fact kuupaev = MTA snapshot_date kontroll ==='
SELECT
    count(*) AS bad_rows,
    CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ERROR' END AS status
FROM mart_star.fact_maksuvolg
WHERE kuupaev <> mta_snapshot_date;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*) INTO v_bad
    FROM mart_star.fact_maksuvolg
    WHERE kuupaev <> mta_snapshot_date;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR fact.kuupaev ei vordu mta_snapshot_date vaartusega, vigaseid ridu=%', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR faktisumma pariteet STAGE snapshotitega ==='
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

\echo '=== MART_STAR kuupaeva kaupa summa ja ridade pariteet ==='
WITH stage_by_date AS (
    SELECT
        mta_snapshot_date AS kuupaev,
        count(*) AS rows,
        COALESCE(sum(maksuvola_summa), 0) AS summa
    FROM mart_star_quality_stage_by_company
    GROUP BY mta_snapshot_date
),
fact_by_date AS (
    SELECT
        kuupaev,
        count(*) AS rows,
        COALESCE(sum(maksuvola_summa), 0) AS summa
    FROM mart_star.fact_maksuvolg
    GROUP BY kuupaev
)
SELECT
    COALESCE(s.kuupaev, f.kuupaev) AS kuupaev,
    s.rows AS stage_rows,
    f.rows AS fact_rows,
    s.summa AS stage_summa,
    f.summa AS fact_summa,
    s.rows = f.rows AND abs(s.summa - f.summa) < 0.01 AS ok
FROM stage_by_date s
FULL JOIN fact_by_date f ON f.kuupaev = s.kuupaev
ORDER BY kuupaev;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    WITH stage_by_date AS (
        SELECT
            mta_snapshot_date AS kuupaev,
            count(*) AS rows,
            COALESCE(sum(maksuvola_summa), 0) AS summa
        FROM mart_star_quality_stage_by_company
        GROUP BY mta_snapshot_date
    ),
    fact_by_date AS (
        SELECT
            kuupaev,
            count(*) AS rows,
            COALESCE(sum(maksuvola_summa), 0) AS summa
        FROM mart_star.fact_maksuvolg
        GROUP BY kuupaev
    )
    SELECT count(*)
    INTO v_bad
    FROM stage_by_date s
    FULL JOIN fact_by_date f ON f.kuupaev = s.kuupaev
    WHERE s.kuupaev IS NULL
       OR f.kuupaev IS NULL
       OR s.rows <> f.rows
       OR abs(s.summa - f.summa) >= 0.01;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR kuupaeva kaupa pariteet ei klapi, vigaseid kuupaevi=%', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR faktiridade pariteet STAGE ettevõte+snapshot grainiga ==='
WITH stage_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star_quality_stage_by_company
),
fact_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star.fact_maksuvolg
)
SELECT
    stage_cnt.cnt AS stage_company_snapshot_rows,
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

\echo '=== MART_STAR grain duplikaatide kontroll ==='
SELECT
    count(*) AS duplicate_company_snapshot_keys,
    CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ERROR' END AS status
FROM (
    SELECT dim_ettevote_id, kuupaev
    FROM mart_star.fact_maksuvolg
    GROUP BY dim_ettevote_id, kuupaev
    HAVING count(*) > 1
) d;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*)
    INTO v_bad
    FROM (
        SELECT dim_ettevote_id, kuupaev
        FROM mart_star.fact_maksuvolg
        GROUP BY dim_ettevote_id, kuupaev
        HAVING count(*) > 1
    ) d;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR faktis on ettevõte+snapshot kuupäev duplikaate: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR juhatuse muutuse abivaate kokkuvote ==='
SELECT
    count(*) AS ridu,
    count(DISTINCT mta_kuupaev) AS mta_kuupaevi,
    count(*) FILTER (WHERE juhatuse_muutuse_fakt = true) AS muutusega_ridu,
    count(*) FILTER (WHERE rik_vordlus_olemas = false) AS puuduliku_vordlusega_ridu,
    count(DISTINCT mta_kuupaev) FILTER (WHERE rik_vordlus_olemas = false) AS puuduliku_vordlusega_mta_kuupaevi
FROM mart_star.v_juhatuse_muutus_paeviti;

DO $$
DECLARE
    v_rows bigint;
BEGIN
    SELECT count(*) INTO v_rows
    FROM mart_star.v_juhatuse_muutus_paeviti;

    IF v_rows = 0 THEN
        RAISE EXCEPTION 'mart_star.v_juhatuse_muutus_paeviti ei tagastanud ridu';
    END IF;
END;
$$;

\echo '=== MART_STAR juhatuse abivaade vs fakt grain ==='
WITH helper_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star.v_juhatuse_muutus_paeviti
),
fact_cnt AS (
    SELECT count(*) AS cnt
    FROM mart_star.fact_maksuvolg
),
missing_helper AS (
    SELECT count(*) AS cnt
    FROM mart_star.fact_maksuvolg f
    LEFT JOIN mart_star.v_juhatuse_muutus_paeviti jm
           ON jm.mta_kuupaev = f.kuupaev
          AND jm.registrikood = f.registrikood
    WHERE jm.registrikood IS NULL
)
SELECT
    helper_cnt.cnt AS helper_rows,
    fact_cnt.cnt AS fact_rows,
    missing_helper.cnt AS fact_rows_without_helper,
    helper_cnt.cnt = fact_cnt.cnt AND missing_helper.cnt = 0 AS ok
FROM helper_cnt, fact_cnt, missing_helper;

DO $$
DECLARE
    v_helper_rows bigint;
    v_fact_rows bigint;
    v_missing bigint;
BEGIN
    SELECT h.cnt, f.cnt, m.cnt
    INTO v_helper_rows, v_fact_rows, v_missing
    FROM (SELECT count(*) AS cnt FROM mart_star.v_juhatuse_muutus_paeviti) h
    CROSS JOIN (SELECT count(*) AS cnt FROM mart_star.fact_maksuvolg) f
    CROSS JOIN (
        SELECT count(*) AS cnt
        FROM mart_star.fact_maksuvolg f
        LEFT JOIN mart_star.v_juhatuse_muutus_paeviti jm
               ON jm.mta_kuupaev = f.kuupaev
              AND jm.registrikood = f.registrikood
        WHERE jm.registrikood IS NULL
    ) m;

    IF v_helper_rows <> v_fact_rows OR v_missing <> 0 THEN
        RAISE EXCEPTION 'MART_STAR juhatuse abivaate grain ei klapi faktiga: helper=%, fact=%, missing=%',
            v_helper_rows, v_fact_rows, v_missing;
    END IF;
END;
$$;

\echo '=== MART_STAR juhatuse muutus faktis klapib abivaatega ==='
SELECT
    count(*) AS mismatched_rows,
    CASE WHEN count(*) = 0 THEN 'OK' ELSE 'ERROR' END AS status
FROM mart_star.fact_maksuvolg f
JOIN mart_star.v_juhatuse_muutus_paeviti jm
  ON jm.mta_kuupaev = f.kuupaev
 AND jm.registrikood = f.registrikood
WHERE f.juhatuse_muutuse_fakt IS DISTINCT FROM jm.juhatuse_muutuse_fakt
   OR f.lisatud_juhatuse_liikmeid <> jm.lisatud_juhatuse_liikmeid
   OR f.eemaldatud_juhatuse_liikmeid <> jm.eemaldatud_juhatuse_liikmeid;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*)
    INTO v_bad
    FROM mart_star.fact_maksuvolg f
    JOIN mart_star.v_juhatuse_muutus_paeviti jm
      ON jm.mta_kuupaev = f.kuupaev
     AND jm.registrikood = f.registrikood
    WHERE f.juhatuse_muutuse_fakt IS DISTINCT FROM jm.juhatuse_muutuse_fakt
       OR f.lisatud_juhatuse_liikmeid <> jm.lisatud_juhatuse_liikmeid
       OR f.eemaldatud_juhatuse_liikmeid <> jm.eemaldatud_juhatuse_liikmeid;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'MART_STAR faktis olev juhatuse muutus ei klapi abivaatega: % rida', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR juhatuse muutuse boolean ja arvud ==='
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

\echo '=== MART_STAR juhatuse muutus kuupaevade kaupa ==='
SELECT
    kuupaev,
    count(*) AS fact_rows,
    count(*) FILTER (WHERE juhatuse_muutuse_fakt = true) AS juhatuse_muutusega_fact_rows
FROM mart_star.fact_maksuvolg
GROUP BY kuupaev
ORDER BY kuupaev;

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
