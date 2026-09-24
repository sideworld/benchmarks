#!/usr/bin/env bash
# PR -> changed system serving, in Firecracker fork <k>.
# The "PR" is one line in posthog/views.py: /_health answers "ok paraglobe-pr1" instead of "ok".
# Unauthenticated, so "is this fork running the pull request's code?" is a string compare.
# A full PostHog image build is a multi-GB Python+Node build; a Python-only change does not need
# one (the same trick as Mastodon): the changed file is layered onto the pinned image with a
# two-line Dockerfile. web, worker and temporal-django-worker share that image; all three are
# recreated. Times build cold/warm, ship, load+swap, and to-serving.
#   benchmarks/posthog/pr-swap.sh <k> [image-only]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); P=${PH_SRC:-/tank/work/posthog}; SW=${PARAGLOBE_DIR:-/tank/work/paraglobe}
K=${1:?k}; KK=$(printf '%02d' "$K"); WT=$P-pr; SHA=$(git -C "$P" rev-parse HEAD)
BASE_IMG=posthog/posthog:$SHA; IMG=posthog/posthog:$SHA-pr
[ -d "$WT" ] || (cd "$P" && git worktree add -q --detach "$WT" HEAD)
F=$WT/posthog/views.py
grep -q 'paraglobe-pr1' "$F" || sed -i 's|        return HttpResponse("ok", status=status, content_type="text/plain")|        return HttpResponse("ok paraglobe-pr1", status=status, content_type="text/plain")|' "$F"
grep -n 'paraglobe-pr1' "$F" | sed 's/^/   /'
printf 'FROM %s\nCOPY --chown=posthog:posthog posthog/views.py /code/posthog/views.py\n' "$BASE_IMG" > "$WT/Dockerfile.pr"
f() { echo "$1 $2" | awk '{printf "%.1f", $2-$1}'; }
t0=$(date +%s.%N); docker build -q -t "$IMG" -f "$WT/Dockerfile.pr" "$WT" >/dev/null 2>&1; t1=$(date +%s.%N)
[ "${2:-}" = image-only ] && { echo "build=$(f "$t0" "$t1")s"; exit 0; }
SSH="ssh -p 3${KK}22 -i $SW/vm/out/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
docker save "$IMG" | $SSH root@127.0.0.1 'cat > /tmp/pr.tar'; t2=$(date +%s.%N)
$SSH root@127.0.0.1 "docker load -q -i /tmp/pr.tar >/dev/null && docker tag $IMG $BASE_IMG && rm /tmp/pr.tar
  cd /opt/app && . /etc/app.env && docker compose \${ENV_FILE:+--env-file \$ENV_FILE} \$COMPOSE_ARGS up -d --no-deps --force-recreate web worker temporal-django-worker >/dev/null 2>&1"; t3=$(date +%s.%N)
for _ in $(seq 1 2400); do v=$( { curl -s -m 5 "http://127.0.0.1:3${KK}80/_health" || true; } ); case "$v" in *paraglobe-pr1*) break ;; esac; sleep 0.25; done; t4=$(date +%s.%N)
echo "build=$(f "$t0" "$t1")s  ship=$(f "$t1" "$t2")s  load+swap=$(f "$t2" "$t3")s  serving=$(f "$t3" "$t4")s  total=$(f "$t0" "$t4")s  (/_health: '${v:-<none>}')"
