CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stage;
CREATE SCHEMA IF NOT EXISTS mart;

CREATE TABLE IF NOT EXISTS raw.rik_kaardile_kantud_isikud_json (
    id BIGSERIAL PRIMARY KEY,
    snapshot_date DATE NOT NULL,
    source_file TEXT NOT NULL,
    row_no BIGINT NOT NULL,
    record JSONB NOT NULL,
    loaded_at TIMESTAMP DEFAULT now(),
    CONSTRAINT uq_rik_raw_snapshot_file_row UNIQUE (snapshot_date, source_file, row_no)
);

CREATE INDEX IF NOT EXISTS idx_rik_raw_snapshot_date
ON raw.rik_kaardile_kantud_isikud_json(snapshot_date);

CREATE INDEX IF NOT EXISTS idx_rik_raw_record_gin
ON raw.rik_kaardile_kantud_isikud_json
USING GIN(record);
