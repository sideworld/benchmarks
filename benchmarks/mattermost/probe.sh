#!/usr/bin/env bash
# PROBE -- the readiness gate. Deliberately a ROUND TRIP, not /api/v4/system/ping.
#
# Mattermost answers ping while the store is still migrating, so ping proves only that a Go
# process bound a port. This creates a team and a user, has that user post into a channel as
# themselves, and then reads the message back out of channel history by id. That crosses the
# API, Postgres (Teams, Users, Channels, ChannelMembers, Posts), the session store and the
# post-list read path. If any of those is not really up, this fails.
#
#   benchmarks/mattermost/probe.sh [base-url]
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE=${1:-${MM_BASE:-http://127.0.0.1:8065}}
TOK=${MM_TOKEN:-$(cat "$SPEC_DIR/.token" 2>/dev/null || true)}
[ -n "$TOK" ] || { echo "no admin token: run init-app.sh first" >&2; exit 1; }
S=$(date +%s)
api() { curl -sS -m 30 -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$@"; }
jq_() { python3 -c "import json,sys;d=json.load(sys.stdin);print(d$1)"; }
t0=$(date +%s.%N); el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}'; }

echo "==> ping"
code=$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$BASE/api/v4/system/ping")
[ "$code" = 200 ] || { echo "ping HTTP $code" >&2; exit 1; }
echo "    HTTP 200 after $(el $t0)s"

echo "==> create team probe-$S"
TEAM=$(api -X POST "$BASE/api/v4/teams" -d "{\"name\":\"probe-$S\",\"display_name\":\"Probe $S\",\"type\":\"O\"}" | jq_ "['id']")
echo "    team $TEAM"

echo "==> a user to post as"
# An UNLICENSED Mattermost refuses to create users past `maxUsersLimit = 200`
# (server/channels/app/limits.go:13) with ERROR_SAFETY_LIMITS_EXCEEDED. The populated world has
# 2,022 users, so creating one here is not possible -- and that is a fact about the product at
# scale, not a broken probe. On an empty world the create succeeds and the gate covers it; on a
# populated one we log in as a user that already exists. Either way something posts and something
# reads it back.
PW=${MM_PROBE_PW:-Probe-12345}
RESP=$(api -X POST "$BASE/api/v4/users" -d "{\"email\":\"probe$S@example.test\",\"username\":\"probe$S\",\"password\":\"$PW\"}")
USER=$(printf '%s' "$RESP" | python3 -c "
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: d={}
i=d.get('id','')
print(i if re.fullmatch(r'[a-z0-9]{26}', i or '') else '')")
if [ -n "$USER" ]; then
  LOGIN="probe$S@example.test"
  api -X POST "$BASE/api/v4/teams/$TEAM/members" -d "{\"team_id\":\"$TEAM\",\"user_id\":\"$USER\"}" >/dev/null
  echo "    created user $USER, added to the team"
else
  why=$(printf '%s' "$RESP" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')")
  LOGIN=${MM_PROBE_USER:-core1}; PW=${MM_PROBE_PW_EXISTING:-Paraglobe-1234}
  USER=$(api "$BASE/api/v4/users/username/$LOGIN" | jq_ "['id']")
  [ -n "$USER" ] || { echo "cannot create a user ($why) and $LOGIN does not exist either" >&2; exit 1; }
  api -X POST "$BASE/api/v4/teams/$TEAM/members" -d "{\"team_id\":\"$TEAM\",\"user_id\":\"$USER\"}" >/dev/null
  echo "    server refused a new user ($why); posting as the existing $LOGIN instead"
fi

echo "==> town-square of that team"
CH=$(api "$BASE/api/v4/teams/$TEAM/channels/name/town-square" | jq_ "['id']")
echo "    channel $CH"

echo "==> log the user in and post AS THEM"
HDR=$(mktemp); curl -sS -m 30 -D "$HDR" -o /dev/null -H 'Content-Type: application/json' \
  -X POST "$BASE/api/v4/users/login" -d "{\"login_id\":\"$LOGIN\",\"password\":\"$PW\"}"
UTOK=$(awk 'tolower($1)=="token:"{print $2}' "$HDR" | tr -d '\r'); rm -f "$HDR"
[ -n "$UTOK" ] || { echo "login produced no session token" >&2; exit 1; }
MSG="paraglobe round trip $S"
POST=$(curl -sS -m 30 -H "Authorization: Bearer $UTOK" -H 'Content-Type: application/json' \
  -X POST "$BASE/api/v4/posts" -d "{\"channel_id\":\"$CH\",\"message\":\"$MSG\"}" | jq_ "['id']")
echo "    post $POST"

echo "==> read it back out of channel history"
found=$(curl -sS -m 30 -H "Authorization: Bearer $UTOK" "$BASE/api/v4/channels/$CH/posts?per_page=20" \
  | PID="$POST" python3 -c "
import json,sys,os
d=json.load(sys.stdin); p=d.get('posts',{}).get(os.environ['PID'])
print(p['message'] if p else '')")
[ "$found" = "$MSG" ] || { echo "round trip FAILED: history returned '$found'" >&2; exit 1; }
echo "    history returned: $found"
echo "ROUND TRIP OK in $(el $t0)s"
