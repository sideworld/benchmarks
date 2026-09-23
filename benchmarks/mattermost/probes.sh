#!/usr/bin/env bash
# Mattermost probes at full volume. Every one goes through the public REST API with a token, so
# what is timed is what a client experiences, not what a hand-written query can do.
#
#   benchmarks/mattermost/probes.sh [base-url] [runs]
#
# Anything whose median crosses THRESHOLD_MS gets an EXPLAIN (ANALYZE, BUFFERS) of the query
# Mattermost actually issued, printed underneath it.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=${1:-${MM_BASE:-http://127.0.0.1:8065}}
RUNS=${2:-5}
THRESHOLD_MS=${THRESHOLD_MS:-200}
TOK=$(cat "$SPEC_DIR/.token"); TEAM=$(cat "$SPEC_DIR/.core-team")
PGC=${MM_PG_CONTAINER:-mm-postgres}
api() { curl -sS -m 300 -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$@"; }
q() { docker exec -i -e PGPASSWORD=mostest_password "$PGC" psql -U mmuser -d mattermost_test -tAc "$1" < /dev/null; }

# median of RUNS wall-clock times, in ms, plus the last body for a shape check
time_it() {
  local name=$1; shift
  local -a ms=()
  local body=""
  for _ in $(seq 1 "$RUNS"); do
    local t0 t1
    t0=$(date +%s%N); body=$("$@"); t1=$(date +%s%N)
    ms+=( $(( (t1 - t0) / 1000000 )) )
  done
  local med
  med=$(printf '%s\n' "${ms[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  printf '  %-26s p50 %6s ms   (n=%s: %s)\n' "$name" "$med" "$RUNS" "$(printf '%s ' "${ms[@]}")"
  LAST_BODY=$body; LAST_MED=$med
}
explain_if_slow() {  # $1 = label, $2 = SQL
  [ "$LAST_MED" -ge "$THRESHOLD_MS" ] || return 0
  echo "    ── over ${THRESHOLD_MS} ms; EXPLAIN (ANALYZE, BUFFERS) of the underlying query:"
  q "EXPLAIN (ANALYZE, BUFFERS, TIMING ON) $2" | sed 's/^/      /'
}

BUSY_NAME=$(q "select c.name from channels c order by c.totalmsgcount desc limit 1")
BUSY=$(q "select c.id from channels c order by c.totalmsgcount desc limit 1")
BUSY_N=$(q "select c.totalmsgcount from channels c order by c.totalmsgcount desc limit 1")
USR=$(q "select userid from channelmembers group by userid order by count(*) desc limit 1")
USR_N=$(q "select count(*) from channelmembers where userid='$USR'")
echo "target: channel $BUSY_NAME ($BUSY_N posts), user in $USR_N channels, $(q "select count(*) from posts") posts total"
echo

# ---------------------------------------------------------------- 1. channel history, page 1
p1() { api "$BASE/api/v4/channels/$BUSY/posts?per_page=60"; }
time_it "history page 1" p1
echo "$LAST_BODY" | python3 -c "import json,sys;d=json.load(sys.stdin);print('    returned %d posts' % len(d.get('posts',{})))"
explain_if_slow hist1 "SELECT * FROM posts WHERE channelid = '$BUSY' AND deleteat = 0 ORDER BY createat DESC LIMIT 60"

# ---------------------------------------------------------------- 2. channel history, deep page
DEEP=$(( BUSY_N / 60 / 2 ))   # halfway back through the channel
pd() { api "$BASE/api/v4/channels/$BUSY/posts?per_page=60&page=$DEEP"; }
time_it "history page $DEEP" pd
echo "$LAST_BODY" | python3 -c "import json,sys;d=json.load(sys.stdin);print('    returned %d posts' % len(d.get('posts',{})))"
explain_if_slow histdeep "SELECT * FROM posts WHERE channelid = '$BUSY' AND deleteat = 0 ORDER BY createat DESC LIMIT 60 OFFSET $(( DEEP * 60 ))"

# ---------------------------------------------------------------- 3. search, common term
srch() { api -X POST "$BASE/api/v4/teams/$TEAM/posts/search" -d '{"terms":"deployment","is_or_search":false,"per_page":20}'; }
time_it "search 'deployment'" srch
echo "$LAST_BODY" | python3 -c "import json,sys;d=json.load(sys.stdin);print('    matched %d' % len(d.get('order',[])))"
explain_if_slow search "SELECT * FROM posts WHERE to_tsvector('english', message) @@ plainto_tsquery('english','deployment') AND deleteat = 0 ORDER BY createat DESC LIMIT 20"

# ---------------------------------------------------------------- 4. unread counts, many channels
unread() { api "$BASE/api/v4/users/$USR/teams/$TEAM/channels/members"; }
time_it "unread across $USR_N chans" unread
echo "$LAST_BODY" | python3 -c "
import json,sys;d=json.load(sys.stdin)
print('    %d memberships, %d with unread' % (len(d), sum(1 for m in d if m.get('msg_count',0)>0)))"
explain_if_slow unread "SELECT m.*, c.totalmsgcount FROM channelmembers m JOIN channels c ON c.id = m.channelid WHERE m.userid = '$USR'"

# ---------------------------------------------------------------- 5. the round trip, still
echo
"$SPEC_DIR/probe.sh" "$BASE" | tail -1 | sed 's/^/  /'
