#!/usr/bin/env bash
# Compose+ZFS fork of TrainTicket (the engine-less path): clone the 25 datasets from
# @<snapshot>, generate an override with vm/mkfork-generic.sh, bring the project up,
# measure time to healthy, per-fork RAM (cgroups) and storage delta, and do one write
# through the API to show forks do not see each other's data.
#   benchmarks/trainticket/fork.sh <n> [snapshot]      (n = 1..3; ports offset by 13000*n)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARAGLOBE_DIR=${PARAGLOBE_DIR:-$(cd "$HERE/../../../paraglobe" 2>/dev/null && pwd || echo "$HERE/../../../paraglobe")}  # sibling checkout of the fork runtime
N=${1:?n}; SNAP=${2:-tt-base}
TT=${TT_DIR:-/tank/work/trainticket}
P=tt-f$N; OFF=$((13000 * N))
OUT=$HERE/compose/docker-compose.$P.yml
set -a; . "$HERE/compose/tt.env"; set +a           # IMG_REPO etc. for config resolution
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "fork $N from @$SNAP: clones + override (port offset +$OFF)"
t0=$(date +%s.%N)
FORK_MAP="$HERE/fork.map" OFFSET=$OFF PROJECT=$P OUT=$OUT \
  "$PARAGLOBE_DIR/vm/mkfork-generic.sh" "$TT" "$N" "$SNAP" -f "$TT/docker-compose.yml" -f "$HERE/compose/docker-compose.tt.yml" >/dev/null
t_clone=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}')
n_clones=$(zfs list -H -o name -t filesystem | grep -c "^tank/tt-f$N-")
log "$n_clones clones + override in ${t_clone}s"

log "up --wait"
t0=$(date +%s.%N)
docker compose -p "$P" --project-directory "$TT" --env-file "$HERE/compose/tt.env" \
  -f "$TT/docker-compose.yml" -f "$HERE/compose/docker-compose.tt.yml" -f "$OUT" up -d --wait 2>&1 \
  | grep -vE 'level=warning' | grep -iE 'unhealthy|error' || true
T_UP=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
healthy=$(docker ps --filter "label=com.docker.compose.project=$P" --format '{{.Status}}' | grep -c '(healthy)')
log "t_boot_to_healthy=${T_UP}s  healthy=$healthy/68"

AUTH=$((12340 + OFF)); TRAVEL=$((12346 + OFF)); UI=$((8080 + OFF)); CONTACTS=$((12347 + OFF))
log "probe on fork ports (auth $AUTH, travel $TRAVEL, ui $UI)"
SEARCH_TIMEOUT=600 "$HERE/probe.sh" 127.0.0.1 "$AUTH" "$TRAVEL" "$UI" || log "probe FAILED"

# ---- isolation: one contact created through this fork's API, as a generated user
tok=$(curl -s -m 10 -X POST "http://127.0.0.1:$AUTH/api/v1/users/login" -H 'Content-Type: application/json' \
      -d '{"username":"user_0000042","password":"111111","verificationCode":""}' \
      | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]; print(d["token"], d["userId"])')
read -r TOK UID_ <<<"$tok"
code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$CONTACTS/api/v1/contactservice/contacts" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOK" \
  -d "{\"accountId\":\"$UID_\",\"name\":\"fork-$N-probe\",\"documentType\":1,\"documentNumber\":\"F$N\",\"phoneNumber\":\"000$N\"}")
count() { docker exec "$1" mongo --quiet ts --eval 'db.contacts.count({name:/^fork-.*-probe$/})'; }
log "isolation: POST contact via fork $N -> HTTP $code; fork-probe contacts: native=$(count tt-ts-contacts-mongo-1) fork$N=$(count $P-ts-contacts-mongo-1)$(for k in 1 2 3; do [ "$k" != "$N" ] && docker ps --format '{{.Names}}' | grep -q "^tt-f$k-ts-contacts-mongo-1$" && printf ' fork%s=%s' "$k" "$(count tt-f$k-ts-contacts-mongo-1)"; done)"

# ---- RAM from cgroups, storage from zfs
sum=0; for id in $(docker ps -q --filter "label=com.docker.compose.project=$P" --no-trunc); do
  f=/sys/fs/cgroup/system.slice/docker-$id.scope/memory.current; [ -f "$f" ] && sum=$((sum + $(cat "$f"))); done
used=$(zfs list -Hp -o used -t filesystem $(zfs list -H -o name -t filesystem | grep "^tank/tt-f$N-") | awk '{s+=$1} END{print s}')
log "fork $N: ram_cgroup_mib=$((sum / 1048576))  storage_delta_mib=$((used / 1048576)) (across $n_clones clones)"
echo "fork=$N t_clone=$t_clone t_boot_to_healthy=$T_UP healthy=$healthy ram_mib=$((sum/1048576)) storage_mib=$((used/1048576)) isolation_http=$code"
