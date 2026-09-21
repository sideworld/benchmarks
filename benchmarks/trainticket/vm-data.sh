#!/usr/bin/env bash
# Build tank/tt-vm-data (the zvol Firecracker attaches as /dev/vdb) from the tank/tt-* datasets'
# @<snap> snapshots, laid out as vm-data.map says, and snapshot it @<snap>.
#   benchmarks/trainticket/vm-data.sh [snap]     (default tt-base; the name vm.sh expects)
# Added after the repeat-onboarding run, in which this was the one step done by hand.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNAP=${1:-tt-base}; ZVOL=tank/tt-vm-data; SIZE=${SIZE:-24G}
zfs list -H -o name "$ZVOL" >/dev/null 2>&1 && { echo "$ZVOL exists; zfs destroy -r $ZVOL first" >&2; exit 1; }
zfs create -V "$SIZE" -o volblocksize=16K -o compression=lz4 "$ZVOL"
for _ in $(seq 1 50); do [ -e "/dev/zvol/$ZVOL" ] && break; sleep 0.1; done
mkfs.ext4 -q -F -m 0 -L tt-data "/dev/zvol/$ZVOL"
M=$(mktemp -d -t ttvm.XXXXXX); mount "/dev/zvol/$ZVOL" "$M"
trap 'umount "$M" 2>/dev/null; rmdir "$M" 2>/dev/null' EXIT
n=0
while read -r svc path sub; do
  case "$svc" in ''|'#'*) continue ;; esac
  src="/tank/tt-$sub/.zfs/snapshot/$SNAP"
  [ -d "$src" ] || { echo "no snapshot $src (run snapshot.sh $SNAP first)" >&2; exit 1; }
  mkdir -p "$M/$sub"; cp -a "$src/." "$M/$sub/"; n=$((n + 1))
done < "$HERE/vm-data.map"
echo "copied $n state dirs, $(du -sh "$M" | cut -f1)"
umount "$M"; rmdir "$M"; trap - EXIT
zfs snapshot "$ZVOL@$SNAP"
echo "$ZVOL@$SNAP ready"
