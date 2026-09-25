#!/usr/bin/env bash
# HOOK_POST_UP -- the schema (migrations/0001_schema.sql), once. The app has no migrator of its
# own; a pull request's 0002_*.sql is applied by the Migration Check, not here.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PGC=${CASCADE_PG_CONTAINER:-cascade-db}
psql_() { docker exec -i -e PGPASSWORD=cascade "$PGC" psql -U cascade -d cascade -v ON_ERROR_STOP=1 -X "$@"; }
if [ "$(psql_ -tAc "select to_regclass('public.accounts') is not null")" = t ]; then
  echo "  schema already there"; exit 0
fi
psql_ -q < "$HERE/migrations/0001_schema.sql"
echo "  schema: $(psql_ -tAc "select count(*) from pg_tables where schemaname = 'public'") tables, $(psql_ -tAc "select count(*) from pg_constraint where contype = 'f' and confdeltype = 'c'") ON DELETE CASCADE foreign keys"
