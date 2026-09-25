#!/usr/bin/env bash
# PROBE -- every service answers, and each reaches Postgres through PgBouncer (GET /ready runs
# SELECT 1 through the service's own pool). Runs before the generator, so it asks for no data.
#   probe.sh [host]       ports from compose/cascade.env (18480-18483)
set -euo pipefail
H=${1:-127.0.0.1}
for p in 18480:api 18481:billing 18482:dashboard 18483:ingest; do
  port=${p%%:*}; name=${p#*:}
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$H:$port/ready" || true)
    [ "$code" = 200 ] && break; sleep 1
  done
  [ "$code" = 200 ] || { echo "$name: /ready answered $code" >&2; exit 1; }
  echo "  $name: ready (through PgBouncer)"
done
