#!/usr/bin/env bash
# Inverse of fork.sh: down the project, destroy its 25 clones, remove the override.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
N=${1:?n}; P=tt-f$N; TT=${TT_DIR:-/tank/work/trainticket}
set -a; . "$HERE/compose/tt.env"; set +a
OUT=$HERE/compose/docker-compose.$P.yml
if [ -f "$OUT" ]; then
  docker compose -p "$P" --project-directory "$TT" --env-file "$HERE/compose/tt.env" \
    -f "$TT/docker-compose.yml" -f "$HERE/compose/docker-compose.tt.yml" -f "$OUT" down --remove-orphans 2>&1 | grep -vE 'level=warning' | tail -1
fi
for c in $(zfs list -H -o name -t filesystem | grep "^tank/tt-f$N-"); do
  [ "$(zfs get -H -o value origin "$c")" != "-" ] || { echo "refusing: $c is not a clone" >&2; exit 1; }
  zfs destroy "$c"
done
rm -f "$OUT"
echo "fork $N removed: $(zfs list -H -o name -t filesystem | grep -c "^tank/tt-f$N-") clones left, project $(docker ps -aq --filter "label=com.docker.compose.project=$P" | wc -l) containers left"
