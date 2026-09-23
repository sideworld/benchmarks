#!/usr/bin/env bash
# Replay one of Mattermost's OWN migrations against the full-size database, and record what it
# locks and for how long.
#
#   benchmarks/mattermost/migration.sh [name]
#
# Default: 000130_system_console_stats, which builds three materialized views, the first two of
# which join every post to its channel. It is the heaviest thing in their migration history that
# a 20-million-post database has to survive, and it is entirely invisible at fixture scale --
# on an empty Posts table it completes in milliseconds.
#
# Also available: 000102_posts_originalid_index, a plain (non-CONCURRENT) CREATE INDEX on Posts,
# which is the lock story rather than the duration story.
#
# All 422 migrations already ran at first boot against an empty database, so the objects exist.
# This drops the ones the chosen migration creates and replays the file verbatim -- the SQL that
# runs is Mattermost's, byte for byte.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MIG=${1:-000130_system_console_stats}
SRC=${MM_SRC:-/tank/work/mattermost}/server/channels/db/migrations/postgres
PGC=${MM_PG_CONTAINER:-mm-postgres}
F=$SRC/$MIG.up.sql
[ -f "$F" ] || { echo "no such migration: $F" >&2; exit 2; }
q() { docker exec -i -e PGPASSWORD=mostest_password "$PGC" psql -U mmuser -d mattermost_test -tAc "$1" < /dev/null; }

echo "== $MIG, against $(q "select to_char(count(*),'FM999,999,999') from posts") posts"
echo "-- the migration, verbatim:"; sed 's/^/     /' "$F"

case "$MIG" in
  000130_system_console_stats)
    q "DROP MATERIALIZED VIEW IF EXISTS posts_by_team_day, bot_posts_by_team_day, file_stats" >/dev/null ;;
  000102_posts_originalid_index)
    q "DROP INDEX IF EXISTS idx_posts_original_id" >/dev/null ;;
esac

# Watch the locks from a second session while it runs. AccessExclusiveLock on posts is the one
# that would stop a live Mattermost dead; ShareLock blocks writes but not reads.
( for _ in $(seq 1 600); do
    docker exec -i -e PGPASSWORD=mostest_password "$PGC" psql -U mmuser -d mattermost_test -tAc "
      select l.mode||' on '||coalesce(c.relname,'?')
      from pg_locks l left join pg_class c on c.oid=l.relation
      join pg_stat_activity a on a.pid=l.pid
      where a.query not like '%pg_locks%' and c.relname in
        ('posts','channels','fileinfo','posts_by_team_day','bot_posts_by_team_day','file_stats')" < /dev/null 2>/dev/null
    sleep 0.5
  done ) > "$SPEC_DIR/.locks" 2>/dev/null &
WATCH=$!

t0=$(date +%s.%N)
docker exec -i -e PGPASSWORD=mostest_password "$PGC" psql -U mmuser -d mattermost_test -v ON_ERROR_STOP=1 -q < "$F"
T=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
kill "$WATCH" 2>/dev/null || true; wait "$WATCH" 2>/dev/null || true

echo "-- duration: ${T}s"
echo "-- locks held while it ran (distinct):"
sort -u "$SPEC_DIR/.locks" | grep -v '^\s*$' | sed 's/^/     /'
rm -f "$SPEC_DIR/.locks"
case "$MIG" in
  000130_system_console_stats)
    q "select '     posts_by_team_day: '||count(*)||' rows' from posts_by_team_day"
    q "select '     file_stats: '||num||' files, '||pg_size_pretty(usage) from file_stats" ;;
  000102_posts_originalid_index)
    q "select '     idx_posts_original_id: '||pg_size_pretty(pg_relation_size('idx_posts_original_id'))" ;;
esac
