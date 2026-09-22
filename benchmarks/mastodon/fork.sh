#!/usr/bin/env bash
# Compose+ZFS fork of Mastodon (the engine-less path): clone the three datasets from @<snapshot>,
# generate an override with vm/mkfork-generic.sh (fork map from the app spec), bring the project
# up, measure time to healthy + ready, per-fork RAM (cgroups) and storage delta, and post one
# status through the fork's API to show forks do not see each other's data.
#   benchmarks/mastodon/fork.sh <n> [snapshot]      (ports offset by 20000*n: web 23300, 43300, ...)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MICROMONKIS_DIR=${MICROMONKIS_DIR:-$(cd "$HERE/../../../micromonkis" 2>/dev/null && pwd || echo "$HERE/../../../micromonkis")}  # sibling checkout of the fork runtime
N=${1:?n}; SNAP=${2:-md-base}; MD=${MD_DIR:-/tank/work/mastodon}
P=md-f$N; OFF=$((20000 * N)); OUT=$HERE/compose/docker-compose.$P.yml
H=(-H "X-Forwarded-Proto: https" -H "Host: mastodon.test")
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
dc() { docker compose -p "$P" --project-directory "$MD" -f "$MD/docker-compose.yml" -f "$HERE/compose/docker-compose.md.yml" -f "$OUT" "$@"; }

log "fork $N from @$SNAP: clones + override (port offset +$OFF)"
"$MICROMONKIS_DIR/vm/app-datasets.sh" "$HERE/app.spec" forkmap "tank/md-f{n}-" > "$HERE/fork.map"
t0=$(date +%s.%N)
FORK_MAP=$HERE/fork.map OFFSET=$OFF PROJECT=$P OUT=$OUT \
  "$MICROMONKIS_DIR/vm/mkfork-generic.sh" "$MD" "$N" "$SNAP" -f "$MD/docker-compose.yml" -f "$HERE/compose/docker-compose.md.yml" >/dev/null
t_clone=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.2f", $2-$1}')
n_clones=$(zfs list -H -o name -t filesystem | grep -c "^tank/md-f$N-")
log "$n_clones clones + override in ${t_clone}s"

log "up --wait"
t0=$(date +%s.%N)
dc up -d --wait 2>&1 | grep -vE 'level=warning' | grep -iE 'unhealthy|error' || true
T_UP=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
healthy=$(docker ps --filter "label=com.docker.compose.project=$P" --format '{{.Status}}' | grep -c '(healthy)')
log "t_boot_to_healthy=${T_UP}s  healthy=$healthy/7"
WEB=$((3300 + OFF)); STREAM=$((4300 + OFF))
log "readiness probe on fork ports (web $WEB, streaming $STREAM)"
MD_PROJECT=$P MD_TOKEN=$(cat "$HERE/.token") "$HERE/probe.sh" 127.0.0.1 "$WEB" "$STREAM" || log "probe FAILED"
T_READY=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')

# ---- isolation: one status posted through this fork's API, as the admin (its token is in the clone)
code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "${H[@]}" -H "Authorization: Bearer $(cat "$HERE/.token")" \
  -X POST "http://127.0.0.1:$WEB/api/v1/statuses" -d "status=fork-$N-probe")
# by the admin's (account_id, id) index; a bare `text LIKE` would seq-scan the 25 GB statuses heap
count() { docker exec "$1" psql -U postgres -d mastodon_production -Atc "select count(*) from statuses where account_id = (select id from accounts where username='admin' and domain is null) and text like 'fork-%-probe'"; }
log "isolation: POST status via fork $N -> HTTP $code; fork-probe statuses: native=$(count md-db-1) fork$N=$(count $P-db-1)$(for k in 1 2 3; do [ "$k" != "$N" ] && docker ps --format '{{.Names}}' | grep -q "^md-f$k-db-1$" && printf ' fork%s=%s' "$k" "$(count md-f$k-db-1)"; done)"

# ---- RAM from cgroups, storage from zfs
sum=0; for id in $(docker ps -q --filter "label=com.docker.compose.project=$P" --no-trunc); do
  f=/sys/fs/cgroup/system.slice/docker-$id.scope/memory.current; [ -f "$f" ] && sum=$((sum + $(cat "$f"))); done
used=$(zfs list -Hp -o used -t filesystem $(zfs list -H -o name -t filesystem | grep "^tank/md-f$N-") | awk '{s+=$1} END{print s}')
log "fork $N: ram_cgroup_mib=$((sum / 1048576))  storage_delta_mib=$((used / 1048576)) (across $n_clones clones)"
echo "fork=$N t_clone=$t_clone t_boot_to_healthy=$T_UP t_ready=$T_READY healthy=$healthy ram_mib=$((sum/1048576)) storage_mib=$((used/1048576)) isolation_http=$code"
