#!/usr/bin/env bash
# Run the generator against the live tt project and report throughput and on-disk cost.
#   benchmarks/trainticket/scale/gen.sh [N_ORDERS] [N_USERS] [N_TRIPS]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
N_ORDERS=${1:-1000000}; N_USERS=${2:-10000}; N_TRIPS=${3:-1000}
NET=${TT_NET:-tt_my-network}
echo "== generating: $N_ORDERS orders, $N_USERS users, $N_TRIPS trips (seed 42)"
t0=$(date +%s.%N)
docker run --rm --network "$NET" -v "$HERE:/gen:ro" mongo:4.4 \
  mongo --quiet --host ts-order-mongo ts --eval "var N_ORDERS=$N_ORDERS, N_USERS=$N_USERS, N_TRIPS=$N_TRIPS, SEED=42;" /gen/gen.js
t1=$(date +%s.%N)
echo "== wall: $(echo "$t0 $t1" | awk '{printf "%.1f", $2-$1}') s"
echo "== coherence check (300 orders + 300 payments sampled)"
docker run --rm --network "$NET" -v "$HERE:/gen:ro" mongo:4.4 mongo --quiet --host ts-order-mongo ts /gen/check.js
sync; sleep 2
echo "== on disk (zfs, after sync)"
zfs list -o name,used,logicalused,compressratio -t filesystem tank/tt-order-mongo tank/tt-order-other-mongo tank/tt-payment-mongo tank/tt-inside-payment-mongo tank/tt-auth-mongo tank/tt-user-mongo tank/tt-contacts-mongo tank/tt-travel-mongo tank/tt-travel2-mongo
zfs list -Ho used,logicalused -t filesystem -r tank | awk '/tt-/' >/dev/null
printf '== all 25 tt datasets: used %s, logical %s\n' "$(zfs list -Hp -o used -t filesystem $(zfs list -H -o name -t filesystem | grep '^tank/tt-') | awk '{s+=$1} END{printf "%.0f MiB", s/1048576}')" "$(zfs list -Hp -o logicalused -t filesystem $(zfs list -H -o name -t filesystem | grep '^tank/tt-') | awk '{s+=$1} END{printf "%.0f MiB", s/1048576}')"
