#!/usr/bin/env bash
# PROBE -- every service answers, and each reaches Postgres through PgBouncer (GET /ready runs
# SELECT 1 through the service's own pool); then the same through the gateway, by the routes the
# Migration Check's probes take (PAR-83). Runs before the generator, so it asks for no data.
#   probe.sh [host]       ports from compose/cascade.env (services 18480-18483, gateway 18484)
set -euo pipefail
H=${1:-127.0.0.1}
ready() {  # name url
  local code=
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$2" || true)
    [ "$code" = 200 ] && break; sleep 1
  done
  [ "$code" = 200 ] || { echo "$1: $2 answered $code" >&2; exit 1; }
}
for p in 18480:api 18481:billing 18482:dashboard 18483:ingest; do
  port=${p%%:*}; name=${p#*:}
  ready "$name" "http://$H:$port/ready"
  ready "gateway /$name" "http://$H:18484/$name/ready"
  echo "  $name: ready (through PgBouncer), and through the gateway at /$name"
done
