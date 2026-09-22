#!/usr/bin/env bash
# PR -> changed system serving, in VM fork <k>. The "PR" is a one-line change to
# lib/mastodon/version.rb (build metadata 'pr1' on the version string, visible in /api/v1/instance),
# layered onto the prebuilt image with a two-line Dockerfile: a full Mastodon image build is a
# ~15-minute asset compile, and a Ruby-only change does not need one. Ships it into the fork,
# swaps web (and sidekiq), times to serving.
#   benchmarks/mastodon/pr-swap.sh <k> [image-only]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); MD=${MD_DIR:-/tank/work/mastodon}
SIDEWORLD_DIR=${SIDEWORLD_DIR:-$(cd "$HERE/../../../sideworld" 2>/dev/null && pwd || echo "$HERE/../../../sideworld")}  # sibling checkout of the fork runtime
K=${1:?k}; KK=$(printf '%02d' "$K"); WT=$MD-pr; IMG=ghcr.io/mastodon/mastodon:v4.7.2-pr
H=(-H "X-Forwarded-Proto: https" -H "Host: mastodon.test")
[ -d "$WT" ] || (cd "$MD" && git worktree add -q --detach "$WT" HEAD)
# the one line: build_metadata falls back to 'pr1', so Mastodon::Version.to_s == "4.7.2+pr1"
grep -q "pr1" "$WT/lib/mastodon/version.rb" || sed -i "s|      version_configuration\[:metadata\]$|      version_configuration[:metadata].presence \|\| 'pr1'|" "$WT/lib/mastodon/version.rb"
grep -A1 'def build_metadata' "$WT/lib/mastodon/version.rb" | sed 's/^/   /'
printf 'FROM ghcr.io/mastodon/mastodon:v4.7.2\nCOPY --chown=mastodon:mastodon lib/mastodon/version.rb /opt/mastodon/lib/mastodon/version.rb\n' > "$WT/Dockerfile.pr"
t0=$(date +%s.%N)
docker build -q -t "$IMG" -f "$WT/Dockerfile.pr" "$WT" >/dev/null 2>&1
t1=$(date +%s.%N)
[ "${2:-}" = image-only ] && { echo "built $IMG in $(echo "$t0 $t1" | awk '{printf "%.1f", $2-$1}')s"; exit 0; }
SSH="ssh -p 3${KK}22 -i $SIDEWORLD_DIR/vm/out/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
docker save "$IMG" | $SSH root@127.0.0.1 'cat > /tmp/pr.tar'
t2=$(date +%s.%N)
$SSH root@127.0.0.1 'docker load -q -i /tmp/pr.tar >/dev/null && docker tag ghcr.io/mastodon/mastodon:v4.7.2-pr ghcr.io/mastodon/mastodon:v4.7.2 && rm /tmp/pr.tar
  cd /opt/app && . /etc/app.env && docker compose ${ENV_FILE:+--env-file $ENV_FILE} $COMPOSE_ARGS up -d --no-deps --force-recreate web sidekiq >/dev/null 2>&1'   # the env file carries the guest port binds
t3=$(date +%s.%N)
# `|| true`: while web is being recreated curl exits 7 (refused), which under set -e/pipefail killed the script
for _ in $(seq 1 600); do v=$( { curl -s -m 5 "${H[@]}" "http://127.0.0.1:3${KK}80/api/v1/instance" || true; } | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["version"])
except Exception: print("")'); case "$v" in *pr1*) break ;; esac; sleep 0.25; done
t4=$(date +%s.%N)
f() { echo "$1 $2" | awk '{printf "%.1f", $2-$1}'; }
echo "build=$(f "$t0" "$t1")s ship=$(f "$t1" "$t2")s load+swap=$(f "$t2" "$t3")s serving=$(f "$t3" "$t4")s  total=$(f "$t0" "$t4")s  (version: $v)"
