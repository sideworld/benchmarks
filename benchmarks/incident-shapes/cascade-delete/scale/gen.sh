#!/usr/bin/env bash
# GEN -- PAR-76's world at volume: an account root and 24 tables of history under it, skewed so
# a few accounts are huge and most are tiny (scale/gen.sql says how).
#
#   scale/gen.sh [scale] [accounts]        # defaults 1 and 20000: ~26M rows, account 1 ~6.4M
#
# benchmarks/lib's bulk-load profile: foreign-key triggers off for the session, the secondary
# indexes dropped and rebuilt from their own definitions, every FK pair proven orphan-free
# after, then VACUUM ANALYZE. Only ever adds, so it refuses a world that already has accounts.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB=$(cd "$HERE/../../../lib" && pwd)
SCALE=${1:-1}; ACCOUNTS=${2:-20000}
PGC=${CASCADE_PG_CONTAINER:-cascade-db}
psql_() { docker exec -i -e PGPASSWORD=cascade "$PGC" psql -U cascade -d cascade -v ON_ERROR_STOP=1 -X "$@"; }
q() { psql_ -tAc "$1"; }
say() { printf '\n[%s] %s\n' "$(date -u +%T)" "$*"; }

have=$(q "select count(*) from accounts")
if [ "$have" -gt 0 ]; then echo "  already $have accounts: nothing to generate"; exit 0; fi

# The executor and ingest insert with the sequences while this inserts explicit ids: stopped for
# the load, started again at the end (or on a failure).
WRITERS="cascade-executor cascade-ingest"
say "stopping the writers ($WRITERS) for the load"; docker stop $WRITERS >/dev/null
trap 'docker start $WRITERS >/dev/null' EXIT

say "secondary indexes: saved, then dropped for the load"
q "select indexdef || ';' from pg_indexes where schemaname = 'public' and indexname not like '%_pkey'" > "$HERE/.indexes.sql"
q "select 'DROP INDEX ' || quote_ident(indexname) || ';' from pg_indexes where schemaname = 'public' and indexname not like '%_pkey'" | psql_ -q
trap 'say "restoring the indexes"; psql_ -q < "$HERE/.indexes.sql" || true' ERR

t0=$(date +%s)
say "load: scale $SCALE, $ACCOUNTS accounts"
{ cat "$LIB/pg-bulk-load-begin.sql"; cat "$HERE/gen.sql"; } | psql_ -v scale="$SCALE" -v accounts="$ACCOUNTS"
say "load done in $(( $(date +%s) - t0 )) s; rebuilding $(wc -l < "$HERE/.indexes.sql") indexes"
{ echo "SET maintenance_work_mem = '1GB';"; cat "$HERE/.indexes.sql"; } | psql_ -q
trap - ERR
tables=$(q "select string_agg(tablename, ',') from pg_tables where schemaname = 'public'")
say "referential integrity, every FK pair"
psql_ -v load_tables="$tables" < "$LIB/pg-bulk-load-end.sql" 2>&1 | grep -E 'orphans|violated' | sed 's/^.*NOTICE: *//'
say "VACUUM ANALYZE"; q "VACUUM ANALYZE" >/dev/null
say "done in $(( $(date +%s) - t0 )) s"
q "select relname || ' ' || n_live_tup from pg_stat_user_tables order by n_live_tup desc" | column -t
q "select 'account 1: ' || runs || ' runs; account 15000: ' || (select runs from usage_counters where account_id = 15000) || ' runs' from usage_counters where account_id = 1"
