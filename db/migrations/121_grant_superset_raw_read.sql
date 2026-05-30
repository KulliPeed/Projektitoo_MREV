-- Allow Superset SQL Lab to inspect original raw source tables with the read-only role.
-- This grants read access only; no write privileges are given.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_readonly')
       AND EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'raw') THEN
        EXECUTE 'GRANT USAGE ON SCHEMA raw TO superset_readonly';
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA raw TO superset_readonly';
        EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA raw GRANT SELECT ON TABLES TO superset_readonly';
    END IF;
END $$;
