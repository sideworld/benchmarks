#!/usr/bin/env bash
# HOOK_PRE_UP -- build the app image the compose file names (app/Dockerfile).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMG=sideworld/cascade-app:v1       # the name compose/docker-compose.cascade.yml runs
docker build -q -t "$IMG" "$HERE/app" | sed 's/^/    /'
