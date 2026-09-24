#!/usr/bin/env bash
# Five Firecracker forks of the populated Mattermost baseline: restore times, a PSS series, and
# the isolation check that matters — a post made in one fork must exist in that fork and in no
# other.
#
#   benchmarks/mattermost/forks.sh up [n]   |   down [n]   |   isolation [n]
#
# Fork k answers on 127.0.0.1:3<kk>80. Owns tank/mm-vmfork<k>, tank/rootfs-mm-src<k>, fc-mm<k>.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SW=${PARAGLOBE_DIR:-/tank/work/paraglobe}
SPEC=$SPEC_DIR/app.spec
ACT=${1:?up|down|isolation}; N=${2:-5}
TOK=$(cat "$SPEC_DIR/.token"); TEAM=$(cat "$SPEC_DIR/.core-team")
port() { printf '3%02d80' "$1"; }
api() { local p=$1; shift; curl -sS -m 300 -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "http://127.0.0.1:$p/api/v4$@"; }
el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}'; }

if [ "$ACT" = down ]; then
  for k in $(seq 1 "$N"); do "$SW/vm/app.sh" "$SPEC" unfork "$k" >/dev/null 2>&1 && echo "  unforked $k"; done
  exit 0
fi

if [ "$ACT" = up ]; then
  echo "== restoring $N forks of mmbase"
  for k in $(seq 1 "$N"); do
    t0=$(date +%s.%N)
    "$SW/vm/app.sh" "$SPEC" fork mmbase "$k" > "$SPEC_DIR/.fork$k.log" 2>&1
    T=$(el "$t0")
    p=$(port "$k")
    code=$(curl -sS -o /dev/null -m 30 -w '%{http_code}' "http://127.0.0.1:$p/api/v4/system/ping" || echo 000)
    # by name: /teams/{id}/channels lists only the CALLER's channels, so scanning it makes a
    # perfectly good fork look empty.
    posts=$(api "$p" "/teams/$TEAM/channels/name/gen-1" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('total_msg_count',0))
except Exception: print(0)")
    printf '  fork %d  restore %6ss  ping %s  busiest channel %s posts\n' "$k" "$T" "$code" "$posts"
  done
  echo
  echo "== PSS at t+120 s (per firecracker process)"
  sleep 120
  tot=0
  for k in $(seq 1 "$N"); do
    pid=$(cat "$SW/vm/out/fc-mmf$k.pid" 2>/dev/null || true)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || { printf '  fork %d  (no pid)\n' "$k"; continue; }
    pss=$(awk '/^Pss:/ {s+=$2} END {printf "%d", s/1024}' "/proc/$pid/smaps" 2>/dev/null || echo 0)
    tot=$((tot + pss))
    printf '  fork %d  PSS %5d MB\n' "$k" "$pss"
  done
  echo "  summed  PSS $tot MB across $N forks"
  free -m | sed -n '2p' | awk '{printf "  host: used %d MiB, available %d MiB\n", $3, $7}'
  exit 0
fi

if [ "$ACT" = isolation ]; then
  echo "== isolation: post in fork 1, look for it everywhere"
  p1=$(port 1)
  CH=$(api "$p1" "/teams/$TEAM/channels/name/gen-1" | python3 -c "
import json,sys;print(json.load(sys.stdin)['id'])")
  S=$(date +%s%N); MSG="isolation probe $S"
  PID=$(api "$p1" "/posts" -X POST -d "{\"channel_id\":\"$CH\",\"message\":\"$MSG\"}" | python3 -c "
import json,sys;print(json.load(sys.stdin).get('id',''))")
  [ -n "$PID" ] || { echo "  could not post in fork 1" >&2; exit 1; }
  echo "  posted $PID in fork 1, channel $CH"
  rc=0
  for k in $(seq 1 "$N"); do
    p=$(port "$k")
    # Compare the id to the one we posted. Do NOT test for "non-empty": a 404 from Mattermost is
    # {"id":"app.post.get.app_error", ...}, whose `id` is the ERROR CODE, so every fork that
    # correctly did NOT have the post reported it as present. Second time this API's error
    # shape has produced a confident wrong answer in this world; the first was in scale/core.sh.
    found=$(curl -sS -m 120 -H "Authorization: Bearer $TOK" "http://127.0.0.1:$p/api/v4/posts/$PID" \
            | PID="$PID" python3 -c "
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: d={}
i=d.get('id','') if isinstance(d,dict) else ''
print('yes' if i == os.environ['PID'] else 'no')")
    if [ "$k" = 1 ]; then
      [ "$found" = yes ] && echo "  fork 1: present   <- correct" || { echo "  fork 1: MISSING   <- wrong"; rc=1; }
    else
      [ "$found" = no ] && echo "  fork $k: absent    <- correct" || { echo "  fork $k: PRESENT   <- forks are not isolated"; rc=1; }
    fi
  done
  exit $rc
fi
