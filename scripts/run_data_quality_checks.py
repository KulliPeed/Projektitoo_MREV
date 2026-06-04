#!/usr/bin/env python3
import csv
import hashlib
import json
import os
import sys
import uuid
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from pathlib import Path
from typing import Any

import ijson
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "andmeprojekt")
DB_USER = os.environ.get("DB_USER", "andrus")
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD") or os.environ.get("DB_PASSWORD")

PROJECT_DIR = Path(os.environ.get("PROJECT_DIR", Path(__file__).resolve().parents[1]))
BAD_ROWS_SAMPLE_LIMIT = int(os.environ.get("DATA_QUALITY_BAD_ROWS_LIMIT", "1000"))
FAIL_PIPELINE = os.environ.get("DATA_QUALITY_FAIL_PIPELINE", "false").lower() == "true"
PIPELINE_NAME = os.environ.get("DATA_QUALITY_PIPELINE_NAME", "manual")
TRIGGERED_BY = os.environ.get("DATA_QUALITY_TRIGGERED_BY", os.environ.get("USER", "unknown"))

MTA_HEADERS = [
    "Andmed on seisuga",
    "Registrikood",
    "Nimi",
    "Maksuvõlg",
    "sh vaidlustatud",
    "sh tasumisgraafikus",
    "Tasumisgraafiku lõppkuupäev",
    "Vanima tasumata nõude tasumise tähtpäev",
]

QUALITY_DDL = r"""
CREATE SCHEMA IF NOT EXISTS quality;
CREATE TABLE IF NOT EXISTS quality.data_quality_runs (
    run_id uuid PRIMARY KEY,
    started_at timestamp NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamp NULL,
    triggered_by text NULL,
    pipeline_name text NULL,
    status text NOT NULL DEFAULT 'RUNNING',
    message text NULL
);
CREATE TABLE IF NOT EXISTS quality.data_quality_results (
    id bigserial PRIMARY KEY,
    run_id uuid NOT NULL REFERENCES quality.data_quality_runs(run_id),
    checked_at timestamp NOT NULL DEFAULT clock_timestamp(),
    layer_name text NOT NULL,
    check_name text NOT NULL,
    check_group text NULL,
    object_name text NOT NULL,
    source_name text NULL,
    status text NOT NULL,
    severity text NOT NULL DEFAULT 'ERROR',
    expected_value text NULL,
    actual_value text NULL,
    failed_count bigint NULL,
    total_count bigint NULL,
    snapshot_date date NULL,
    data_as_of date NULL,
    message text NULL,
    details jsonb NULL,
    CONSTRAINT chk_data_quality_results_status
        CHECK (status IN ('PASS', 'WARN', 'FAIL', 'SKIPPED', 'ERROR')),
    CONSTRAINT chk_data_quality_results_severity
        CHECK (severity IN ('INFO', 'WARN', 'ERROR', 'FATAL'))
);
CREATE TABLE IF NOT EXISTS quality.data_quality_bad_rows (
    id bigserial PRIMARY KEY,
    run_id uuid NOT NULL REFERENCES quality.data_quality_runs(run_id),
    checked_at timestamp NOT NULL DEFAULT clock_timestamp(),
    layer_name text NOT NULL,
    check_name text NOT NULL,
    object_name text NOT NULL,
    snapshot_date date NULL,
    data_as_of date NULL,
    source_name text NULL,
    source_file text NULL,
    row_no bigint NULL,
    business_key text NULL,
    reason text NOT NULL,
    row_data jsonb NULL
);
CREATE TABLE IF NOT EXISTS quality.source_structure_snapshots (
    id bigserial PRIMARY KEY,
    captured_at timestamp NOT NULL DEFAULT clock_timestamp(),
    source_name text NOT NULL,
    object_name text NOT NULL,
    snapshot_date date NULL,
    data_as_of date NULL,
    structure_signature text NOT NULL,
    structure_json jsonb NOT NULL,
    is_current boolean NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS idx_data_quality_runs_started_at
ON quality.data_quality_runs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_data_quality_results_run_check
ON quality.data_quality_results(run_id, layer_name, check_name);
CREATE INDEX IF NOT EXISTS idx_data_quality_results_status
ON quality.data_quality_results(status, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_data_quality_bad_rows_run_check
ON quality.data_quality_bad_rows(run_id, layer_name, check_name);
CREATE INDEX IF NOT EXISTS idx_source_structure_snapshots_current
ON quality.source_structure_snapshots(source_name, object_name, is_current, captured_at DESC);
ALTER TABLE quality.data_quality_runs
    ALTER COLUMN started_at SET DEFAULT clock_timestamp();
ALTER TABLE quality.data_quality_results
    ALTER COLUMN checked_at SET DEFAULT clock_timestamp();
ALTER TABLE quality.data_quality_bad_rows
    ALTER COLUMN checked_at SET DEFAULT clock_timestamp();
ALTER TABLE quality.source_structure_snapshots
    ALTER COLUMN captured_at SET DEFAULT clock_timestamp();
CREATE OR REPLACE VIEW quality.v_data_quality_latest AS
WITH latest_run AS (
    SELECT run_id
    FROM quality.data_quality_runs
    ORDER BY started_at DESC
    LIMIT 1
)
SELECT r.*
FROM quality.data_quality_results r
JOIN latest_run lr ON lr.run_id = r.run_id
ORDER BY r.layer_name, r.check_name, r.source_name NULLS LAST;
CREATE OR REPLACE VIEW quality.v_data_quality_history AS
SELECT
    r.checked_at,
    q.started_at,
    q.finished_at,
    q.pipeline_name,
    q.status AS run_status,
    r.run_id,
    r.layer_name,
    r.check_name,
    r.check_group,
    r.object_name,
    r.source_name,
    r.status,
    r.severity,
    r.failed_count,
    r.total_count,
    r.snapshot_date,
    r.data_as_of,
    r.message,
    r.actual_value,
    r.expected_value
FROM quality.data_quality_results r
JOIN quality.data_quality_runs q ON q.run_id = r.run_id;
CREATE OR REPLACE VIEW quality.v_data_quality_summary AS
SELECT
    q.run_id,
    q.started_at,
    q.finished_at,
    q.pipeline_name,
    q.status AS run_status,
    count(r.*) AS checks_total,
    count(*) FILTER (WHERE r.status = 'PASS') AS checks_pass,
    count(*) FILTER (WHERE r.status = 'WARN') AS checks_warn,
    count(*) FILTER (WHERE r.status = 'FAIL') AS checks_fail,
    count(*) FILTER (WHERE r.status = 'ERROR') AS checks_error,
    count(*) FILTER (WHERE r.status = 'SKIPPED') AS checks_skipped
FROM quality.data_quality_runs q
LEFT JOIN quality.data_quality_results r ON r.run_id = q.run_id
GROUP BY q.run_id, q.started_at, q.finished_at, q.pipeline_name, q.status;
CREATE OR REPLACE VIEW quality.v_data_quality_bad_rows AS
SELECT *
FROM quality.data_quality_bad_rows
ORDER BY checked_at DESC, check_name, id DESC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_readonly') THEN
        GRANT CONNECT ON DATABASE andmeprojekt TO superset_readonly;
        GRANT USAGE ON SCHEMA quality TO superset_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA quality TO superset_readonly;
        GRANT SELECT, USAGE ON ALL SEQUENCES IN SCHEMA quality TO superset_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA quality GRANT SELECT ON TABLES TO superset_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA quality GRANT SELECT, USAGE ON SEQUENCES TO superset_readonly;
    END IF;
END $$;
"""


@dataclass
class QualityResult:
    layer_name: str
    check_name: str
    check_group: str
    object_name: str
    source_name: str | None
    status: str
    severity: str = "ERROR"
    expected_value: str | None = None
    actual_value: str | None = None
    failed_count: int | None = None
    total_count: int | None = None
    snapshot_date: date | None = None
    data_as_of: date | None = None
    message: str | None = None
    details: dict[str, Any] | None = None


def json_default(value: Any) -> Any:
    if isinstance(value, Decimal):
        if value == value.to_integral_value():
            return int(value)
        return float(value)
    if isinstance(value, date):
        return value.isoformat()
    raise TypeError(f"Object of type {type(value).__name__} is not JSON serializable")


def stable_signature(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=json_default)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def connect():
    if not DB_PASSWORD:
        raise RuntimeError("Määra POSTGRES_PASSWORD või DB_PASSWORD keskkonnamuutuja.")
    return psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        row_factory=dict_row,
    )


def ensure_quality_schema(cur) -> None:
    cur.execute(QUALITY_DDL)


def scalar(cur, sql: str, params: tuple[Any, ...] = ()) -> Any:
    cur.execute(sql, params)
    row = cur.fetchone()
    if row is None:
        return None
    return next(iter(row.values()))


def fetchone(cur, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
    cur.execute(sql, params)
    return cur.fetchone()


def insert_result(cur, run_id: uuid.UUID, result: QualityResult) -> None:
    cur.execute(
        """
        INSERT INTO quality.data_quality_results (
            run_id,
            layer_name,
            check_name,
            check_group,
            object_name,
            source_name,
            status,
            severity,
            expected_value,
            actual_value,
            failed_count,
            total_count,
            snapshot_date,
            data_as_of,
            message,
            details
        )
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """,
        (
            str(run_id),
            result.layer_name,
            result.check_name,
            result.check_group,
            result.object_name,
            result.source_name,
            result.status,
            result.severity,
            result.expected_value,
            result.actual_value,
            result.failed_count,
            result.total_count,
            result.snapshot_date,
            result.data_as_of,
            result.message,
            Jsonb(result.details or {}, dumps=lambda obj: json.dumps(obj, ensure_ascii=False, default=json_default)),
        ),
    )


def insert_bad_rows(cur, run_id: uuid.UUID, sql: str, params: tuple[Any, ...] = ()) -> None:
    cur.execute(sql, (str(run_id),) + params + (BAD_ROWS_SAMPLE_LIMIT,))


def start_run(cur, run_id: uuid.UUID) -> None:
    cur.execute(
        """
        INSERT INTO quality.data_quality_runs (run_id, triggered_by, pipeline_name, status, message)
        VALUES (%s, %s, %s, 'RUNNING', %s)
        """,
        (str(run_id), TRIGGERED_BY, PIPELINE_NAME, "Data quality runner started."),
    )


def finish_run(cur, run_id: uuid.UUID, status: str, message: str) -> None:
    cur.execute(
        """
        UPDATE quality.data_quality_runs
        SET finished_at = clock_timestamp(), status = %s, message = %s
        WHERE run_id = %s
        """,
        (status, message, str(run_id)),
    )


def latest_dates(cur) -> dict[str, Any]:
    return {
        "mta_data_as_of": scalar(cur, "SELECT max(data_as_of) FROM stage.mta_maksuvolglased"),
        "mta_snapshot_date": scalar(cur, "SELECT max(snapshot_date) FROM stage.mta_maksuvolglased"),
        "rik_snapshot_date": scalar(cur, "SELECT max(snapshot_date) FROM stage.rik_ettevotted"),
        "fact_kuupaev": scalar(cur, "SELECT max(kuupaev) FROM mart_star.fact_maksuvolg"),
    }


def result_from_counts(
    *,
    layer_name: str,
    check_name: str,
    check_group: str,
    object_name: str,
    source_name: str,
    failed: int,
    total: int | None,
    expected: str,
    actual: str,
    message: str,
    snapshot_date: date | None = None,
    data_as_of: date | None = None,
    severity: str = "ERROR",
    warn: bool = False,
    details: dict[str, Any] | None = None,
) -> QualityResult:
    status = "PASS" if failed == 0 else ("WARN" if warn else "FAIL")
    return QualityResult(
        layer_name=layer_name,
        check_name=check_name,
        check_group=check_group,
        object_name=object_name,
        source_name=source_name,
        status=status,
        severity="INFO" if status == "PASS" else ("WARN" if status == "WARN" else severity),
        expected_value=expected,
        actual_value=actual,
        failed_count=failed,
        total_count=total,
        snapshot_date=snapshot_date,
        data_as_of=data_as_of,
        message=message,
        details=details or {},
    )


def check_mta_raw_stage_parity(cur, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT
            (SELECT count(*) FROM raw.mta_maksuvolglased_csv WHERE data_as_of = %s) AS raw_count,
            (SELECT count(*) FROM stage.mta_maksuvolglased WHERE data_as_of = %s) AS stage_count
        """,
        (data_as_of, data_as_of),
    )
    raw_count = row["raw_count"] or 0
    stage_count = row["stage_count"] or 0
    failed = 0 if raw_count == stage_count else abs(raw_count - stage_count)
    return result_from_counts(
        layer_name="RAW_STAGE",
        check_name="mta_raw_stage_parity",
        check_group="parity",
        object_name="stage.mta_maksuvolglased",
        source_name="MTA",
        failed=failed,
        total=raw_count,
        expected=f"stage_count={raw_count}",
        actual=f"raw_count={raw_count}; stage_count={stage_count}",
        data_as_of=data_as_of,
        message="MTA RAW ja STAGE ridade arv ei klapi.",
    )


def check_rik_raw_stage_parity(cur, dates) -> QualityResult:
    snapshot_date = dates["rik_snapshot_date"]
    row = fetchone(
        cur,
        """
        SELECT
            (SELECT count(*) FROM raw.rik_kaardile_kantud_isikud_json WHERE snapshot_date = %s) AS raw_count,
            (SELECT count(*) FROM stage.rik_ettevotted WHERE snapshot_date = %s) AS stage_count
        """,
        (snapshot_date, snapshot_date),
    )
    raw_count = row["raw_count"] or 0
    stage_count = row["stage_count"] or 0
    failed = 0 if raw_count == stage_count else abs(raw_count - stage_count)
    return result_from_counts(
        layer_name="RAW_STAGE",
        check_name="rik_raw_stage_parity",
        check_group="parity",
        object_name="stage.rik_ettevotted",
        source_name="RIK",
        failed=failed,
        total=raw_count,
        expected=f"stage_count={raw_count}",
        actual=f"raw_count={raw_count}; stage_count={stage_count}",
        snapshot_date=snapshot_date,
        message="RIK RAW ja STAGE ridade arv ei klapi.",
    )


def check_stage_mta_bad_registrikood(cur, run_id, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE registrikood IS NULL OR registrikood !~ '^[0-9]{8}$') AS failed_count
        FROM stage.mta_maksuvolglased
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date, data_as_of,
                source_name, source_file, row_no, business_key, reason, row_data
            )
            SELECT %s, 'STAGE', 'stage_mta_bad_registrikood', 'stage.mta_maksuvolglased',
                   snapshot_date, data_as_of, 'MTA', source_file, row_no, registrikood,
                   'MTA registrikood ei vasta formaadile või puudub.', to_jsonb(t)
            FROM stage.mta_maksuvolglased t
            WHERE data_as_of = %s
              AND (registrikood IS NULL OR registrikood !~ '^[0-9]{8}$')
            LIMIT %s
            """,
            (data_as_of,),
        )
    return result_from_counts(
        layer_name="STAGE",
        check_name="stage_mta_bad_registrikood",
        check_group="format_validation",
        object_name="stage.mta_maksuvolglased",
        source_name="MTA",
        failed=failed,
        total=row["total_count"],
        expected="0 bad registrikood rows",
        actual=f"{failed} bad registrikood rows",
        data_as_of=data_as_of,
        message="MTA registrikood ei vasta formaadile või puudub.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_stage_mta_null_maksuvolg(cur, run_id, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE maksuvolg IS NULL) AS failed_count
        FROM stage.mta_maksuvolglased
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date, data_as_of,
                source_name, source_file, row_no, business_key, reason, row_data
            )
            SELECT %s, 'STAGE', 'stage_mta_null_maksuvolg', 'stage.mta_maksuvolglased',
                   snapshot_date, data_as_of, 'MTA', source_file, row_no, registrikood,
                   'MTA maksuvõlg sisaldab NULL väärtust.', to_jsonb(t)
            FROM stage.mta_maksuvolglased t
            WHERE data_as_of = %s AND maksuvolg IS NULL
            LIMIT %s
            """,
            (data_as_of,),
        )
    return result_from_counts(
        layer_name="STAGE",
        check_name="stage_mta_null_maksuvolg",
        check_group="value_validation",
        object_name="stage.mta_maksuvolglased",
        source_name="MTA",
        failed=failed,
        total=row["total_count"],
        expected="0 NULL maksuvolg rows",
        actual=f"{failed} NULL maksuvolg rows",
        data_as_of=data_as_of,
        message="MTA maksuvõlg sisaldab NULL väärtusi.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_stage_mta_negative_maksuvolg(cur, run_id, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE maksuvolg < 0) AS failed_count
        FROM stage.mta_maksuvolglased
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date, data_as_of,
                source_name, source_file, row_no, business_key, reason, row_data
            )
            SELECT %s, 'STAGE', 'stage_mta_negative_maksuvolg', 'stage.mta_maksuvolglased',
                   snapshot_date, data_as_of, 'MTA', source_file, row_no, registrikood,
                   'MTA maksuvõlg sisaldab negatiivset väärtust.', to_jsonb(t)
            FROM stage.mta_maksuvolglased t
            WHERE data_as_of = %s AND maksuvolg < 0
            LIMIT %s
            """,
            (data_as_of,),
        )
    return result_from_counts(
        layer_name="STAGE",
        check_name="stage_mta_negative_maksuvolg",
        check_group="value_validation",
        object_name="stage.mta_maksuvolglased",
        source_name="MTA",
        failed=failed,
        total=row["total_count"],
        expected="0 negative maksuvolg rows",
        actual=f"{failed} negative maksuvolg rows",
        data_as_of=data_as_of,
        message="MTA maksuvõlg sisaldab negatiivseid väärtusi.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_stage_rik_bad_registrikood(cur, run_id, dates) -> QualityResult:
    snapshot_date = dates["rik_snapshot_date"]
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE registrikood IS NULL OR registrikood !~ '^[0-9]{8}$') AS failed_count
        FROM stage.rik_ettevotted
        WHERE snapshot_date = %s
        """,
        (snapshot_date,),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date,
                source_name, source_file, row_no, business_key, reason, row_data
            )
            SELECT %s, 'STAGE', 'stage_rik_bad_registrikood', 'stage.rik_ettevotted',
                   snapshot_date, 'RIK', source_file, row_no, registrikood,
                   'RIK registrikood ei vasta formaadile või on tühi.', to_jsonb(t)
            FROM stage.rik_ettevotted t
            WHERE snapshot_date = %s
              AND (registrikood IS NULL OR registrikood !~ '^[0-9]{8}$')
            LIMIT %s
            """,
            (snapshot_date,),
        )
    return result_from_counts(
        layer_name="STAGE",
        check_name="stage_rik_bad_registrikood",
        check_group="format_validation",
        object_name="stage.rik_ettevotted",
        source_name="RIK",
        failed=failed,
        total=row["total_count"],
        expected="0 bad registrikood rows",
        actual=f"{failed} bad registrikood rows",
        snapshot_date=snapshot_date,
        message="RIK registrikood ei vasta formaadile või on tühi.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_stage_rik_duplicate_registrikood(cur, run_id, dates) -> QualityResult:
    snapshot_date = dates["rik_snapshot_date"]
    row = fetchone(
        cur,
        """
        WITH duplicate_groups AS (
            SELECT registrikood, count(*) AS rows_in_group
            FROM stage.rik_ettevotted
            WHERE snapshot_date = %s
            GROUP BY registrikood
            HAVING count(*) > 1
        )
        SELECT
            (SELECT count(*) FROM stage.rik_ettevotted WHERE snapshot_date = %s) AS total_count,
            count(*) AS failed_count,
            COALESCE(sum(rows_in_group), 0) AS duplicate_rows
        FROM duplicate_groups
        """,
        (snapshot_date, snapshot_date),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date,
                source_name, business_key, reason, row_data
            )
            SELECT %s, 'STAGE', 'stage_rik_duplicate_registrikood', 'stage.rik_ettevotted',
                   snapshot_date, 'RIK', registrikood,
                   'RIK snapshotis esineb duplikaatregistrikoode.',
                   jsonb_build_object('snapshot_date', snapshot_date, 'registrikood', registrikood, 'rows_in_group', count(*))
            FROM stage.rik_ettevotted
            WHERE snapshot_date = %s
            GROUP BY snapshot_date, registrikood
            HAVING count(*) > 1
            LIMIT %s
            """,
            (snapshot_date,),
        )
    return result_from_counts(
        layer_name="STAGE",
        check_name="stage_rik_duplicate_registrikood",
        check_group="uniqueness",
        object_name="stage.rik_ettevotted",
        source_name="RIK",
        failed=failed,
        total=row["total_count"],
        expected="0 duplicate registrikood groups",
        actual=f"{failed} duplicate groups; duplicate_rows={row['duplicate_rows']}",
        snapshot_date=snapshot_date,
        message="RIK snapshotis esineb duplikaatregistrikoode.",
        details={"duplicate_rows": row["duplicate_rows"], "bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_mart_star_required_columns(cur, _dates) -> QualityResult:
    required = [
        ("dim_ettevote", "ettevote_id"),
        ("dim_ettevote", "registrikood"),
        ("dim_ettevote", "nimi"),
        ("dim_aeg", "kuupaev"),
        ("dim_vanuse_grupp", "maksuvola_vanuse_grupp"),
        ("fact_maksuvolg", "id"),
        ("fact_maksuvolg", "dim_ettevote_id"),
        ("fact_maksuvolg", "kuupaev"),
        ("fact_maksuvolg", "maksuvola_summa"),
        ("fact_maksuvolg", "maksuvola_vanuse_grupp"),
        ("fact_maksuvolg", "juhatuse_muutuse_fakt"),
    ]
    cur.execute(
        """
        SELECT table_name, column_name
        FROM information_schema.columns
        WHERE table_schema = 'mart_star'
          AND table_name = ANY(%s)
        """,
        ([table for table, _ in required],),
    )
    existing = {(row["table_name"], row["column_name"]) for row in cur.fetchall()}
    missing = [f"{table}.{column}" for table, column in required if (table, column) not in existing]
    return result_from_counts(
        layer_name="MART_STAR",
        check_name="mart_star_required_columns",
        check_group="schema_validation",
        object_name="mart_star",
        source_name="MART_STAR",
        failed=len(missing),
        total=len(required),
        expected="all required mart_star columns exist",
        actual="missing=" + ",".join(missing) if missing else "missing=0",
        message="MART_STAR veerud puuduvad.",
        details={"missing_columns": missing, "required_columns": [f"{t}.{c}" for t, c in required]},
    )


def check_mart_star_snapshot_parity(cur, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        WITH stage_dates AS (
            SELECT DISTINCT data_as_of AS kuupaev
            FROM stage.mta_maksuvolglased
            WHERE data_as_of IS NOT NULL
        ),
        fact_dates AS (
            SELECT DISTINCT kuupaev
            FROM mart_star.fact_maksuvolg
        ),
        missing AS (
            SELECT s.kuupaev
            FROM stage_dates s
            LEFT JOIN fact_dates f ON f.kuupaev = s.kuupaev
            WHERE f.kuupaev IS NULL
        )
        SELECT
            (SELECT count(*) FROM stage_dates) AS stage_dates,
            (SELECT count(*) FROM fact_dates) AS fact_dates,
            (SELECT count(*) FROM missing) AS missing_count,
            (SELECT jsonb_agg(kuupaev ORDER BY kuupaev) FROM missing) AS missing_dates
        """,
    )
    failed = row["missing_count"] or 0
    return result_from_counts(
        layer_name="MART_STAR",
        check_name="mart_star_snapshot_parity",
        check_group="parity",
        object_name="mart_star.fact_maksuvolg",
        source_name="MART_STAR",
        failed=failed,
        total=row["stage_dates"],
        expected="all stage data_as_of dates exist in fact kuupaev",
        actual=f"stage_dates={row['stage_dates']}; fact_dates={row['fact_dates']}; missing={failed}",
        message="FACT snapshotide arv ei klapi STAGE snapshotidega.",
        details={"missing_dates": row["missing_dates"] or []},
    )


def check_raw_data_as_of_idempotent(cur, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT
            count(*) AS total_count,
            count(row_hash) AS hash_count,
            count(DISTINCT row_hash) AS distinct_hashes,
            count(DISTINCT source_file) AS source_files,
            count(DISTINCT file_sha256) AS file_hashes
        FROM raw.mta_maksuvolglased_csv
        WHERE data_as_of = %s
        """,
        (data_as_of,),
    )
    total = row["total_count"] or 0
    missing_hash = total - (row["hash_count"] or 0)
    duplicate_hashes = total - (row["distinct_hashes"] or 0) if missing_hash == 0 else 0
    failed = duplicate_hashes
    warn = False
    status_message = "RAW kihis on mitu snapshoti sama kuupäevaga."
    if missing_hash:
        failed = missing_hash
        warn = True
        status_message = "RAW MTA latest data_as_of ridadel puudub osaliselt row_hash; vastuolulist sisu ei hinnatud FAIL-iks."
    elif row["source_files"] and row["source_files"] > 1:
        failed = int(row["source_files"])
        warn = True
        status_message = "RAW MTA latest data_as_of kasutab mitut source_file väärtust, kuid row_hash on unikaalne."
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_data_as_of_idempotent",
        check_group="idempotency",
        object_name="raw.mta_maksuvolglased_csv",
        source_name="MTA",
        failed=failed,
        total=total,
        expected="row_hash count equals rows and no duplicate row_hashes in latest data_as_of",
        actual=(
            f"rows={total}; hash_count={row['hash_count']}; distinct_hashes={row['distinct_hashes']}; "
            f"source_files={row['source_files']}; file_hashes={row['file_hashes']}"
        ),
        data_as_of=data_as_of,
        message=status_message,
        warn=warn,
        details=dict(row),
    )


def check_stage_fact_maksuvolg_sum_parity(cur, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        WITH stage_sum AS (
            SELECT data_as_of AS kuupaev, sum(maksuvolg) AS stage_sum
            FROM stage.mta_maksuvolglased
            WHERE data_as_of IS NOT NULL
            GROUP BY data_as_of
        ),
        fact_sum AS (
            SELECT kuupaev, sum(maksuvola_summa) AS fact_sum
            FROM mart_star.fact_maksuvolg
            GROUP BY kuupaev
        ),
        diffs AS (
            SELECT
                s.kuupaev,
                s.stage_sum,
                f.fact_sum,
                abs(s.stage_sum - COALESCE(f.fact_sum, 0)) AS diff
            FROM stage_sum s
            LEFT JOIN fact_sum f ON f.kuupaev = s.kuupaev
            WHERE f.kuupaev IS NULL OR abs(s.stage_sum - f.fact_sum) > 1.0
        )
        SELECT
            (SELECT count(*) FROM stage_sum) AS total_count,
            (SELECT count(*) FROM diffs) AS failed_count,
            (SELECT max(diff) FROM diffs) AS max_diff,
            (SELECT jsonb_agg(jsonb_build_object('kuupaev', kuupaev, 'stage_sum', stage_sum, 'fact_sum', fact_sum, 'diff', diff) ORDER BY kuupaev) FROM diffs) AS bad_dates
        """,
    )
    failed = row["failed_count"] or 0
    return result_from_counts(
        layer_name="STAGE_FACT",
        check_name="stage_fact_maksuvolg_sum_parity",
        check_group="parity",
        object_name="mart_star.fact_maksuvolg",
        source_name="MTA",
        failed=failed,
        total=row["total_count"],
        expected="abs(stage_sum - fact_sum) <= 1.0 for every date",
        actual=f"bad_dates={failed}; max_diff={row['max_diff']}",
        message="Maksuvõla summa STAGE ja FACT kihis ei klapi lubatud piirides.",
        details={"bad_dates": row["bad_dates"] or [], "tolerance": 1.0},
    )


def check_fact_foreign_key_integrity(cur, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        WITH checks AS (
            SELECT 'fact_dim_ettevote' AS check_name, count(*) AS failed_count
            FROM mart_star.fact_maksuvolg f
            LEFT JOIN mart_star.dim_ettevote d ON d.ettevote_id = f.dim_ettevote_id
            WHERE d.ettevote_id IS NULL
            UNION ALL
            SELECT 'fact_dim_aeg', count(*)
            FROM mart_star.fact_maksuvolg f
            LEFT JOIN mart_star.dim_aeg d ON d.kuupaev = f.kuupaev
            WHERE d.kuupaev IS NULL
            UNION ALL
            SELECT 'fact_dim_vanuse_grupp', count(*)
            FROM mart_star.fact_maksuvolg f
            LEFT JOIN mart_star.dim_vanuse_grupp d ON d.maksuvola_vanuse_grupp = f.maksuvola_vanuse_grupp
            WHERE d.maksuvola_vanuse_grupp IS NULL
        )
        SELECT
            (SELECT count(*) FROM mart_star.fact_maksuvolg) AS total_count,
            sum(failed_count) AS failed_count,
            jsonb_object_agg(check_name, failed_count) AS details
        FROM checks
        """,
    )
    failed = row["failed_count"] or 0
    return result_from_counts(
        layer_name="FACT",
        check_name="fact_foreign_key_integrity",
        check_group="referential_integrity",
        object_name="mart_star.fact_maksuvolg",
        source_name="MART_STAR",
        failed=failed,
        total=row["total_count"],
        expected="0 missing dimension references",
        actual=f"{failed} missing references",
        message="FACT tabelis leidub võõrvõtmeid, millel puudub vaste dimensioonides.",
        details=row["details"] or {},
    )


def check_fact_grain_uniqueness(cur, run_id, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        WITH duplicates AS (
            SELECT dim_ettevote_id, kuupaev, count(*) AS rows_in_group
            FROM mart_star.fact_maksuvolg
            GROUP BY dim_ettevote_id, kuupaev
            HAVING count(*) > 1
        )
        SELECT
            (SELECT count(*) FROM mart_star.fact_maksuvolg) AS total_count,
            count(*) AS failed_count,
            COALESCE(sum(rows_in_group), 0) AS duplicate_rows
        FROM duplicates
        """,
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date,
                source_name, business_key, reason, row_data
            )
            SELECT %s, 'FACT', 'fact_grain_uniqueness', 'mart_star.fact_maksuvolg',
                   kuupaev, 'MART_STAR', dim_ettevote_id::text || ':' || kuupaev::text,
                   'FACT tabelis esineb duplikaatridu sama ettevõtte ja kuupäeva kohta.',
                   jsonb_build_object('dim_ettevote_id', dim_ettevote_id, 'kuupaev', kuupaev, 'rows_in_group', count(*))
            FROM mart_star.fact_maksuvolg
            GROUP BY dim_ettevote_id, kuupaev
            HAVING count(*) > 1
            LIMIT %s
            """,
            (),
        )
    return result_from_counts(
        layer_name="FACT",
        check_name="fact_grain_uniqueness",
        check_group="uniqueness",
        object_name="mart_star.fact_maksuvolg",
        source_name="MART_STAR",
        failed=failed,
        total=row["total_count"],
        expected="one row per dim_ettevote_id and kuupaev",
        actual=f"duplicate_groups={failed}; duplicate_rows={row['duplicate_rows']}",
        message="FACT tabelis esineb duplikaatridu sama ettevõtte ja kuupäeva kohta.",
        details={"duplicate_rows": row["duplicate_rows"], "bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_fact_juhatuse_muutuse_not_null(cur, run_id, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE juhatuse_muutuse_fakt IS NULL) AS failed_count
        FROM mart_star.fact_maksuvolg
        """,
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date,
                source_name, business_key, reason, row_data
            )
            SELECT %s, 'FACT', 'fact_juhatuse_muutuse_not_null', 'mart_star.fact_maksuvolg',
                   kuupaev, 'MART_STAR', dim_ettevote_id::text,
                   'FACT tabelis juhatuse_muutuse_fakt sisaldab NULL väärtust.', to_jsonb(t)
            FROM mart_star.fact_maksuvolg t
            WHERE juhatuse_muutuse_fakt IS NULL
            LIMIT %s
            """,
            (),
        )
    return result_from_counts(
        layer_name="FACT",
        check_name="fact_juhatuse_muutuse_not_null",
        check_group="value_validation",
        object_name="mart_star.fact_maksuvolg",
        source_name="MART_STAR",
        failed=failed,
        total=row["total_count"],
        expected="0 NULL juhatuse_muutuse_fakt rows",
        actual=f"{failed} NULL rows",
        message="FACT tabelis juhatuse_muutuse_fakt sisaldab NULL väärtusi.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def check_raw_mta_download_success(cur, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        SELECT max(data_as_of) AS latest_data_as_of,
               count(*) FILTER (WHERE data_as_of = current_date) AS today_rows,
               max(loaded_at)::date AS latest_loaded_date
        FROM raw.mta_maksuvolglased_csv
        """,
    )
    failed = 0 if row["latest_data_as_of"] == date.today() and (row["today_rows"] or 0) > 0 else 1
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_mta_download_success",
        check_group="freshness",
        object_name="raw.mta_maksuvolglased_csv",
        source_name="MTA",
        failed=failed,
        total=row["today_rows"],
        expected="latest data_as_of is current_date and rows > 0",
        actual=f"latest_data_as_of={row['latest_data_as_of']}; today_rows={row['today_rows']}; latest_loaded_date={row['latest_loaded_date']}",
        data_as_of=row["latest_data_as_of"],
        message="MTA andmete allalaadimine ebaõnnestus või ridade arv puudub.",
        details=dict(row),
    )


def check_raw_rik_download_success(cur, _dates) -> QualityResult:
    row = fetchone(
        cur,
        """
        SELECT logical_snapshot_date AS latest_snapshot_date,
               COALESCE(NULLIF(raw_rows_after, 0), inserted_rows, expected_rows, 0) AS today_rows,
               finished_at::date AS latest_loaded_date,
               action,
               status AS audit_status,
               message AS audit_message
        FROM admin.raw_import_audit
        WHERE dataset_name = 'rik_kaardile_kantud_isikud_json'
          AND status = 'SUCCESS'
        ORDER BY logical_snapshot_date DESC, finished_at DESC NULLS LAST, id DESC
        LIMIT 1
        """,
    )
    if row is None:
        row = {
            "latest_snapshot_date": None,
            "today_rows": 0,
            "latest_loaded_date": None,
            "action": None,
            "audit_status": None,
            "audit_message": "RIK audit entry missing",
        }
    failed = 0 if row["latest_snapshot_date"] == date.today() and (row["today_rows"] or 0) > 0 else 1
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_rik_download_success",
        check_group="freshness",
        object_name="admin.raw_import_audit",
        source_name="RIK",
        failed=failed,
        total=row["today_rows"],
        expected="latest successful RIK audit snapshot is current_date and rows > 0",
        actual=f"latest_snapshot_date={row['latest_snapshot_date']}; today_rows={row['today_rows']}; latest_loaded_date={row['latest_loaded_date']}; action={row['action']}",
        snapshot_date=row["latest_snapshot_date"],
        message="RIK andmete allalaadimine ebaõnnestus või ridade arv puudub.",
        details=dict(row),
    )


def read_latest_mta_header() -> tuple[date | None, list[str], Path | None]:
    latest_file = PROJECT_DIR / "data/raw/maksuvolglased/latest.txt"
    csv_file = PROJECT_DIR / "data/raw/maksuvolglased/maksuvolglased_latest.csv"
    if latest_file.exists():
        value = latest_file.read_text(encoding="utf-8").strip()
        if value:
            candidate = PROJECT_DIR / value if not Path(value).is_absolute() else Path(value)
            if candidate.exists():
                csv_file = candidate
    if not csv_file.exists():
        return None, [], csv_file
    with csv_file.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f, delimiter=";")
        header = next(reader, [])
        first_row = next(reader, [])
    data_as_of = None
    if first_row:
        try:
            from datetime import datetime
            data_as_of = datetime.strptime(first_row[0].strip(), "%d.%m.%Y").date()
        except Exception:
            data_as_of = None
    return data_as_of, [item.strip() for item in header], csv_file


def collect_json_shape(value: Any, depth: int = 0, max_depth: int = 2) -> Any:
    if isinstance(value, dict):
        if depth >= max_depth:
            return sorted(value.keys())
        return {key: collect_json_shape(value[key], depth + 1, max_depth) for key in sorted(value.keys())}
    if isinstance(value, list):
        if not value:
            return []
        return [collect_json_shape(value[0], depth + 1, max_depth)]
    return type(value).__name__


def read_latest_rik_structure(snapshot_date: date | None) -> tuple[date | None, dict[str, Any], Path | None]:
    if snapshot_date is None:
        return None, {}, None
    json_file = PROJECT_DIR / f"data/raw/rik/{snapshot_date.isoformat()}/extracted/ettevotja_rekvisiidid__kaardile_kantud_isikud.json"
    if not json_file.exists():
        return snapshot_date, {}, json_file
    with json_file.open("rb") as f:
        for record in ijson.items(f, "item"):
            return snapshot_date, collect_json_shape(record), json_file
    return snapshot_date, {}, json_file


def record_structure_snapshot(cur, source_name: str, object_name: str, snapshot_date: date | None, data_as_of: date | None, structure_json: dict[str, Any]) -> tuple[str, str | None, bool]:
    signature = stable_signature(structure_json)
    previous = fetchone(
        cur,
        """
        SELECT structure_signature
        FROM quality.source_structure_snapshots
        WHERE source_name = %s
          AND object_name = %s
          AND is_current = true
        ORDER BY captured_at DESC, id DESC
        LIMIT 1
        """,
        (source_name, object_name),
    )
    previous_signature = previous["structure_signature"] if previous else None
    changed = previous_signature is not None and previous_signature != signature
    cur.execute(
        """
        UPDATE quality.source_structure_snapshots
        SET is_current = false
        WHERE source_name = %s
          AND object_name = %s
          AND is_current = true
        """,
        (source_name, object_name),
    )
    cur.execute(
        """
        INSERT INTO quality.source_structure_snapshots (
            source_name, object_name, snapshot_date, data_as_of, structure_signature, structure_json, is_current
        )
        VALUES (%s, %s, %s, %s, %s, %s, true)
        """,
        (source_name, object_name, snapshot_date, data_as_of, signature, Jsonb(structure_json, dumps=lambda obj: json.dumps(obj, ensure_ascii=False, default=json_default))),
    )
    return signature, previous_signature, changed


def check_raw_source_structure_consistency_mta(cur, _dates) -> QualityResult:
    data_as_of, header, csv_file = read_latest_mta_header()
    if not header:
        return QualityResult(
            layer_name="RAW",
            check_name="raw_source_structure_consistency",
            check_group="source_structure",
            object_name="MTA CSV header",
            source_name="MTA",
            status="ERROR",
            severity="FATAL",
            expected_value="readable latest MTA CSV header",
            actual_value=f"csv_file={csv_file}",
            failed_count=1,
            total_count=1,
            data_as_of=data_as_of,
            message="Allikandmete struktuur või veerunimed on muutunud.",
            details={"csv_file": str(csv_file) if csv_file else None},
        )
    structure = {"type": "csv", "delimiter": ";", "header": header}
    signature, previous_signature, changed = record_structure_snapshot(
        cur, "MTA", "maksuvolglased_csv_header", None, data_as_of, structure
    )
    expected_header_ok = header == MTA_HEADERS
    failed = 0 if expected_header_ok and not changed else 1
    warn = changed and expected_header_ok
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_source_structure_consistency",
        check_group="source_structure",
        object_name="MTA CSV header",
        source_name="MTA",
        failed=failed,
        total=1,
        expected="MTA CSV header equals expected parser header and signature unchanged",
        actual=f"signature={signature}; previous_signature={previous_signature}; changed={changed}",
        data_as_of=data_as_of,
        message="Allikandmete struktuur või veerunimed on muutunud.",
        warn=warn,
        details={"header": header, "csv_file": str(csv_file), "signature": signature, "previous_signature": previous_signature},
    )


def check_raw_source_structure_consistency_rik(cur, dates) -> QualityResult:
    snapshot_date, structure, json_file = read_latest_rik_structure(dates.get("rik_snapshot_date"))
    if not structure:
        return QualityResult(
            layer_name="RAW",
            check_name="raw_source_structure_consistency",
            check_group="source_structure",
            object_name="RIK JSON top-level structure",
            source_name="RIK",
            status="ERROR",
            severity="FATAL",
            expected_value="readable latest RIK JSON structure",
            actual_value=f"json_file={json_file}",
            failed_count=1,
            total_count=1,
            snapshot_date=snapshot_date,
            message="Allikandmete struktuur või veerunimed on muutunud.",
            details={"json_file": str(json_file) if json_file else None},
        )
    signature, previous_signature, changed = record_structure_snapshot(
        cur, "RIK", "kaardile_kantud_isikud_json_structure", snapshot_date, None, structure
    )
    failed = 1 if changed else 0
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_source_structure_consistency",
        check_group="source_structure",
        object_name="RIK JSON top-level structure",
        source_name="RIK",
        failed=failed,
        total=1,
        expected="RIK JSON structure signature unchanged",
        actual=f"signature={signature}; previous_signature={previous_signature}; changed={changed}",
        snapshot_date=snapshot_date,
        message="Allikandmete struktuur või veerunimed on muutunud.",
        warn=True,
        details={"structure": structure, "json_file": str(json_file), "signature": signature, "previous_signature": previous_signature},
    )


def check_raw_mta_date_fields_not_null(cur, run_id, dates) -> QualityResult:
    data_as_of = dates["mta_data_as_of"]
    row = fetchone(
        cur,
        """
        SELECT count(*) AS total_count,
               count(*) FILTER (WHERE snapshot_date IS NULL OR data_as_of IS NULL) AS failed_count
        FROM raw.mta_maksuvolglased_csv
        WHERE data_as_of = %s OR data_as_of IS NULL
        """,
        (data_as_of,),
    )
    failed = row["failed_count"] or 0
    if failed:
        insert_bad_rows(
            cur,
            run_id,
            """
            INSERT INTO quality.data_quality_bad_rows (
                run_id, layer_name, check_name, object_name, snapshot_date, data_as_of,
                source_name, source_file, row_no, business_key, reason, row_data
            )
            SELECT %s, 'RAW', 'raw_mta_date_fields_not_null', 'raw.mta_maksuvolglased_csv',
                   snapshot_date, data_as_of, 'MTA', source_file, row_no, registrikood,
                   'MTA andmetes puuduvad kuupäevaväljad või sisaldavad NULL väärtusi.', to_jsonb(t)
            FROM raw.mta_maksuvolglased_csv t
            WHERE data_as_of = %s OR data_as_of IS NULL OR snapshot_date IS NULL
            LIMIT %s
            """,
            (data_as_of,),
        )
    return result_from_counts(
        layer_name="RAW",
        check_name="raw_mta_date_fields_not_null",
        check_group="value_validation",
        object_name="raw.mta_maksuvolglased_csv",
        source_name="MTA",
        failed=failed,
        total=row["total_count"],
        expected="snapshot_date and data_as_of are not null",
        actual=f"{failed} rows with null date fields",
        data_as_of=data_as_of,
        message="MTA andmetes puuduvad kuupäevaväljad või sisaldavad NULL väärtusi.",
        details={"bad_rows_sample_limit": BAD_ROWS_SAMPLE_LIMIT},
    )


def run_checks(cur, run_id: uuid.UUID) -> list[QualityResult]:
    dates = latest_dates(cur)
    checks = [
        lambda: check_mta_raw_stage_parity(cur, dates),
        lambda: check_rik_raw_stage_parity(cur, dates),
        lambda: check_stage_mta_bad_registrikood(cur, run_id, dates),
        lambda: check_stage_mta_null_maksuvolg(cur, run_id, dates),
        lambda: check_stage_mta_negative_maksuvolg(cur, run_id, dates),
        lambda: check_stage_rik_bad_registrikood(cur, run_id, dates),
        lambda: check_stage_rik_duplicate_registrikood(cur, run_id, dates),
        lambda: check_mart_star_required_columns(cur, dates),
        lambda: check_mart_star_snapshot_parity(cur, dates),
        lambda: check_raw_data_as_of_idempotent(cur, dates),
        lambda: check_stage_fact_maksuvolg_sum_parity(cur, dates),
        lambda: check_fact_foreign_key_integrity(cur, dates),
        lambda: check_fact_grain_uniqueness(cur, run_id, dates),
        lambda: check_fact_juhatuse_muutuse_not_null(cur, run_id, dates),
        lambda: check_raw_mta_download_success(cur, dates),
        lambda: check_raw_rik_download_success(cur, dates),
        lambda: check_raw_source_structure_consistency_mta(cur, dates),
        lambda: check_raw_source_structure_consistency_rik(cur, dates),
        lambda: check_raw_mta_date_fields_not_null(cur, run_id, dates),
    ]

    results: list[QualityResult] = []
    for check in checks:
        try:
            result = check()
        except Exception as exc:
            result = QualityResult(
                layer_name="RUNNER",
                check_name=getattr(check, "__name__", "data_quality_check"),
                check_group="runner_error",
                object_name="scripts.run_data_quality_checks",
                source_name=None,
                status="ERROR",
                severity="FATAL",
                failed_count=1,
                total_count=1,
                message=str(exc),
                details={"exception_type": type(exc).__name__},
            )
        insert_result(cur, run_id, result)
        results.append(result)
        print(
            f"{result.status:7} {result.layer_name:11} {result.check_name} "
            f"failed={result.failed_count} total={result.total_count}",
            flush=True,
        )
    return results


def run_status(results: list[QualityResult]) -> str:
    statuses = {result.status for result in results}
    if "ERROR" in statuses or "FAIL" in statuses:
        return "FAIL"
    if "WARN" in statuses:
        return "WARN"
    return "PASS"


def main() -> int:
    run_id = uuid.uuid4()
    print(f"Data quality run_id={run_id}", flush=True)
    try:
        with connect() as conn:
            with conn.cursor() as cur:
                ensure_quality_schema(cur)
                start_run(cur, run_id)
                results = run_checks(cur, run_id)
                status = run_status(results)
                finish_run(cur, run_id, status, f"Data quality checks finished with status {status}.")
            conn.commit()
    except Exception as exc:
        print(f"Data quality runner technical failure: {exc}", file=sys.stderr)
        return 1

    summary: dict[str, int] = {}
    for result in results:
        summary[result.status] = summary.get(result.status, 0) + 1
    print("Data quality summary: " + ", ".join(f"{k}={v}" for k, v in sorted(summary.items())), flush=True)

    if FAIL_PIPELINE and status == "FAIL":
        print("DATA_QUALITY_FAIL_PIPELINE=true ja kontrollides oli FAIL/ERROR.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
