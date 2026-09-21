#!/usr/bin/env bash
# Readiness probe for a running TrainTicket 0.2.0: the things a user would do.
#   benchmarks/trainticket/probe.sh [host] [auth_port] [travel_port] [ui_port]
# Defaults are the native deployment's published ports. Exit 0 only if the UI
# serves, login returns a JWT, and a ticket search answers with status 1.
set -uo pipefail
HOST=${1:-127.0.0.1}
AUTH=${2:-12340}; TRAVEL=${3:-12346}; UI=${4:-8080}
DATE=${DATE:-$(date -u -d '+1 day' +%F)}
# At 1M orders the search is ~100 s: every matching trip costs a collection scan of the
# order store (only an _id index upstream). Cap generously and report the time.
SEARCH_TIMEOUT=${SEARCH_TIMEOUT:-300}

ui=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$HOST:$UI/")
tok=$(curl -s -m 10 -X POST "http://$HOST:$AUTH/api/v1/users/login" -H 'Content-Type: application/json' \
      -d '{"username":"fdse_microservice","password":"111111","verificationCode":""}' \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["token"])
except Exception: pass' 2>/dev/null)
if [ -n "$tok" ]; then
  t0=$(date +%s.%N)
  read -r st trips <<<"$(curl -s -m "$SEARCH_TIMEOUT" -X POST "http://$HOST:$TRAVEL/api/v1/travelservice/trips/left" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" \
      -d "{\"startingPlace\":\"Nan Jing\",\"endPlace\":\"Shang Hai\",\"departureTime\":\"$DATE\"}" \
      | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("status"), len(d.get("data") or []))
except Exception: print("- -")' 2>/dev/null)"
  search_s=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
else
  st=-; trips=-; search_s=-
fi
printf 'ui=%s login=%s search_status=%s trips=%s search_s=%s\n' "$ui" "${tok:+ok}" "$st" "$trips" "$search_s"
[ "$ui" = 200 ] && [ -n "$tok" ] && [ "$st" = 1 ] && [ "${trips:-0}" -ge 1 ] 2>/dev/null
