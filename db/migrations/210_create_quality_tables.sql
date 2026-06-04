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
