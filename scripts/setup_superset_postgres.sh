#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/kool/projekt"
CONTAINER="andmeprojekt_postgres"
ADMIN_USER="andrus"
MAIN_DB="andmeprojekt"
POSTGRES_DB="postgres"

cd "$PROJECT_DIR"

if [ ! -f ".env.superset" ]; then
  echo "Puudub .env.superset. Loo see .env.superset.example põhjal." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ".env.superset"
set +a

: "${SUPERSET_META_DB_NAME:?SUPERSET_META_DB_NAME puudub}"
: "${SUPERSET_META_DB_USER:?SUPERSET_META_DB_USER puudub}"
: "${SUPERSET_META_DB_PASSWORD:?SUPERSET_META_DB_PASSWORD puudub}"
: "${SUPERSET_READONLY_DB_USER:?SUPERSET_READONLY_DB_USER puudub}"
: "${SUPERSET_READONLY_DB_PASSWORD:?SUPERSET_READONLY_DB_PASSWORD puudub}"

if [ "$SUPERSET_META_DB_NAME" != "superset_meta" ]; then
  echo "Turvakontroll: SUPERSET_META_DB_NAME peab olema superset_meta." >&2
  exit 1
fi

if [ "$SUPERSET_META_DB_USER" != "superset_meta" ]; then
  echo "Turvakontroll: SUPERSET_META_DB_USER peab olema superset_meta." >&2
  exit 1
fi

if [ "$SUPERSET_READONLY_DB_USER" != "superset_readonly" ]; then
  echo "Turvakontroll: SUPERSET_READONLY_DB_USER peab olema superset_readonly." >&2
  exit 1
fi

echo "Loon/uuendan Superseti PostgreSQL rolle."
docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$POSTGRES_DB" \
  -v meta_password="$SUPERSET_META_DB_PASSWORD" \
  -v readonly_password="$SUPERSET_READONLY_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE superset_meta LOGIN PASSWORD %L', :'meta_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_meta')
\gexec

ALTER ROLE superset_meta LOGIN PASSWORD :'meta_password';

SELECT format('CREATE ROLE superset_readonly LOGIN PASSWORD %L', :'readonly_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'superset_readonly')
\gexec

ALTER ROLE superset_readonly LOGIN PASSWORD :'readonly_password';
SQL

if docker exec -i "$CONTAINER" psql -X -U "$ADMIN_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT 1 FROM pg_database WHERE datname = 'superset_meta'" | grep -q 1; then
  echo "superset_meta andmebaas on juba olemas."
else
  echo "Loon superset_meta andmebaasi."
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$POSTGRES_DB" -c \
    "CREATE DATABASE superset_meta OWNER superset_meta;"
fi

echo "Annan superset_readonly kasutajale ainult mart skeemi lugemisõigused."
docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$ADMIN_USER" -d "$MAIN_DB" <<'SQL'
GRANT CONNECT ON DATABASE andmeprojekt TO superset_readonly;
GRANT USAGE ON SCHEMA mart TO superset_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO superset_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA mart
GRANT SELECT ON TABLES TO superset_readonly;

REVOKE ALL ON SCHEMA raw FROM superset_readonly;
REVOKE ALL ON SCHEMA stage FROM superset_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM superset_readonly;
REVOKE ALL ON ALL TABLES IN SCHEMA stage FROM superset_readonly;
REVOKE CREATE ON SCHEMA public FROM superset_readonly;
SQL

echo "Superseti PostgreSQL seadistus valmis."
