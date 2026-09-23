#!/usr/bin/env bash
# PR -> changed system serving, in VM fork <k>.
#
# The "PR" is one line in server/channels/api4/system.go: the ping handler returns an extra key.
# Unauthenticated and trivially checkable, so "is the fork running the pull request's code?" has
# a yes/no answer rather than an inference.
#
#   benchmarks/mattermost/pr-swap.sh <k> [image-only]
#
# Unlike the Rails and Python worlds there is no trick here: the server really is rebuilt from
# source with Mattermost's own recipe, because a warm Go build is seconds. The image is the
# published release image with the two rebuilt binaries laid on top (see image/Dockerfile).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MM=${MM_SRC:-/tank/work/mattermost}
SIDEWORLD_DIR=${SIDEWORLD_DIR:-/tank/work/sideworld}
K=${1:?k}; KK=$(printf '%02d' "$K")
WT=$MM-pr
IMG=sideworld/mattermost-server:v11.11.0-pr
BASE_IMG=sideworld/mattermost-server:v11.11.0

[ -d "$WT" ] || (cd "$MM" && git worktree add -q --detach "$WT" HEAD)

# the one line
F=$WT/server/channels/api4/system.go
grep -q 'SideworldPR' "$F" || sed -i 's|^\ts\[model.STATUS\] = model.StatusOk$|\ts[model.STATUS] = model.StatusOk\n\ts["SideworldPR"] = "pr1"|' "$F"
grep -n 'SideworldPR' "$F" | sed 's/^/   /'

t0=$(date +%s.%N)
( cd "$WT/server" && make build-cmd-linux BUILD_NUMBER=pr1 SKIP_SETUP_GO_WORK=false >/dev/null )
t1=$(date +%s.%N)
printf 'FROM %s\nCOPY --chown=2000:2000 bin/mattermost /mattermost/bin/mattermost\nCOPY --chown=2000:2000 bin/mmctl /mattermost/bin/mmctl\n' \
  "mattermost/mattermost-team-edition:11.11.0" > "$WT/server/Dockerfile.pr"
docker build -q -t "$IMG" -f "$WT/server/Dockerfile.pr" "$WT/server" >/dev/null
t2=$(date +%s.%N)
f() { echo "$1 $2" | awk '{printf "%.1f", $2-$1}'; }
[ "${2:-}" = image-only ] && { echo "go build=$(f "$t0" "$t1")s  image=$(f "$t1" "$t2")s"; exit 0; }

SSH="ssh -p 3${KK}22 -i $SIDEWORLD_DIR/vm/out/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
docker save "$IMG" | $SSH root@127.0.0.1 'cat > /tmp/pr.tar'
t3=$(date +%s.%N)
$SSH root@127.0.0.1 "docker load -q -i /tmp/pr.tar >/dev/null && docker tag $IMG $BASE_IMG && rm /tmp/pr.tar
  cd /opt/app && . /etc/app.env && docker compose \${ENV_FILE:+--env-file \$ENV_FILE} \$COMPOSE_ARGS up -d --no-deps --force-recreate mattermost >/dev/null 2>&1"
t4=$(date +%s.%N)
# curl exits 7 while the container is being recreated; `|| true` keeps set -e out of it
for _ in $(seq 1 1200); do
  v=$( { curl -s -m 5 "http://127.0.0.1:3${KK}80/api/v4/system/ping" || true; } | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("SideworldPR",""))
except Exception: print("")')
  [ "$v" = pr1 ] && break
  sleep 0.25
done
t5=$(date +%s.%N)
echo "go build=$(f "$t0" "$t1")s  image=$(f "$t1" "$t2")s  ship=$(f "$t2" "$t3")s  load+swap=$(f "$t3" "$t4")s  serving=$(f "$t4" "$t5")s  total=$(f "$t0" "$t5")s  (SideworldPR: ${v:-<absent>})"
