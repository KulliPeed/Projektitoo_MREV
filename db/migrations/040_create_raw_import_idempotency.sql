CREATE SCHEMA IF NOT EXISTS admin;

CREATE TABLE IF NOT EXISTS admin.raw_import_audit (
    id BIGSERIAL PRIMARY KEY,
    dataset_name TEXT NOT NULL,
    logical_snapshot_date DATE NOT NULL,
    source_file TEXT NOT NULL,
    action TEXT NOT NULL,
    expected_rows BIGINT NOT NULL,
    existing_rows_before BIGINT NOT NULL,
    inserted_rows BIGINT NOT NULL DEFAULT 0,
    raw_rows_after BIGINT,
    content_signature TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'SUCCESS',
    message TEXT,
    started_at TIMESTAMP DEFAULT now(),
    finished_at TIMESTAMP DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_raw_import_audit_dataset_snapshot_started
ON admin.raw_import_audit(dataset_name, logical_snapshot_date, started_at DESC);

DO $$
BEGIN
    IF to_regclass('raw.mta_maksuvolglased_csv') IS NOT NULL THEN
        ALTER TABLE raw.mta_maksuvolglased_csv
            ADD COLUMN IF NOT EXISTS row_hash TEXT;

        EXECUTE '
            CREATE UNIQUE INDEX IF NOT EXISTS ux_mta_maksuvolglased_raw_data_as_of_row_hash
            ON raw.mta_maksuvolglased_csv(data_as_of, row_hash)
            WHERE data_as_of IS NOT NULL AND row_hash IS NOT NULL
        ';
    END IF;

    IF to_regclass('raw.rik_kaardile_kantud_isikud_json') IS NOT NULL THEN
        ALTER TABLE raw.rik_kaardile_kantud_isikud_json
            ADD COLUMN IF NOT EXISTS row_hash TEXT;

        EXECUTE '
            CREATE UNIQUE INDEX IF NOT EXISTS ux_rik_raw_snapshot_date_row_hash
            ON raw.rik_kaardile_kantud_isikud_json(snapshot_date, row_hash)
            WHERE row_hash IS NOT NULL
        ';
    END IF;
END $$;
