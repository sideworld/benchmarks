#!/usr/bin/env bash
# Scale probes at full volume: p50/p95 over N requests for the home timeline of the heavy-
# follow account, the public timeline, notifications of a mega-follower account, and account
# lookup; anything over 250 ms p95 gets its slow queries (log_min_duration_statement) shown
# with EXPLAIN (ANALYZE, BUFFERS).
#   benchmarks/mastodon/probes.sh [n]      (env: WEB=3300 HOST=127.0.0.1)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); N=${1:-20}; HOST=${HOST:-127.0.0.1}; WEB=${WEB:-3300}
H=(-H "X-Forwarded-Proto: https" -H "Host: mastodon.test")
psql() { "$HERE/md.sh" exec -T db psql -U postgres -d mastodon_production -Atq -c "$1"; }
tok() { "$HERE/make-token.sh" "$1"; }
# the mega-follow accounts are whichever five gen_accounts put first; take the heaviest by stats
HEAVY=$(psql "select a.username from account_stats s join accounts a on a.id=s.account_id where a.domain is null order by s.followers_count desc limit 1")
HEAVY_ID=$(psql "select id from accounts where username='$HEAVY' and domain is null")
TOK_HF=$(tok heavyfollower); TOK_U1=$(tok "$HEAVY")
echo "== heavy account: $HEAVY ($(psql "select followers_count||' followers, '||statuses_count||' statuses' from account_stats where account_id=$HEAVY_ID"))"
psql "ALTER SYSTEM SET log_min_duration_statement = '250ms'" >/dev/null; psql "SELECT pg_reload_conf()" >/dev/null   # two calls: ALTER SYSTEM refuses a transaction block
since=$(date -u +%FT%T)
bench() { # label, url, token   (ONLY=<substring> runs just the matching probes, e.g. ONLY=followers)
  [ -z "${ONLY:-}" ] || [[ "$1" == *"$ONLY"* ]] || return 0
  local ts=(); for i in $(seq 1 "$N"); do ts+=("$(curl -s -m 60 -o /dev/null -w '%{http_code} %{time_total}' "${H[@]}" ${3:+-H "Authorization: Bearer $3"} "$2")"); done
  local codes; codes=$(printf '%s\n' "${ts[@]}" | awk '{print $1}' | sort | uniq -c | tr '\n' ' ')
  printf '%s\n' "${ts[@]}" | awk '{print $2*1000}' | sort -n | awk -v l="$1" -v c="$codes" '{a[NR]=$1} END{printf "  %-34s p50=%6.0f ms  p95=%6.0f ms  max=%6.0f ms  codes: %s\n", l, a[int((NR+1)/2)], a[NR-int((NR-1)*0.05)], a[NR], c}'
}
# a home feed missing from Redis is rebuilt by RegenerationWorker (206 until done) once a sign-in asks for
# it; an API read alone serves 200 [] -- so ask for it the way a sign-in does, then time the rebuild
if [ -z "${ONLY:-}" ] || [[ "home" == *"$ONLY"* ]]; then
"$HERE/regen-feed.sh" heavyfollower >/dev/null
t=$(date +%s.%N); code=; n=0
for i in $(seq 1 600); do
  out=$(curl -s -m 60 -w ' %{http_code}' "${H[@]}" -H "Authorization: Bearer $TOK_HF" "http://$HOST:$WEB/api/v1/timelines/home?limit=20")
  code=${out##* }; n=$(echo "${out% *}" | python3 -c 'import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')
  [ "$code" = 200 ] && [ "$n" -gt 0 ] && break; sleep 0.5
done
echo "== home feed of heavyfollower (5000 followed, 5 of them mega): first 200 with $n statuses after $(echo "$t $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}') s (last code $code)"
fi
echo "== $N requests each"
bench "home timeline (heavyfollower)" "http://$HOST:$WEB/api/v1/timelines/home?limit=20" "$TOK_HF"
bench "public timeline" "http://$HOST:$WEB/api/v1/timelines/public?limit=20&local=true" ""
bench "notifications ($HEAVY, 3M followers)" "http://$HOST:$WEB/api/v1/notifications?limit=20" "$TOK_U1"
bench "grouped notifications ($HEAVY)" "http://$HOST:$WEB/api/v2/notifications?limit=20" "$TOK_U1"
bench "account lookup ($HEAVY)" "http://$HOST:$WEB/api/v1/accounts/lookup?acct=$HEAVY" ""
bench "account statuses ($HEAVY)" "http://$HOST:$WEB/api/v1/accounts/$HEAVY_ID/statuses?limit=20" "$TOK_HF"
bench "followers of $HEAVY" "http://$HOST:$WEB/api/v1/accounts/$HEAVY_ID/followers?limit=40" "$TOK_HF"
echo "== slow statements (>250 ms) logged by Postgres since $since"
"$HERE/md.sh" logs --since "$since" db 2>/dev/null | grep -A3 'duration:' | grep -vE '^--' | sed 's/^md-db-1  *| //' | head -40 > "$HERE/.slow.log"
if [ -s "$HERE/.slow.log" ]; then
  grep -oE 'duration: [0-9.]+ ms' "$HERE/.slow.log" | sort -t' ' -k2 -rn | head -5 | sed 's/^/  /'
  echo "== EXPLAIN (ANALYZE, BUFFERS) of the slowest distinct statements"
  # Rails uses the extended protocol: the SQL is on the "execute <unnamed>:" line, its binds on the next DETAIL line
  python3 - "$HERE/.slow.log" <<'PYX' | sort -u | head -3 | while IFS= read -r q; do
import re, sys
lines = open(sys.argv[1]).read().splitlines()
for i, l in enumerate(lines):
    m = re.search(r'(?:statement|execute [^:]*): (.*)$', l)
    if not m or 'duration:' not in l: continue
    q = m.group(1)
    if i + 1 < len(lines) and 'parameters:' in lines[i + 1]:
        for k, v in re.findall(r"\$(\d+) = ('(?:[^']|'')*'|NULL)", lines[i + 1]):
            q = re.sub(r'\$%s\b' % k, v, q)
    print(q)
PYX
    echo "--- $q" | cut -c1-200; psql "EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) $q" 2>&1 | grep -E 'Index|Seq Scan|Sort|Buffers|Execution|rows=' | head -12 | sed 's/^/    /'; done
else echo "  none"; fi
psql "ALTER SYSTEM RESET log_min_duration_statement" >/dev/null; psql "SELECT pg_reload_conf()" >/dev/null
