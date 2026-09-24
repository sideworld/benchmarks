#!/usr/bin/env bash
# The coherent core, created through Mattermost's own REST API so that the world is anchored in
# rows the application itself wrote: a team, real users with real password hashes and sessions,
# real channels with their default categories and sidebar entries, and real posts.
#
# Only the core goes through the API. Twenty million posts do not: at ~20 requests/second that is
# eleven days. The bulk lives in scale/gen.sql at the data plane, shaped to match exactly what
# these rows look like.
#
#   benchmarks/mattermost/scale/core.sh [users] [channels] [posts-per-channel]
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=${MM_BASE:-http://127.0.0.1:8065}
TOK=$(cat "$SPEC_DIR/.token")
NU=${1:-20}; NC=${2:-20}; NP=${3:-5}
api() { curl -sS -m 60 -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' "$@"; }
# Mattermost's ERROR bodies also carry an "id" -- the error code, e.g.
#   {"id":"app.team.get_by_name.missing.app_error","status_code":404,...}
# Taking d['id'] blindly made a 404 look like a team id, after which every create silently
# no-opped and the whole core "succeeded" in 2.9 seconds. Only a real 26-char id counts.
id_() { python3 -c "
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
i=d.get('id','') if isinstance(d,dict) else ''
print(i if re.fullmatch(r'[a-z0-9]{26}', i or '') else '')"; }
need() { [ -n "$1" ] || { echo "FAILED: $2" >&2; exit 1; }; }

echo "==> team"
TEAM=$(api "$BASE/api/v4/teams/name/sideworld" | id_)
if [ -z "$TEAM" ]; then
  TEAM=$(api -X POST "$BASE/api/v4/teams" -d '{"name":"sideworld","display_name":"Sideworld","type":"O"}' | id_)
fi
need "$TEAM" "could not create or find the team"
echo "    $TEAM"

echo "==> $NU users"
: > "$SPEC_DIR/.core-users"
for i in $(seq 1 "$NU"); do
  u=core$i
  uid=$(api "$BASE/api/v4/users/username/$u" | id_)
  [ -n "$uid" ] || uid=$(api -X POST "$BASE/api/v4/users" \
      -d "{\"email\":\"$u@example.test\",\"username\":\"$u\",\"password\":\"Sideworld-1234\"}" | id_)
  need "$uid" "could not create user $u"
  api -X POST "$BASE/api/v4/teams/$TEAM/members" -d "{\"team_id\":\"$TEAM\",\"user_id\":\"$uid\"}" >/dev/null
  echo "$uid" >> "$SPEC_DIR/.core-users"
done
echo "    $(wc -l < "$SPEC_DIR/.core-users") users on the team"

echo "==> $NC channels, every core user a member, $NP posts each"
: > "$SPEC_DIR/.core-channels"
for i in $(seq 1 "$NC"); do
  n=core-$i
  cid=$(api "$BASE/api/v4/teams/$TEAM/channels/name/$n" | id_)
  [ -n "$cid" ] || cid=$(api -X POST "$BASE/api/v4/channels" \
      -d "{\"team_id\":\"$TEAM\",\"name\":\"$n\",\"display_name\":\"Core $i\",\"type\":\"O\"}" | id_)
  need "$cid" "could not create channel $n"
  while read -r uid; do
    api -X POST "$BASE/api/v4/channels/$cid/members" -d "{\"user_id\":\"$uid\"}" >/dev/null
  done < "$SPEC_DIR/.core-users"
  for p in $(seq 1 "$NP"); do
    uid=$(sed -n "$(( (p % NU) + 1 ))p" "$SPEC_DIR/.core-users")
    api -X POST "$BASE/api/v4/posts" \
      -d "{\"channel_id\":\"$cid\",\"message\":\"core seed post $p in $n — deployment rollout status\"}" >/dev/null
  done
  echo "$cid" >> "$SPEC_DIR/.core-channels"
done
echo "    $(wc -l < "$SPEC_DIR/.core-channels") channels"
printf '%s\n' "$TEAM" > "$SPEC_DIR/.core-team"
echo "core done: team $TEAM"
