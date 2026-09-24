#!/usr/bin/env bash
# PROBE -- the readiness gate. A ROUND TRIP, not /_health.
#
# /_health is Django answering. This logs in, captures an event through the public ingestion
# endpoint (Caddy -> the Rust `capture` container -> Redpanda), and then asks a HogQL query for
# that event until it is there -- which means the Node plugin-server consumed it and wrote it to
# ClickHouse. Every state store and both ingestion tiers must be up for this to pass. That is what
# "PostHog is ready" means; nothing weaker counts.
#
#   benchmarks/posthog/probe.sh [base-url]        (first run signs the instance up; later runs log in)
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=${1:-${PH_BASE:-http://127.0.0.1:8100}}
EMAIL=${PH_ADMIN_EMAIL:-sideworld@example.test}; PASS=${PH_ADMIN_PASS:-Sideworld-12345678}
CJ=$(mktemp); trap 'rm -f "$CJ"' EXIT
S=$(date +%s); t0=$(date +%s.%N); el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}'; }
j() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
$1"; }

echo "==> /_health"
code=$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$BASE/_health"); [ "$code" = 200 ] || { echo "    HTTP $code" >&2; exit 1; }
echo "    HTTP 200 after $(el $t0)s"

echo "==> a session: sign up the first user, or log in"
# CSRF: PostHog's session auth wants the csrftoken cookie echoed back as a header.
curl -sS -m 30 -c "$CJ" -o /dev/null "$BASE/login"
CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")
code=$(curl -sS -m 60 "${H[@]}" -o /tmp/ph-signup.json -w '%{http_code}' -X POST "$BASE/api/signup/" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"first_name\":\"Side\",\"organization_name\":\"Paraglobe\",\"role_at_organization\":\"engineering\"}")
[ "$code" = 201 ] && echo "    signed up $EMAIL (HTTP 201) -- first boot"
login() { curl -sS -m 60 "${H[@]}" -o /tmp/ph-login.json -w '%{http_code}' -X POST "$BASE/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"; }
code=$(login)
if [ "$code" = 401 ] && grep -q verify_email_pending /tmp/ph-login.json; then
  # With EMAIL_ENABLED (we point it at the maildev sink) PostHog gates the first login on a 6-digit
  # code it mails out. The 401 carries the user's uuid in `detail`; the code is in the sink.
  UUID=$(python3 -c "import json;print(json.load(open('/tmp/ph-login.json')).get('detail',''))")
  CODE=$(curl -sS -m 10 "${PH_MAILDEV:-http://127.0.0.1:1180}/email" | python3 -c "
import json,sys,re,html
ms=[m for m in json.load(sys.stdin) if 'Verify' in (m.get('subject') or '')]
t=html.unescape(re.sub(r'<[^>]+>',' ',(ms[-1].get('html') or '')+' '+(ms[-1].get('text') or ''))) if ms else ''
r=re.findall(r'\b([0-9]{6}) is your code',t); print(r[0] if r else '')")
  [ -n "$CODE" ] || { echo "    login gated on email verification and no code in the mail sink" >&2; exit 1; }
  curl -sS -m 30 "${H[@]}" -o /dev/null -X POST "$BASE/api/users/verify_email/" -d "{\"uuid\":\"$UUID\",\"code\":\"$CODE\"}"
  echo "    email verified with code $CODE from the mail sink (a real round trip through SMTP)"
  code=$(login)
fi
[ "$code" = 200 ] || { echo "    login HTTP $code: $(cut -c1-160 /tmp/ph-login.json)" >&2; exit 1; }
echo "    logged in $EMAIL (HTTP 200)"
CSRF=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $CSRF" -H "Referer: $BASE/" -b "$CJ" -c "$CJ")

echo "==> the project and its ingestion token"
read -r PID TOKEN < <(curl -sS -m 30 "${H[@]}" "$BASE/api/projects/@current/" | j "print(d.get('id',''), d.get('api_token',''))")
[ -n "$PID" ] && [ -n "$TOKEN" ] || { echo "    no current project" >&2; exit 1; }
echo "    project $PID, token ${TOKEN:0:8}…"
printf '%s\n' "$PID" > "$SPEC_DIR/.project"; umask 077; printf '%s\n' "$TOKEN" > "$SPEC_DIR/.token"

echo "==> capture one event through /capture/ (Caddy -> rust capture -> Redpanda)"
EV="paraglobe_round_trip"; DID="probe-$S"
code=$(curl -sS -m 30 -o /tmp/ph-cap.json -w '%{http_code}' -H "Content-Type: application/json" -X POST "$BASE/capture/" \
  -d "{\"api_key\":\"$TOKEN\",\"event\":\"$EV\",\"distinct_id\":\"$DID\",\"properties\":{\"probe\":$S,\"\$lib\":\"paraglobe\"},\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
[ "$code" = 200 ] || { echo "    capture HTTP $code: $(cut -c1-160 /tmp/ph-cap.json)" >&2; exit 1; }
echo "    accepted (HTTP 200) at $(el $t0)s"

# PostHog caches query results (cache_target_age is hours away); a poll that reads the cache never sees
# the row it is waiting for. refresh=force_blocking bypasses it.
echo "==> ask ClickHouse for it, through HogQL (plugin-server -> ClickHouse)"
t1=$(date +%s.%N); n=0
for _ in $(seq 1 240); do
  n=$(curl -sS -m 60 "${H[@]}" -X POST "$BASE/api/projects/$PID/query/" \
      -d "{\"query\":{\"kind\":\"HogQLQuery\",\"query\":\"select count() from events where event = '$EV' and distinct_id = '$DID'\"},\"refresh\":\"force_blocking\"}" \
      | j "r=d.get('results') or [[0]]; print(r[0][0] if r and r[0] else 0)")
  [ "${n:-0}" -ge 1 ] && break; sleep 0.5
done
[ "${n:-0}" -ge 1 ] || { echo "    the event never appeared in ClickHouse (120 s)" >&2; exit 1; }
echo "    found after $(el $t1)s of polling"
echo "ROUND TRIP OK in $(el $t0)s  (capture -> Kafka -> plugin-server -> ClickHouse -> HogQL)"
