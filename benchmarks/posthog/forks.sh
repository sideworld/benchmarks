#!/usr/bin/env bash
# N Firecracker forks of the PostHog baseline: restore times, PSS at 10/60/120 s after EACH fork's
# own restore, and the isolation check that matters here -- an event captured in one fork must be
# queryable in that fork and in no other.
#   benchmarks/posthog/forks.sh up [n] | down [n] | isolation [n]
# Fork k answers on 127.0.0.1:3<kk>80. Owns tank/ph-snapfork<k>, tank/ph-snapfork<k>-rootfs, fc-phf<k>.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); SW=${PARAGLOBE_DIR:-/tank/work/paraglobe}; SPEC=$SPEC_DIR/app.spec
ACT=${1:?up|down|isolation}; N=${2:-3}
EMAIL=${PH_ADMIN_EMAIL:-sideworld@example.test}; PASS=${PH_ADMIN_PASS:-Sideworld-12345678}
port() { printf '3%02d80' "$1"; }
el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}'; }
pss() { awk '/^Pss:/ {s+=$2} END {printf "%d", s/1024}' "/proc/$1/smaps" 2>/dev/null || echo 0; }
j() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
$1"; }
session() {  # $1=base -> sets H[] with a logged-in session
  CJ=$(mktemp); curl -sS -m 30 -c "$CJ" -o /dev/null "$1/login"; local c; c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
  curl -sS -m 60 -H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: $1/" -b "$CJ" -c "$CJ" -o /dev/null -X POST "$1/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
  c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: $1/" -b "$CJ" -c "$CJ")
}

if [ "$ACT" = down ]; then for k in $(seq 1 "$N"); do "$SW/vm/app.sh" "$SPEC" unfork "$k" >/dev/null 2>&1 && echo "  unforked $k"; done; exit 0; fi

if [ "$ACT" = up ]; then
  echo "== restoring $N forks of phbase"; declare -A T0
  for k in $(seq 1 "$N"); do
    t0=$(date +%s.%N); "$SW/vm/app.sh" "$SPEC" fork phbase "$k" > "$SPEC_DIR/.fork$k.log" 2>&1; T=$(el "$t0"); T0[$k]=$(date +%s)
    p=$(port "$k"); code=$(curl -sS -o /dev/null -m 30 -w '%{http_code}' "http://127.0.0.1:$p/_health" || echo 000)
    pid=$(cat "$SW/vm/out/fc-phf$k.pid" 2>/dev/null || true)
    printf '  fork %d  restore %6ss  /_health %s  PSS@10s %5d MB\n' "$k" "$T" "$code" "$( [ -n "$pid" ] && { while [ $(( $(date +%s) - T0[$k] )) -lt 10 ]; do sleep 1; done; pss "$pid"; } || echo 0)"
  done
  echo; echo "== PSS at t+60 s and t+120 s after each fork's own restore"
  for k in $(seq 1 "$N"); do pid=$(cat "$SW/vm/out/fc-phf$k.pid" 2>/dev/null || true); [ -n "$pid" ] || continue
    while [ $(( $(date +%s) - T0[$k] )) -lt 60 ]; do sleep 1; done; a=$(pss "$pid")
    while [ $(( $(date +%s) - T0[$k] )) -lt 120 ]; do sleep 1; done; b=$(pss "$pid")
    printf '  fork %d  PSS@60s %5d MB  PSS@120s %5d MB\n' "$k" "$a" "$b"; done
  tot=0; for k in $(seq 1 "$N"); do pid=$(cat "$SW/vm/out/fc-phf$k.pid" 2>/dev/null || true); [ -n "$pid" ] && tot=$(( tot + $(pss "$pid") )); done
  echo "  summed PSS now: $tot MB across $N forks"; free -m | sed -n '2p' | awk '{printf "  host: used %d MiB, available %d MiB\n", $3, $7}'; exit 0
fi

if [ "$ACT" = isolation ]; then
  echo "== isolation: capture an event in fork 1, query for it in every fork"
  p1="http://127.0.0.1:$(port 1)"; session "$p1"
  read -r PID TOK < <(curl -sS -m 30 "${H[@]}" "$p1/api/projects/@current/" | j "print(d.get('id',''), d.get('api_token',''))")
  S=$(date +%s%N); EV="isolation_probe_$S"
  code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -H "Content-Type: application/json" -X POST "$p1/capture/" -d "{\"api_key\":\"$TOK\",\"event\":\"$EV\",\"distinct_id\":\"iso-$S\",\"properties\":{}}")
  [ "$code" = 200 ] || { echo "  capture in fork 1 failed: HTTP $code" >&2; exit 1; }
  echo "  captured $EV in fork 1 (project $PID)"
# PostHog caches query results (cache_target_age is hours away); a poll that reads the cache never sees
# the row it is waiting for. refresh=force_blocking bypasses it.
  rc=0
  for k in $(seq 1 "$N"); do
    b="http://127.0.0.1:$(port "$k")"; session "$b"; n=0
    for _ in $(seq 1 $([ "$k" = 1 ] && echo 240 || echo 20)); do
      n=$(curl -sS -m 60 "${H[@]}" -X POST "$b/api/projects/$PID/query/" -d "{\"query\":{\"kind\":\"HogQLQuery\",\"query\":\"select count() from events where event = '$EV'\"},\"refresh\":\"force_blocking\"}" | j "r=d.get('results') or [[0]]; print(r[0][0] if r and r[0] else 0)")
      [ "${n:-0}" -ge 1 ] && break; sleep 0.5; done
    if [ "$k" = 1 ]; then [ "${n:-0}" -ge 1 ] && echo "  fork 1: present   <- correct" || { echo "  fork 1: MISSING   <- wrong"; rc=1; }
    else [ "${n:-0}" -eq 0 ] && echo "  fork $k: absent (after 10 s)   <- correct" || { echo "  fork $k: PRESENT   <- forks are not isolated"; rc=1; }; fi
  done; exit $rc
fi
