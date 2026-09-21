#!/usr/bin/env bash
# Run Mastodon's own docker-compose.yml with our override. Everything else is upstream's.
#   benchmarks/mastodon/md.sh up|down|ps|logs|exec|run ... [compose args]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MD=${MD_DIR:-/tank/work/mastodon}
PROJECT=${MD_PROJECT:-md}
exec docker compose -p "$PROJECT" --project-directory "$MD" \
  -f "$MD/docker-compose.yml" -f "$HERE/compose/docker-compose.md.yml" "$@"
