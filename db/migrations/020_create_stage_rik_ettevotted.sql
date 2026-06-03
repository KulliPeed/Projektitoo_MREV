BEGIN;

CREATE SCHEMA IF NOT EXISTS stage;

CREATE TABLE IF NOT EXISTS stage.rik_ettevotted (
    id BIGSERIAL PRIMARY KEY,
    raw_id BIGINT NOT NULL,
    snapshot_date DATE NOT NULL,
    source_file TEXT,
    row_no BIGINT,
    registrikood TEXT,
    nimi TEXT,
    oiguslik_vorm TEXT,
    staatus TEXT,
    loaded_at TIMESTAMP,
    stage_loaded_at TIMESTAMP DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stage_rik_ettevotted_snapshot_reg
    ON stage.rik_ettevotted(snapshot_date, registrikood);

CREATE INDEX IF NOT EXISTS idx_stage_rik_ettevotted_raw_id
    ON stage.rik_ettevotted(raw_id);

COMMIT;
