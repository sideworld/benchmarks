#!/usr/bin/env bash
# GEN -- PostHog at production scale, at the data plane.
#   benchmarks/posthog/scale/gen.sh [n_events] [n_teams] [n_persons_per_team] [days]
# Phases: persons (Postgres, bulk-load profile) -> persons (ClickHouse, copied from Postgres)
#         -> events (ClickHouse, server-side) -> OPTIMIZE/settle -> assert the app can read it.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); SCALE=$SPEC_DIR/scale
LIB=$(cd "$SPEC_DIR/../lib" && pwd)
N_EVENTS=${1:-100000000}; N_TEAMS=${2:-40}; N_PERSONS=${3:-50000}; DAYS=${4:-90}
PGC=${PH_PG_CONTAINER:-ph-db-1}; CHC=${PH_CH_CONTAINER:-ph-clickhouse-1}
psql_() { docker exec -i -e PGPASSWORD=posthog "$PGC" psql -U posthog -d posthog -v ON_ERROR_STOP=1 "$@"; }
q()     { psql_ -tAc "$1" < /dev/null; }
ch()    { docker exec -i "$CHC" clickhouse-client --database posthog "$@"; }
say()   { printf '\n\033[1;37m[%s] %s\033[0m\n' "$(date -u +%T)" "$*"; }
el()    { echo "$1 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}'; }

TEAM_IDS=$(q "select string_agg(id::text, ',' order by id) from (select id from posthog_team order by id limit $N_TEAMS) t")
HAVE=$(ch --query "select count() from events")
say "before: events=$HAVE teams=$(q "select count(*) from posthog_team") persons=$(q "select count(*) from posthog_person")"
if [ "$HAVE" -ge $(( N_EVENTS * 9 / 10 )) ]; then echo "  already $HAVE events (>= 90% of $N_EVENTS): nothing to generate"; exit 0; fi
n_teams_have=$(echo "$TEAM_IDS" | tr ',' '\n' | wc -l)
[ "$n_teams_have" -ge "$N_TEAMS" ] || { echo "  only $n_teams_have teams exist; scale/core.sh must create $N_TEAMS projects first" >&2; exit 1; }

# ---------------------------------------------------------------- persons, Postgres
if [ "$(q "select count(*) from information_schema.tables where table_name='sideworld_gen_persons'")" = 1 ]; then
  say "persons: Postgres already has $(q 'select count(*) from sideworld_gen_persons') generated persons; skipping the Postgres phase"
else
say "persons: $N_PERSONS per team x $N_TEAMS teams into Postgres (bulk-load profile)"
t0=$(date +%s.%N)
{ cat "$LIB/pg-bulk-load-begin.sql"; cat "$SCALE/gen-persons.sql"; echo "\\set load_tables 'posthog_person,posthog_persondistinctid'"; cat "$LIB/pg-bulk-load-end.sql"; } \
  | psql_ -v n_persons="$N_PERSONS" -v team_ids="$TEAM_IDS" 2>&1 | grep -E "INSERT|RI |Time:|ERROR" | tail -12 | sed 's/^/  /'
echo "  t_persons_pg=$(el "$t0")s"
fi

# ---------------------------------------------------------------- persons, ClickHouse (copied)
if [ "$(ch --query 'select count() from person')" -ge "$(q 'select count(*) from sideworld_gen_persons')" ]; then
  say "persons: ClickHouse already has them; skipping the copy"
else
say "persons: the same rows into ClickHouse person / person_distinct_id2"
t0=$(date +%s.%N)
q "copy (select uuid, to_char(created_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.MS'), team_id, properties, is_identified, 0, 0 from sideworld_gen_persons) to stdout with (format csv)" \
  | ch --query "INSERT INTO person (id, created_at, team_id, properties, is_identified, is_deleted, version) FORMAT CSV"
q "copy (select team_id, distinct_id, uuid, 0, 0 from sideworld_gen_persons) to stdout with (format csv)" \
  | ch --query "INSERT INTO person_distinct_id2 (team_id, distinct_id, person_id, is_deleted, version) FORMAT CSV"
echo "  ch person=$(ch --query 'select count() from person')  pdi2=$(ch --query 'select count() from person_distinct_id2')  t_persons_ch=$(el "$t0")s"
fi

# ---------------------------------------------------------------- events, ClickHouse
say "events: $N_EVENTS into sharded_events, server-side, in batches of 10M"
t0=$(date +%s.%N); T_END=$(date -u +%s)
BATCH=10000000; done_n=$HAVE; N_EVENTS=$(( N_EVENTS + HAVE ))   # continue the sequence past what is already there
while [ "$done_n" -lt "$N_EVENTS" ]; do
  b=$(( N_EVENTS - done_n )); [ "$b" -gt "$BATCH" ] && b=$BATCH
  t1=$(date +%s.%N)
  sed "s/{n_events:UInt64}/{n_events:UInt64}/" "$SCALE/gen-events.sql" \
    | ch --param_n_events="$b" --param_n_teams="$N_TEAMS" --param_teams="[$TEAM_IDS]" --param_n_persons="$N_PERSONS" \
         --param_days="$DAYS" --param_t_end="$T_END" --param_start="$done_n"
  done_n=$(( done_n + b ))
  echo "  +$b in $(el "$t1")s  (total $done_n)"
done
echo "  t_events=$(el "$t0")s  rows=$(ch --query 'select count() from events')"

# ---------------------------------------------------------------- settle
say "settle: OPTIMIZE FINAL on the shard table, then a readability assertion"
t0=$(date +%s.%N)
ch --query "OPTIMIZE TABLE sharded_events FINAL SETTINGS optimize_throw_if_noop = 0" || true
ch --query "SYSTEM FLUSH LOGS"
echo "  t_optimize=$(el "$t0")s"
ch --query "select 'events='||toString(count())||' teams='||toString(uniq(team_id))||' persons='||toString(uniq(person_id))||' span='||toString(min(timestamp))||'..'||toString(max(timestamp)) from events" | sed 's/^/  /'
ch --query "select team_id, count() c from events group by team_id order by c desc limit 3 format TSV" | sed 's/^/  hottest: /'
ch --query "select table, formatReadableSize(sum(bytes_on_disk)) from system.parts where active and database='posthog' and table in ('sharded_events','person','person_distinct_id2') group by table format TSV" | sed 's/^/  disk: /'
