#!/usr/bin/env bash
# GEN -- Mattermost at production scale, at the data plane.
#
#   benchmarks/mattermost/scale/gen.sh [n_posts] [n_channels] [n_users]
#
# Three phases, because the order matters:
#   load    users, channels, the Zipf plan, memberships, and the posts themselves -- with the
#           secondary indexes on posts DROPPED. Building two GIN indexes incrementally over
#           twenty million rows costs far more than building them once at the end.
#   derive  threads, reactions and file metadata, which all read posts by id or group by rootid,
#           so they run only after the indexes are back.
#   counters  Channels.TotalMsgCount / LastPostAt and ChannelMembers.MsgCount / LastViewedAt.
#
# The index DDL is read back out of pg_indexes and replayed verbatim, so what is recreated is
# exactly what Mattermost's own migrations created -- not a hand-copied approximation.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCALE=$SPEC_DIR/scale
N_POSTS=${1:-20000000}; N_CHANNELS=${2:-3000}; N_USERS=${3:-2000}
PGC=${MM_PG_CONTAINER:-mm-postgres}
DB=${MM_DB:-mattermost_test}; DBU=${MM_DB_USER:-mmuser}; DBP=${MM_DB_PASS:-mostest_password}
psql_() { docker exec -i -e PGPASSWORD="$DBP" "$PGC" psql -U "$DBU" -d "$DB" -v ON_ERROR_STOP=1 "$@"; }
q() { psql_ -tAc "$1"; }
say() { printf '\n\033[1;37m[%s] %s\033[0m\n' "$(date -u +%T)" "$*"; }

TEAM=$(cat "$SPEC_DIR/.core-team")
CREATOR=$(head -1 "$SPEC_DIR/.core-users")
T0=$(( $(date +%s) * 1000 ))
T_START=$(( T0 - 2 * 365 * 86400 * 1000 ))    # two years of history

say "before: $(q "select 'posts='||count(*) from posts")"

# The runbook re-runs GEN whenever it re-runs, and this generator only ever ADDS. Without this
# guard a second `onboard-generic.sh` on a populated world silently doubles it. Skip if the world
# is already at (or near) the requested scale.
have=$(q "select count(*) from posts")
if [ "$have" -ge $(( N_POSTS * 9 / 10 )) ]; then
  echo "  already $have posts (>= 90% of $N_POSTS): nothing to generate"
  exit 0
fi

# ---------------------------------------------------------------- indexes off
say "recording and dropping the secondary indexes on posts"
q "select indexdef||';' from pg_indexes where tablename='posts' and indexname <> 'posts_pkey' order by indexname" > "$SCALE/.posts-indexes.sql"
wc -l < "$SCALE/.posts-indexes.sql" | sed 's/^/  captured /'
# `docker exec -i` reads stdin, so running q inside `while read ... < <(q ...)` made the first
# DROP swallow the rest of the index list: exactly one index was dropped and the rebuild then
# failed with `relation "idx_posts_channel_id_delete_at_create_at" already exists`.
# Collect the names first, then drop.
mapfile -t DROPME < <(q "select indexname from pg_indexes where tablename='posts' and indexname <> 'posts_pkey'")
for ix in "${DROPME[@]}"; do [ -n "$ix" ] && q "DROP INDEX IF EXISTS $ix" >/dev/null < /dev/null; done
echo "  dropped ${#DROPME[@]}"

# ---------------------------------------------------------------- load
say "load: $N_USERS users, $N_CHANNELS channels, $N_POSTS posts"
t0=$(date +%s.%N)
psql_ -v n_users="$N_USERS" -v n_channels="$N_CHANNELS" -v n_posts="$N_POSTS" \
      -v team="$TEAM" -v creator="$CREATOR" -v t0="$T0" -v t_start="$T_START" \
      -f - < "$SCALE/gen-load.sql" | grep -E "INSERT|Time:" | tail -20 | sed 's/^/  /'
echo "  t_load=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"

# ---------------------------------------------------------------- indexes on
say "rebuilding the post indexes (maintenance_work_mem raised for the build only)"
t0=$(date +%s.%N)
{ echo "SET maintenance_work_mem = '4GB';"; echo "SET max_parallel_maintenance_workers = 4;"; cat "$SCALE/.posts-indexes.sql"; } \
  | psql_ -q
echo "  t_index=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
q "select count(*)||' indexes on posts' from pg_indexes where tablename='posts'" | sed 's/^/  /'

# ---------------------------------------------------------------- derive + counters
say "derive: threads, reactions, file metadata"
t0=$(date +%s.%N)
psql_ -v n_users="$N_USERS" -v team="$TEAM" -v t0="$T0" -f - < "$SCALE/gen-derive.sql" | grep -E "INSERT|UPDATE|Time:" | tail -12 | sed 's/^/  /'
echo "  t_derive=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"

say "counters"
t0=$(date +%s.%N)
psql_ -f - < "$SCALE/gen-counters.sql" | grep -E "UPDATE|Time:" | sed 's/^/  /'
echo "  t_counters=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"

# ---------------------------------------------------------------- settle
say "VACUUM ANALYZE + CHECKPOINT"
t0=$(date +%s.%N)
q "VACUUM (ANALYZE) posts" >/dev/null
for t in reactions fileinfo threads threadmemberships channels channelmembers users; do q "VACUUM (ANALYZE) $t" >/dev/null; done
q "CHECKPOINT" >/dev/null
echo "  t_vacuum=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"

# An assertion, because the NULL-message defect passed every count-based check: a generated
# world is only correct if the application can read it back.
say "assert: the generated rows are readable"
bad=$(q "select count(*) from posts where message is null or message = ''")
[ "$bad" = 0 ] || { echo "  $bad posts have no message -- refusing to call this a populated world" >&2; exit 1; }
echo "  0 posts with a null or empty message"

say "after"
q "select 'posts='||(select count(*) from posts)||' reactions='||(select count(*) from reactions)||' fileinfo='||(select count(*) from fileinfo)||' threads='||(select count(*) from threads)||' channels='||(select count(*) from channels)||' users='||(select count(*) from users)||' members='||(select count(*) from channelmembers)" | sed 's/^/  /'
q "select 'db='||pg_size_pretty(pg_database_size('$DB'))" | sed 's/^/  /'
q "select '  busiest: '||c.name||' '||c.totalmsgcount||' posts' from channels c order by c.totalmsgcount desc limit 3"
