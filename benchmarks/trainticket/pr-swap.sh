#!/usr/bin/env bash
# "PR to changed system serving" in VM fork <k>: rebuild ts-ui-dashboard from a detached
# worktree with one visible change, ship it into the fork, swap it, time until it serves.
#   benchmarks/trainticket/pr-swap.sh <k>
# Added after the repeat-onboarding run, in which these eight steps were done by hand.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARAGLOBE_DIR=${PARAGLOBE_DIR:-$(cd "$HERE/../../../paraglobe" 2>/dev/null && pwd || echo "$HERE/../../../paraglobe")}  # sibling checkout of the fork runtime
K=${1:?k}; KK=$(printf '%02d' "$K"); TT=${TT_DIR:-/tank/work/trainticket}; WT=$TT-pr
SSH="ssh -p 3${KK}22 -i $PARAGLOBE_DIR/vm/out/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
[ -d "$WT" ] || (cd "$TT" && git worktree add -q --detach "$WT" HEAD)
sed -i 's|<title>TrainTicket Admin</title>|<title>TrainTicket Admin (PR-1 build)</title>|' "$WT/ts-ui-dashboard/static/index.html"
t0=$(date +%s.%N)
docker build -q -t codewisdom/ts-ui-dashboard:0.2.0-pr "$WT/ts-ui-dashboard/" >/dev/null 2>&1
t1=$(date +%s.%N)
docker save codewisdom/ts-ui-dashboard:0.2.0-pr | $SSH root@127.0.0.1 'cat > /tmp/ui-pr.tar'
t2=$(date +%s.%N)
$SSH root@127.0.0.1 'docker load -q -i /tmp/ui-pr.tar >/dev/null && docker tag codewisdom/ts-ui-dashboard:0.2.0-pr codewisdom/ts-ui-dashboard:0.2.0 && rm /tmp/ui-pr.tar
  cd /opt/app && . /etc/app.env && docker compose --env-file app.env $COMPOSE_ARGS up -d --no-deps --force-recreate ts-ui-dashboard >/dev/null 2>&1'
t3=$(date +%s.%N)
for _ in $(seq 1 240); do t=$(curl -s -m 3 "http://127.0.0.1:3${KK}80/index.html" | grep -o '<title>[^<]*</title>' || true); case "$t" in *PR-1*) break ;; esac; sleep 0.25; done
t4=$(date +%s.%N)
f() { echo "$1 $2" | awk '{printf "%.1f", $2-$1}'; }
echo "build=$(f "$t0" "$t1")s ship=$(f "$t1" "$t2")s load+swap=$(f "$t2" "$t3")s serving=$(f "$t3" "$t4")s  total=$(f "$t0" "$t4")s  ($t)"
