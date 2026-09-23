#!/usr/bin/env bash
# Sentry probes at full volume. Every call goes through the public API with a token, so what is
# measured is what a user waits for -- Snuba -> ClickHouse for search and counts, Postgres for
# group metadata, nodestore for an event body.
#   benchmarks/sentry/probes.sh [host] [port] [token] [runs]
set -uo pipefail
HOST=${1:-127.0.0.1}; PORT=${2:-9000}; TOK=${3:?token}; RUNS=${4:-5}
API="http://$HOST:$PORT/api/0"
H=(-H "Authorization: Bearer $TOK")

t() { # label url  -> p50/p95 over $RUNS, plus the HTTP code and a size
  local label=$1 url=$2 codes=() times=()
  for i in $(seq 1 "$RUNS"); do
    read -r code tt sz <<<"$(curl -sS -o /tmp/probe.body -w '%{http_code} %{time_total} %{size_download}' "${H[@]}" "$url")"
    codes+=("$code"); times+=("$tt")
  done
  printf '%s\n' "${times[@]}" | awk -v l="$label" -v c="${codes[0]}" -v s="${sz:-0}" '
    {a[NR]=$1*1000} END {n=asort(a); printf "  %-38s p50=%7.0f ms  p95=%7.0f ms  HTTP %s  %d B\n", l, a[int((n+1)/2)], a[n-int((n-1)*0.05)], c, s}'
}

echo "== issues and search, hot project (checkout, 36.8M events / 8,000 groups)"
t "issues list, 14d"          "$API/projects/sentry/checkout/issues/?statsPeriod=14d"
t "issues list, all time"          "$API/projects/sentry/checkout/issues/?statsPeriod="
t "issues sorted by freq"     "$API/projects/sentry/checkout/issues/?statsPeriod=&sort=freq"
t "search by tag"             "$API/projects/sentry/checkout/issues/?statsPeriod=&query=customer_tier%3Aenterprise"
t "search by release"         "$API/projects/sentry/checkout/issues/?statsPeriod=&query=release%3A1.4.2"
echo "== a cold project for contrast (admin, 335k events / 400 groups)"
t "issues list, all time"          "$API/projects/sentry/admin/issues/?statsPeriod="
echo "== stats"
t "project stats 24h"         "$API/projects/sentry/checkout/stats/?stat=received&resolution=1h"
t "org stats_v2 14d"          "$API/organizations/sentry/stats_v2/?field=sum%28quantity%29&statsPeriod=14d&interval=1d&category=error"
echo "== tag cardinality"
t "tag values: customer_tier" "$API/projects/sentry/checkout/tags/customer_tier/values/"
t "tag values: server_name"   "$API/projects/sentry/checkout/tags/server_name/values/"
