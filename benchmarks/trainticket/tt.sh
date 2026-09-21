#!/usr/bin/env bash
# Run TrainTicket's own docker-compose.yml with our override. Wraps the long compose
# invocation; everything else is upstream's file, unmodified.
#   benchmarks/trainticket/tt.sh up|down|ps|logs|config ... [compose args]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TT=${TT_DIR:-/tank/work/trainticket}
PROJECT=${TT_PROJECT:-tt}
[ -f "$HERE/compose/docker-compose.tt.yml" ] || python3 "$HERE/compose/gen-override.py" "$TT/docker-compose.yml" > "$HERE/compose/docker-compose.tt.yml"
exec docker compose -p "$PROJECT" --project-directory "$TT" \
  --env-file "$HERE/compose/tt.env" \
  -f "$TT/docker-compose.yml" -f "$HERE/compose/docker-compose.tt.yml" "$@"
