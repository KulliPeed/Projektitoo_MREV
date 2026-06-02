\set ON_ERROR_STOP on
\pset pager off

\echo '=== MART_STAR objektid olemas ja ainult lubatud tabelid ==='
WITH expected(table_name) AS (
    VALUES
        ('dim_aeg'),
        ('dim_ettevote'),
        ('dim_vanuse_grupp'),
        ('fact_maksuvolg')
),
actual AS (
    SELECT table_name, table_type
    FROM information_schema.tables
    WHERE table_schema = 'mart_star'
)
SELECT
    COALESCE(e.table_name, a.table_name) AS table_name,
    a.table_type,
    CASE
        WHEN e.table_name IS NOT NULL AND a.table_name IS NOT NULL AND a.table_type = 'BASE TABLE' THEN 'OK'
        WHEN e.table_name IS NULL THEN 'ERROR: üleliigne objekt'
        ELSE 'ERROR: puudub'
    END AS status
FROM expected e
FULL JOIN actual a ON a.table_name = e.table_name
ORDER BY table_name;

DO $$
DECLARE
    v_bad text;
BEGIN
    WITH expected(table_name) AS (
        VALUES
            ('dim_aeg'),
            ('dim_ettevote'),
            ('dim_vanuse_grupp'),
            ('fact_maksuvolg')
    ),
    actual AS (
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = 'mart_star'
    )
    SELECT string_agg(COALESCE(e.table_name, a.table_name), ', ' ORDER BY COALESCE(e.table_name, a.table_name))
    INTO v_bad
    FROM expected e
    FULL JOIN actual a ON a.table_name = e.table_name
    WHERE e.table_name IS NULL
       OR a.table_name IS NULL
       OR a.table_type <> 'BASE TABLE';

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MART_STAR objektide kontroll ebaonnestus: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR veerud vastavad pildil olevale tähtskeemile ==='
WITH expected(table_name, column_name, ordinal_position) AS (
    VALUES
        ('dim_ettevote', 'ettevote_id', 1),
        ('dim_ettevote', 'registrikood', 2),
        ('dim_ettevote', 'nimi', 3),
        ('dim_aeg', 'kuupaev', 1),
        ('dim_aeg', 'paev', 2),
        ('dim_aeg', 'kuu', 3),
        ('dim_aeg', 'aasta', 4),
        ('dim_vanuse_grupp', 'maksuvola_vanuse_grupp', 1),
        ('dim_vanuse_grupp', 'min_paevi', 2),
        ('dim_vanuse_grupp', 'max_paevi', 3),
        ('dim_vanuse_grupp', 'jarjestus', 4),
        ('fact_maksuvolg', 'id', 1),
        ('fact_maksuvolg', 'dim_ettevote_id', 2),
        ('fact_maksuvolg', 'kuupaev', 3),
        ('fact_maksuvolg', 'maksuvola_summa', 4),
        ('fact_maksuvolg', 'maksuvola_vanuse_grupp', 5),
        ('fact_maksuvolg', 'juhatuse_muutuse_fakt', 6)
),
actual AS (
    SELECT table_name, column_name, ordinal_position
    FROM information_schema.columns
    WHERE table_schema = 'mart_star'
)
SELECT
    COALESCE(e.table_name, a.table_name) AS table_name,
    COALESCE(e.column_name, a.column_name) AS column_name,
    e.ordinal_position AS expected_position,
    a.ordinal_position AS actual_position,
    CASE
        WHEN e.table_name IS NOT NULL
         AND a.table_name IS NOT NULL
         AND e.ordinal_position = a.ordinal_position THEN 'OK'
        WHEN e.table_name IS NULL THEN 'ERROR: üleliigne veerg'
        ELSE 'ERROR: puudub või vale järjekord'
    END AS status
FROM expected e
FULL JOIN actual a
       ON a.table_name = e.table_name
      AND a.column_name = e.column_name
ORDER BY COALESCE(e.table_name, a.table_name), COALESCE(e.ordinal_position, a.ordinal_position);

DO $$
DECLARE
    v_bad text;
BEGIN
    WITH expected(table_name, column_name, ordinal_position) AS (
        VALUES
            ('dim_ettevote', 'ettevote_id', 1),
            ('dim_ettevote', 'registrikood', 2),
            ('dim_ettevote', 'nimi', 3),
            ('dim_aeg', 'kuupaev', 1),
            ('dim_aeg', 'paev', 2),
            ('dim_aeg', 'kuu', 3),
            ('dim_aeg', 'aasta', 4),
            ('dim_vanuse_grupp', 'maksuvola_vanuse_grupp', 1),
            ('dim_vanuse_grupp', 'min_paevi', 2),
            ('dim_vanuse_grupp', 'max_paevi', 3),
            ('dim_vanuse_grupp', 'jarjestus', 4),
            ('fact_maksuvolg', 'id', 1),
            ('fact_maksuvolg', 'dim_ettevote_id', 2),
            ('fact_maksuvolg', 'kuupaev', 3),
            ('fact_maksuvolg', 'maksuvola_summa', 4),
            ('fact_maksuvolg', 'maksuvola_vanuse_grupp', 5),
            ('fact_maksuvolg', 'juhatuse_muutuse_fakt', 6)
    ),
    actual AS (
        SELECT table_name, column_name, ordinal_position
        FROM information_schema.columns
        WHERE table_schema = 'mart_star'
    )
    SELECT string_agg(COALESCE(e.table_name, a.table_name) || '.' || COALESCE(e.column_name, a.column_name), ', '
                      ORDER BY COALESCE(e.table_name, a.table_name), COALESCE(e.ordinal_position, a.ordinal_position))
    INTO v_bad
    FROM expected e
    FULL JOIN actual a
           ON a.table_name = e.table_name
          AND a.column_name = e.column_name
    WHERE e.table_name IS NULL
       OR a.table_name IS NULL
       OR e.ordinal_position <> a.ordinal_position;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MART_STAR veergude kontroll ebaonnestus: %', v_bad;
    END IF;
END;
$$;

\echo '=== MART_STAR kvaliteedi ajutine STAGE grain ==='
CREATE TEMP TABLE mart_star_quality_stage_by_company AS
SELECT
    NULLIF(btrim(m.registrikood), '') AS registrikood,
    m.snapshot_date AS kuupaev,
    COALESCE(sum(COALESCE(m.maksuvolg, 0)), 0)::numeric(18,2) AS maksuvola_summa
FROM stage.mta_maksuvolglased m
WHERE NULLIF(btrim(m.registrikood), '') IS NOT NULL
  AND m.snapshot_date IS NOT NULL
GROUP BY
    NULLIF(btrim(m.registrikood), ''),
    m.snapshot_date;

\echo '=== MART_STAR rea-arvud ==='
SELECT 'mart_star.dim_ettevote' AS object_name, count(*) AS row_count FROM mart_star.dim_ettevote
UNION ALL
SELECT 'mart_star.dim_aeg', count(*) FROM mart_star.dim_aeg
UNION ALL
SELECT 'mart_star.dim_vanuse_grupp', count(*) FROM mart_star.dim_vanuse_grupp
UNION ALL
SELECT 'mart_star.fact_maksuvolg', count(*) FROM mart_star.fact_maksuvolg
ORDER BY object_name;

\echo '=== Kõik STAGE MTA kuupäevad on faktis ==='
WITH stage_dates AS (
    SELECT count(DISTINCT snapshot_date) AS cnt
    FROM stage.mta_maksuvolglased
),
fact_dates AS (
    SELECT count(DISTINCT kuupaev) AS cnt
    FROM mart_star.fact_maksuvolg
)
SELECT
    stage_dates.cnt AS stage_snapshot_count,
    fact_dates.cnt AS fact_snapshot_count,
    stage_dates.cnt = fact_dates.cnt AS ok
FROM stage_dates, fact_dates;

DO $$
DECLARE
    v_stage_cnt bigint;
    v_fact_cnt bigint;
BEGIN
    SELECT s.cnt, f.cnt
    INTO v_stage_cnt, v_fact_cnt
    FROM (
        SELECT count(DISTINCT snapshot_date) AS cnt
        FROM stage.mta_maksuvolglased
    ) s
    CROSS JOIN (
        SELECT count(DISTINCT kuupaev) AS cnt
        FROM mart_star.fact_maksuvolg
    ) f;

    IF v_stage_cnt <> v_fact_cnt THEN
        RAISE EXCEPTION 'MTA snapshot kuupäevade arv ei klapi: stage=%, fact=%', v_stage_cnt, v_fact_cnt;
    END IF;
END;
$$;

\echo '=== Faktiridade arv iga kuupäeva kohta ==='
WITH stage_cnt AS (
    SELECT
        kuupaev,
        count(*) AS stage_distinct_registrikoodid
    FROM mart_star_quality_stage_by_company
    GROUP BY kuupaev
),
fact_cnt AS (
    SELECT
        kuupaev,
        count(*) AS fact_rows
    FROM mart_star.fact_maksuvolg
    GROUP BY kuupaev
)
SELECT
    s.kuupaev,
    s.stage_distinct_registrikoodid,
    f.fact_rows,
    s.stage_distinct_registrikoodid = f.fact_rows AS ok
FROM stage_cnt s
LEFT JOIN fact_cnt f
  ON f.kuupaev = s.kuupaev
ORDER BY s.kuupaev;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    WITH stage_cnt AS (
        SELECT kuupaev, count(*) AS stage_distinct_registrikoodid
        FROM mart_star_quality_stage_by_company
        GROUP BY kuupaev
    ),
    fact_cnt AS (
        SELECT kuupaev, count(*) AS fact_rows
        FROM mart_star.fact_maksuvolg
        GROUP BY kuupaev
    )
    SELECT count(*)
    INTO v_bad
    FROM stage_cnt s
    LEFT JOIN fact_cnt f ON f.kuupaev = s.kuupaev
    WHERE f.kuupaev IS NULL
       OR s.stage_distinct_registrikoodid <> f.fact_rows;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'Faktiridade arv ei klapi STAGE registrikoodidega, vigaseid kuupäevi=%', v_bad;
    END IF;
END;
$$;

\echo '=== Maksuvõla summa iga kuupäeva kohta ==='
WITH stage_sum AS (
    SELECT
        kuupaev,
        sum(maksuvola_summa) AS stage_sum
    FROM mart_star_quality_stage_by_company
    GROUP BY kuupaev
),
fact_sum AS (
    SELECT
        kuupaev,
        sum(maksuvola_summa) AS fact_sum
    FROM mart_star.fact_maksuvolg
    GROUP BY kuupaev
)
SELECT
    s.kuupaev,
    s.stage_sum,
    f.fact_sum,
    abs(s.stage_sum - f.fact_sum) < 0.01 AS ok
FROM stage_sum s
LEFT JOIN fact_sum f
  ON f.kuupaev = s.kuupaev
ORDER BY s.kuupaev;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    WITH stage_sum AS (
        SELECT kuupaev, sum(maksuvola_summa) AS stage_sum
        FROM mart_star_quality_stage_by_company
        GROUP BY kuupaev
    ),
    fact_sum AS (
        SELECT kuupaev, sum(maksuvola_summa) AS fact_sum
        FROM mart_star.fact_maksuvolg
        GROUP BY kuupaev
    )
    SELECT count(*)
    INTO v_bad
    FROM stage_sum s
    LEFT JOIN fact_sum f ON f.kuupaev = s.kuupaev
    WHERE f.kuupaev IS NULL
       OR abs(s.stage_sum - f.fact_sum) >= 0.01;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'Maksuvõla summa ei klapi kuupäeva kaupa, vigaseid kuupäevi=%', v_bad;
    END IF;
END;
$$;

\echo '=== FK terviklikkus ==='
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
        RAISE EXCEPTION 'FK kontroll leidis vigaseid ridu: %', v_bad;
    END IF;
END;
$$;

\echo '=== Juhatuse muutuse boolean kontroll ==='
SELECT
    count(*) AS null_juhatuse_muutuse_fakt
FROM mart_star.fact_maksuvolg
WHERE juhatuse_muutuse_fakt IS NULL;

DO $$
DECLARE
    v_bad bigint;
BEGIN
    SELECT count(*) INTO v_bad
    FROM mart_star.fact_maksuvolg
    WHERE juhatuse_muutuse_fakt IS NULL;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'juhatuse_muutuse_fakt NULL ridu=%', v_bad;
    END IF;
END;
$$;

\echo '=== Grain duplikaatide kontroll ==='
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
        RAISE EXCEPTION 'Faktis on ettevõte+snapshot duplikaate: %', v_bad;
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
