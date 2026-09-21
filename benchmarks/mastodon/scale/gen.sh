#!/usr/bin/env bash
# Run the generator against the live md project, with the big-table indexes dropped for the
# load and rebuilt after (Mastodon's own definitions, read back from pg_indexes), then
# VACUUM ANALYZE. Reports rows/s, on-disk size and compressratio.
#   benchmarks/mastodon/scale/gen.sh [n_statuses] [n_accounts] [n_follows_longtail] [heavy_followers]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
N_STATUSES=${1:-100000000}; N_ACCOUNTS=${2:-3500000}; N_LONGTAIL=${3:-5000000}; HEAVY_FOLLOWERS=${4:-3000000}
HEAVY=${HEAVY:-5}; YEARS=${YEARS:-3}; FAV_PCT=${FAV_PCT:-15}; REBLOG_PCT=${REBLOG_PCT:-10}; SEED=${SEED:-0.42}
psql() { "$HERE/../md.sh" exec -T db psql -U postgres -d mastodon_production -v ON_ERROR_STOP=1 "$@"; }
echo "== generating: $N_STATUSES statuses, $N_ACCOUNTS accounts, $HEAVY x $HEAVY_FOLLOWERS heavy followers, $N_LONGTAIL long-tail follows, favourites on $FAV_PCT% of statuses, $YEARS years"
# the app is stopped for the load: Sidekiq's schedulers write, and the indexes are dropped
"$HERE/../md.sh" stop web sidekiq streaming >/dev/null 2>&1
# Whatever happens, put the indexes back and restart the app: a failed load must not leave
# the schema without its indexes (which is exactly what the first validation run did).
finish() {
  rc=$?
  if psql -Atc "SELECT 1 FROM gen_saved_indexes LIMIT 1" 2>/dev/null | grep -q 1; then
    echo "== rebuilding $(psql -Atc 'SELECT count(*) FROM gen_saved_indexes') saved indexes (exit was $rc)"
    psql -Atc "SELECT indexdef || ';' FROM gen_saved_indexes ORDER BY tablename, indexname" | psql -q 2>&1 | grep -iE 'error' || true
    psql -Atc "DROP TABLE gen_saved_indexes" >/dev/null
  fi
  "$HERE/../md.sh" start web sidekiq streaming >/dev/null 2>&1
}
trap finish EXIT
# save + drop the non-PK indexes on the tables we bulk-load
psql -Atc "CREATE TABLE IF NOT EXISTS gen_saved_indexes AS SELECT tablename, indexname, indexdef FROM pg_indexes WHERE tablename IN ('statuses','notifications','follows','favourites','account_stats','status_stats') AND indexname NOT LIKE '%_pkey'" >/dev/null
psql -Atc "SELECT count(*) FROM gen_saved_indexes" | xargs -I{} echo "== {} indexes saved; dropping them for the load"
psql -Atc "SELECT 'DROP INDEX IF EXISTS ' || indexname || ';' FROM gen_saved_indexes" | psql -q >/dev/null
t0=$(date +%s)
# generic bulk-load profile around the generator: RI triggers off for the load, every FK pair
# validated (orphans must be 0) at the end -- benchmarks/lib/BULK-LOAD.md
LIB=$HERE/../../lib; LOAD_TABLES=accounts,users,follows,statuses,favourites,notifications,account_stats,status_stats,conversations
cat "$LIB/pg-bulk-load-begin.sql" "$HERE/gen.sql" "$LIB/pg-bulk-load-end.sql" | \
psql -q -v n_statuses=$N_STATUSES -v n_accounts=$N_ACCOUNTS -v n_follows_longtail=$N_LONGTAIL -v heavy=$HEAVY \
     -v heavy_followers=$HEAVY_FOLLOWERS -v years=$YEARS -v fav_pct=$FAV_PCT -v reblog_pct=$REBLOG_PCT -v seed=$SEED \
     -v load_tables=$LOAD_TABLES -f - 2>&1 | grep -E '^===|^Time:|accounts|ERROR|RI ' | sed 's/^/  /'
t1=$(date +%s)
echo "== load: $((t1 - t0)) s"
echo "== rebuilding indexes"
psql -Atc "SELECT indexdef || ';' FROM gen_saved_indexes ORDER BY tablename, indexname" | psql -q 2>&1 | grep -iE 'error' || true
psql -Atc "DROP TABLE gen_saved_indexes" >/dev/null
t2=$(date +%s)
echo "== indexes: $((t2 - t1)) s"
psql -Atc "VACUUM ANALYZE" >/dev/null; t3=$(date +%s); echo "== vacuum analyze: $((t3 - t2)) s"
psql -Atc "SELECT 'statuses='||(SELECT count(*) FROM statuses)||' notifications='||(SELECT count(*) FROM notifications)||' follows='||(SELECT count(*) FROM follows)||' favourites='||(SELECT count(*) FROM favourites)||' accounts='||(SELECT count(*) FROM accounts)||' users='||(SELECT count(*) FROM users)"
echo "== statuses/s over the load: $(( N_STATUSES / (t1 - t0) ))   wall total: $((t3 - t0)) s"
psql -Atc "SELECT relname || ' ' || pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relname IN ('statuses','notifications','follows','favourites','accounts','users','account_stats','status_stats') ORDER BY pg_total_relation_size(oid) DESC"
psql -Atc "SELECT 'database: ' || pg_size_pretty(pg_database_size('mastodon_production'))"
sync; zfs list -o name,used,logicalused,compressratio tank/md-pg tank/md-redis tank/md-system
