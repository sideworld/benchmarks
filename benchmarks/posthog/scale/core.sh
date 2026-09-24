#!/usr/bin/env bash
# The coherent core, through the app: one organization (signup, probe.sh), N projects created via
# the REST API, and a few hundred events captured through the public /capture/ endpoint so the
# ingestion tier has written real rows (person, distinct id, property definitions) before the
# generator adds volume in the same shape.
#   benchmarks/posthog/scale/core.sh [n_projects] [events_per_project]
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=${PH_BASE:-http://127.0.0.1:8100}; NP=${1:-40}; NE=${2:-8}
EMAIL=${PH_ADMIN_EMAIL:-paraglobe@example.test}; PASS=${PH_ADMIN_PASS:-Paraglobe-12345678}
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT
j() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
$1"; }
curl -sS -m 30 -c "$CJ" -o /dev/null "$BASE/login"; CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")
code=$(curl -sS -m 60 "${H[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}")
[ "$code" = 200 ] || { echo "login HTTP $code (run probe.sh first)" >&2; exit 1; }
CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")
ORG=$(curl -sS -m 30 "${H[@]}" "$BASE/api/organizations/@current/" | j "print(d.get('id',''))")
echo "==> organization $ORG"
echo "==> $NP projects"
: > "$SPEC_DIR/.projects"
have=$(curl -sS -m 60 "${H[@]}" "$BASE/api/organizations/$ORG/projects/?limit=500" | j "
for p in d.get('results',[]): print(p['id'], p.get('name',''))")
i=0
for n in $(seq 1 "$NP"); do
  name="Project $n"
  pid=$(printf '%s\n' "$have" | awk -v nm="$name" '{id=$1; $1=""; sub(/^ /,""); if ($0==nm) print id}' | head -1)
  if [ -z "$pid" ]; then
    resp=$(curl -sS -m 60 "${H[@]}" -X POST "$BASE/api/organizations/$ORG/projects/" -d "{\"name\":\"$name\"}")
    pid=$(printf '%s' "$resp" | j "i=d.get('id'); print(i if isinstance(i,int) else '')")
    if [ -z "$pid" ] && printf '%s' "$resp" | grep -q "maximum limit of allowed projects"; then
      # An unlicensed self-hosted PostHog allows ONE project: ORGANIZATIONS_PROJECTS is a paid feature
      # and the API answers 403. The remaining projects are created at the data plane with PostHog's
      # own Team.objects.create_with_data (the same code path the API uses after its licence check),
      # so every side row -- default dashboards, ingestion token, filters -- is what the app would
      # have written. Recorded in the ledger as what it is: the shape a paying customer has and a
      # free install cannot reach through the front door.
      [ -n "${_DP_NOTE:-}" ] || { echo "    API refused (403: project limit for the current plan); creating the rest at the data plane via Team.objects.create_with_data"; _DP_NOTE=1; }
      pid=$(docker exec -i "${PH_WEB_CONTAINER:-ph-web-1}" python manage.py shell -c "
from posthog.models import Organization, Team
o=Organization.objects.get(id='$ORG'); t=Team.objects.create_with_data(initiating_user=None, organization=o, name='$name'); print(t.id)" 2>/dev/null | tail -1)
      dp=$((${dp:-0}+1))
    fi
    [ -n "$pid" ] || { echo "could not create '$name': $(printf '%s' "$resp" | cut -c1-160)" >&2; exit 1; }
    i=$((i+1))
  fi
  tok=$(curl -sS -m 60 "${H[@]}" "$BASE/api/projects/$pid/" | j "print(d.get('api_token',''))")
  echo "$pid $tok" >> "$SPEC_DIR/.projects"
done
echo "    $(wc -l < "$SPEC_DIR/.projects") projects ($i created now, ${dp:-0} of them at the data plane)"
echo "==> $NE events per project through /capture/ (a real ingestion pass for every project)"
S=$(date +%s); sent=0
while read -r pid tok; do
  for e in $(seq 1 "$NE"); do
    curl -sS -m 30 -o /dev/null -H "Content-Type: application/json" -X POST "$BASE/capture/" \
      -d "{\"api_key\":\"$tok\",\"event\":\"$([ $((e%2)) = 0 ] && echo '$pageview' || echo signup)\",\"distinct_id\":\"core-$pid-$((e%3))\",\"properties\":{\"\$current_url\":\"https://app.example.test/home\",\"plan\":\"pro\",\"core\":$S}}"
    sent=$((sent+1))
  done
done < "$SPEC_DIR/.projects"
echo "    $sent events accepted"
# PostHog caches query results (cache_target_age is hours away); a poll that reads the cache never sees
# the row it is waiting for. refresh=force_blocking bypasses it.
echo "==> wait until the LAST project's events are queryable (ingestion caught up)"
read -r lpid ltok < <(tail -1 "$SPEC_DIR/.projects"); t0=$(date +%s.%N)
for _ in $(seq 1 240); do
  n=$(curl -sS -m 60 "${H[@]}" -X POST "$BASE/api/projects/$lpid/query/" -d "{\"query\":{\"kind\":\"HogQLQuery\",\"query\":\"select count() from events where properties.core = '$S'\"},\"refresh\":\"force_blocking\"}" | j "r=d.get('results') or [[0]]; print(r[0][0] if r and r[0] else 0)")
  [ "${n:-0}" -ge "$NE" ] && break; sleep 1
done
echo "    project $lpid sees $n of $NE after $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
[ "${n:-0}" -ge "$NE" ] || { echo "ingestion did not catch up" >&2; exit 1; }
echo "core done"
