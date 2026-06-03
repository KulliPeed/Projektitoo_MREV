BEGIN;

CREATE SCHEMA IF NOT EXISTS stage;

CREATE TABLE IF NOT EXISTS stage.rik_kaardile_kantud_isikud (
    id BIGSERIAL PRIMARY KEY,
    raw_id BIGINT NOT NULL,
    snapshot_date DATE NOT NULL,
    source_file TEXT,
    row_no BIGINT,
    registrikood TEXT,
    ettevotte_nimi TEXT,
    isik_nimi TEXT,
    isikukood TEXT,
    roll TEXT,
    rolli_alguskuupaev DATE,
    on_juhatuse_liige BOOLEAN NOT NULL,
    loaded_at TIMESTAMP,
    stage_loaded_at TIMESTAMP DEFAULT now()
);

ALTER TABLE stage.rik_kaardile_kantud_isikud
    DROP COLUMN IF EXISTS isik_json;

CREATE INDEX IF NOT EXISTS idx_stage_rik_isikud_snapshot_reg
    ON stage.rik_kaardile_kantud_isikud(snapshot_date, registrikood);

CREATE INDEX IF NOT EXISTS idx_stage_rik_isikud_juhatus
    ON stage.rik_kaardile_kantud_isikud(snapshot_date, registrikood, on_juhatuse_liige);

CREATE INDEX IF NOT EXISTS idx_stage_rik_isikud_raw_id
    ON stage.rik_kaardile_kantud_isikud(raw_id);

COMMIT;
