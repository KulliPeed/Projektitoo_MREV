-- Allow Superset SQL Lab to inspect cleaned stage tables with the read-only role.
-- RAW stays restricted; this exposes only the derived stage layer.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_readonly')
       AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'stage') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA stage TO superset_readonly';
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA stage TO superset_readonly';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA stage GRANT SELECT ON TABLES TO superset_readonly';
    END IF;
END $$;
