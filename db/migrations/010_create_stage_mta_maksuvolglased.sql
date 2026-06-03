BEGIN;

CREATE SCHEMA IF NOT EXISTS stage;

CREATE OR REPLACE FUNCTION stage.parse_et_numeric(p_value text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_value text;
BEGIN
    IF p_value IS NULL OR btrim(p_value) = '' THEN
        RETURN NULL;
    END IF;

    v_value := replace(btrim(p_value), chr(160), '');
    v_value := regexp_replace(v_value, '[[:space:]]', '', 'g');
    v_value := regexp_replace(v_value, '[^0-9,.-]', '', 'g');

    IF position(',' IN v_value) > 0 THEN
        v_value := replace(v_value, '.', '');
        v_value := replace(v_value, ',', '.');
    END IF;

    IF v_value = '' THEN
        RETURN NULL;
    END IF;

    RETURN v_value::numeric;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION stage.parse_et_date(p_value text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_value text;
    v_date date;
BEGIN
    IF p_value IS NULL OR btrim(p_value) = '' THEN
        RETURN NULL;
    END IF;

    v_value := btrim(p_value);

    IF v_value ~ '^[0-9]{2}[.][0-9]{2}[.][0-9]{4}$' THEN
        v_date := to_date(v_value, 'DD.MM.YYYY');
        IF to_char(v_date, 'DD.MM.YYYY') <> v_value THEN
            RETURN NULL;
        END IF;
        RETURN v_date;
    END IF;

    IF v_value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RETURN v_value::date;
    END IF;

    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

CREATE TABLE IF NOT EXISTS stage.mta_maksuvolglased (
    id BIGSERIAL PRIMARY KEY,
    raw_id BIGINT NOT NULL,
    snapshot_date DATE NOT NULL,
    data_as_of DATE,
    source_file TEXT,
    file_sha256 TEXT,
    row_no BIGINT,
    registrikood TEXT,
    nimi TEXT,
    maksuvolg NUMERIC(18,2),
    sh_vaidlustatud NUMERIC(18,2),
    sh_tasumisgraafikus NUMERIC(18,2),
    tasumisgraafiku_loppkuupaev DATE,
    vanima_tasumata_noude_tasumise_tahtaeg DATE,
    volg_vanus_paevades INTEGER,
    volg_vanuse_grupp TEXT,
    loaded_at TIMESTAMP,
    stage_loaded_at TIMESTAMP DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stage_mta_snapshot_reg
    ON stage.mta_maksuvolglased(snapshot_date, registrikood);

CREATE INDEX IF NOT EXISTS idx_stage_mta_data_as_of_reg
    ON stage.mta_maksuvolglased(data_as_of, registrikood);

CREATE INDEX IF NOT EXISTS idx_stage_mta_raw_id
    ON stage.mta_maksuvolglased(raw_id);

COMMIT;
