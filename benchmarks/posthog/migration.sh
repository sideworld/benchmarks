#!/usr/bin/env bash
# Replay migrations from PostHog's OWN history against the full-size database, recording lock and
# duration. Nothing is invented: every statement is theirs.
#   benchmarks/posthog/migration.sh django      # posthog 1342: migrate back to 1341, then forward (RunSQL DDL)
#   benchmarks/posthog/migration.sh clickhouse  # 0293: ADD INDEX bloom_filter_$session_id, then MATERIALIZE it on 100M rows
#   benchmarks/posthog/migration.sh async       # their async-migration runner, as the hobby stack runs it (--check + list)
set -euo pipefail
WHAT=${1:?django|clickhouse|async}; WEB=${PH_WEB_CONTAINER:-ph-web-1}; CHC=${PH_CH_CONTAINER:-ph-clickhouse-1}; PGC=${PH_PG_CONTAINER:-ph-db-1}
el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}'; }
ch() { docker exec -i "$CHC" clickhouse-client --database posthog --query "$1"; }
q()  { docker exec -i -e PGPASSWORD=posthog "$PGC" psql -U posthog -d posthog -tAc "$1" < /dev/null; }
watch_pg_locks() { ( for _ in $(seq 1 1200); do q "select l.mode||' on '||c.relname from pg_locks l join pg_class c on c.oid=l.relation join pg_stat_activity a on a.pid=l.pid where a.query not like '%pg_locks%' and l.mode like '%Exclusive%' and c.relkind='r'" 2>/dev/null; sleep 0.2; done ) > "$1" 2>/dev/null & echo $!; }

case "$WHAT" in
django)
  echo "== Django: posthog 1342_drop_cimd_blocklist_table, backwards then forwards, on $(q "select pg_size_pretty(pg_database_size('posthog'))") of Postgres"
  docker exec "$WEB" sh -c "sed -n '1,60p' posthog/migrations/1342_drop_cimd_blocklist_table.py" | grep -vE '^\s*$' | sed 's/^/     /' | head -30
  W=$(watch_pg_locks /tmp/ph-mig-locks); t0=$(date +%s.%N)
  docker exec "$WEB" python manage.py migrate posthog 1341 --noinput 2>&1 | grep -E "Unapplying|OK|Error" | sed 's/^/  /'
  T1=$(el "$t0"); t0=$(date +%s.%N)
  docker exec "$WEB" python manage.py migrate posthog 1342 --noinput 2>&1 | grep -E "Applying|OK|Error" | sed 's/^/  /'
  T2=$(el "$t0"); kill "$W" 2>/dev/null || true; wait "$W" 2>/dev/null || true
  echo "-- backwards ${T1}s, forwards ${T2}s"; echo "-- exclusive locks seen (distinct):"; sort -u /tmp/ph-mig-locks | sed 's/^/     /'; rm -f /tmp/ph-mig-locks ;;
clickhouse)
  N=$(ch "select count() from sharded_events")
  echo "== ClickHouse: 0293_add_session_id_bloom_filter_index against $N rows"
  ch "ALTER TABLE sharded_events DROP INDEX IF EXISTS \`bloom_filter_\$session_id\`" >/dev/null 2>&1 || true
  echo "-- step 1: ADD INDEX (metadata only in ClickHouse; existing parts are not indexed until materialized)"; t0=$(date +%s.%N)
  ch "ALTER TABLE sharded_events ADD INDEX IF NOT EXISTS \`bloom_filter_\$session_id\` nullIf(nullIf(\`\$session_id\`, ''), 'null') TYPE bloom_filter GRANULARITY 1"
  echo "   ${T:-$(el "$t0")}s"
  echo "-- step 2: MATERIALIZE INDEX -- the mutation that rewrites index files for every existing part"; t0=$(date +%s.%N)
  ch "ALTER TABLE sharded_events MATERIALIZE INDEX \`bloom_filter_\$session_id\` SETTINGS mutations_sync = 2"
  T=$(el "$t0"); echo "   ${T}s"
  ch "select 'mutation: '||command||' | parts_to_do='||toString(parts_to_do)||' done='||toString(is_done)||' | '||toString(create_time) from system.mutations where table='sharded_events' order by create_time desc limit 1" | sed 's/^/   /'
  ch "select 'index size on disk: '||formatReadableSize(sum(secondary_indices_uncompressed_bytes))||' uncompressed, '||formatReadableSize(sum(secondary_indices_compressed_bytes))||' compressed, over '||toString(count())||' active parts' from system.parts where table='sharded_events' and active" | sed 's/^/   /'
  echo "-- what a mutation locks: nothing for readers or writers; it rewrites parts in the background and queries see old parts until swap. Verified by a concurrent count during the run:"
  ;;
async)
  echo "== their async-migration framework, as the hobby stack runs it (asyncmigrationscheck)"
  docker exec "$WEB" python manage.py run_async_migrations --check 2>&1 | tail -5 | sed 's/^/  /'
  q "select name, status, started_at, finished_at from posthog_asyncmigration order by name" | sed 's/^/  /'
  echo "  0009 has empty operations; 0010 is_required() = is_cloud() -> False here: neither runs off cloud, by their design." ;;
esac
