#!/usr/bin/env bash
# Put every tank/tt-* dataset back to empty, mounted where the Compose override expects it.
#   benchmarks/trainticket/reset-state.sh        (the tt project must be down)
# One dataset per stateful service, named tank/tt-<service minus "ts-">, mounted at
# /tank/tt-<...>. The mountpoint must be spelled out: a dataset created without one lands
# at /<name>, Docker then binds a plain directory on the parent dataset, and the data is
# invisible to `zfs snapshot`.
set -euo pipefail
P=${TT_PROJECT:-tt}
if docker ps --format '{{.Names}}' | grep -q "^$P-"; then echo "project $P is up; run tt.sh down first" >&2; exit 1; fi
TT=${TT_DIR:-/tank/work/trainticket}
for svc in $(python3 -c "
import yaml; d=yaml.safe_load(open('$TT/docker-compose.yml'))['services']
print(' '.join(n for n in d if n.endswith('-mongo') or n.endswith('-mysql')))"); do
  ds=tank/tt-${svc#ts-}; mp=/tank/tt-${svc#ts-}
  zfs list -H -o name "$ds" >/dev/null 2>&1 && zfs destroy "$ds"
  zfs create -o compression=lz4 -o mountpoint="$mp" "$ds"
  [ "$(zfs get -H -o value mounted "$ds")" = yes ] || { echo "$ds did not mount at $mp" >&2; exit 1; }
done
echo "$(zfs list -H -o name -t filesystem | grep -c '^tank/tt-') datasets empty and mounted under /tank/tt-*"
