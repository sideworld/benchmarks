#!/usr/bin/env bash
# PostHog probes at full volume, through the REST API with a session: trends, a funnel, the persons
# list, and a property-filtered trend, on the hottest project. p50 over RUNS. Anything over
# THRESHOLD_MS gets the ClickHouse EXPLAIN of the query PostHog actually ran, pulled from
# system.query_log by the request's query id.
#   benchmarks/posthog/probes.sh [base-url] [runs]
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=${1:-${PH_BASE:-http://127.0.0.1:8100}}; RUNS=${2:-5}; THRESHOLD_MS=${THRESHOLD_MS:-1000}
CHC=${PH_CH_CONTAINER:-ph-clickhouse-1}
EMAIL=${PH_ADMIN_EMAIL:-paraglobe@example.test}; PASS=${PH_ADMIN_PASS:-Paraglobe-12345678}
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT
j() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
$1"; }
ch() { docker exec -i "$CHC" clickhouse-client --database posthog --query "$1" 2>/dev/null; }
curl -sS -m 30 -c "$CJ" -o /dev/null "$BASE/login"; CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")
curl -sS -m 60 "${H[@]}" -o /dev/null -X POST "$BASE/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")
PID=$(ch "select team_id from events group by team_id order by count() desc limit 1")
N=$(ch "select count() from events where team_id = $PID")
echo "target: project $PID ($N events, the hottest), $(ch 'select count() from events') events total, $RUNS runs"; echo

time_it() {  # name, then the command that prints the response body
  local name=$1; shift; local -a ms=(); local body=""
  for _ in $(seq 1 "$RUNS"); do local t0 t1; t0=$(date +%s%N); body=$("$@"); t1=$(date +%s%N); ms+=( $(( (t1-t0)/1000000 )) ); done
  LAST_MED=$(printf '%s\n' "${ms[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  printf '  %-30s p50 %6s ms   (%s)\n' "$name" "$LAST_MED" "$(printf '%s ' "${ms[@]}")"; LAST_BODY=$body
}
explain_if_slow() {  # $1 = a substring that identifies the query in system.query_log
  [ "$LAST_MED" -ge "$THRESHOLD_MS" ] || return 0
  ch "SYSTEM FLUSH LOGS" >/dev/null
  local qid; qid=$(ch "select query_id from system.query_log where type='QueryFinish' and query like '%$1%' and query not like '%system.query_log%' order by event_time desc limit 1")
  echo "    ── over ${THRESHOLD_MS} ms; ClickHouse's own numbers for that query (query_id $qid):"
  ch "select concat('      read ', formatReadableQuantity(read_rows), ' rows / ', formatReadableSize(read_bytes), ', peak memory ', formatReadableSize(memory_usage), ', ', toString(query_duration_ms), ' ms in ClickHouse') from system.query_log where query_id='$qid' and type='QueryFinish'"
  echo "    ── EXPLAIN indexes=1 of it:"
  # the logged query is multi-line and ends in SETTINGS; hand it to the client whole, as one query
  { printf 'EXPLAIN indexes = 1 '; ch "select query from system.query_log where query_id='$qid' and type='QueryFinish' FORMAT TSVRaw"; } \
    | docker exec -i "$CHC" clickhouse-client --database posthog --multiline 2>&1 | grep -E "ReadFromMergeTree|Parts:|Granules:|Condition|MinMax|Partition|PrimaryKey|Skip|Name:|Description:" | head -16 | sed 's/^/      /'
}
# Every timed query bypasses PostHog's result cache (refresh=force_blocking): the first run of a
# probe would otherwise be the only real one and p50 would be the cache, not ClickHouse.
Q() { curl -sS -m 300 "${H[@]}" -X POST "$BASE/api/projects/$PID/query/" -d "$(printf '%s' "$1" | sed 's/}}$/},"refresh":"force_blocking"}/')"; }

# 1. trends: pageviews per day, 30 days
trends() { Q '{"query":{"kind":"TrendsQuery","dateRange":{"date_from":"-30d"},"interval":"day","series":[{"kind":"EventsNode","event":"$pageview","math":"total"}]}}'; }
time_it "trends: \$pageview/day, 30d" trends
echo "$LAST_BODY" | j "r=d.get('results') or []; print('    series:', len(r), ' points:', len(r[0].get('data',[])) if r else 0, ' total:', sum(r[0].get('data',[])) if r else 0)"
explain_if_slow "\$pageview"

# 2. funnel: $pageview -> signup -> purchase, 30 days
funnel() { Q '{"query":{"kind":"FunnelsQuery","dateRange":{"date_from":"-30d"},"series":[{"kind":"EventsNode","event":"$pageview"},{"kind":"EventsNode","event":"signup"},{"kind":"EventsNode","event":"purchase"}],"funnelsFilter":{"funnelWindowInterval":14,"funnelWindowIntervalUnit":"day"}}}'; }
time_it "funnel: pageview>signup>purchase" funnel
echo "$LAST_BODY" | j "r=d.get('results') or []; print('    steps:', [ (s.get('name'), s.get('count')) for s in r ] if isinstance(r,list) else str(r)[:80])"
explain_if_slow "purchase"

# 3. persons list, first page
persons() { curl -sS -m 300 "${H[@]}" "$BASE/api/projects/$PID/persons/?limit=100"; }
time_it "persons list, page 1" persons
echo "$LAST_BODY" | j "print('    returned:', len(d.get('results',[])), ' next:', bool(d.get('next')))"
explain_if_slow "person"

# 4. property filter: pageviews where plan = enterprise, 30 days
pfilter() { Q '{"query":{"kind":"TrendsQuery","dateRange":{"date_from":"-30d"},"interval":"day","series":[{"kind":"EventsNode","event":"$pageview","math":"total","properties":[{"key":"plan","value":["enterprise"],"operator":"exact","type":"event"}]}]}}'; }
time_it "trends + property filter (plan)" pfilter
echo "$LAST_BODY" | j "r=d.get('results') or []; print('    total:', sum(r[0].get('data',[])) if r else 0)"
explain_if_slow "enterprise"

# 5. event list (the explorer), newest 100
evlist() { Q '{"query":{"kind":"EventsQuery","select":["*","event","person","timestamp"],"orderBy":["timestamp DESC"],"limit":100,"after":"-7d"}}'; }
time_it "event list, newest 100" evlist
echo "$LAST_BODY" | j "print('    rows:', len(d.get('results',[])))"
explain_if_slow "DESC"
echo; "$SPEC_DIR/probe.sh" "$BASE" | tail -1 | sed 's/^/  /'
