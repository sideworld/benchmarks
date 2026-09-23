#!/usr/bin/env bash
# compose/docker-compose.mm.yml inlines Mattermost's own dependency definitions instead of
# `extends`-ing them, because `extends` cannot survive the trip into the guest. A copy can drift.
# This diffs what we pinned against what their docker-compose.common.yml says at the pinned tag,
# so the drift is loud rather than silent.
#
#   benchmarks/mattermost/check-upstream.sh    -> exit 0 if every pin still matches
set -uo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UP=${MM_SRC:-/tank/work/mattermost}/server/build/docker-compose.common.yml
OURS=$SPEC_DIR/compose/docker-compose.mm.yml
[ -f "$UP" ] || { echo "upstream file not found: $UP" >&2; exit 2; }
rc=0
up_image() { python3 -c "
import sys,re
t=open(sys.argv[1]).read()
m=re.search(r'^  %s:\n(?:.*\n)*?    image: \"?([^\"\n]+)\"?' % sys.argv[2], t, re.M)
print(m.group(1) if m else '')" "$UP" "$1"; }
our_image() { python3 -c "
import sys,re
t=open(sys.argv[1]).read()
m=re.search(r'^  %s:\n(?:.*\n)*?    image: \"?([^\"\n]+)\"?' % sys.argv[2], t, re.M)
print(m.group(1) if m else '')" "$OURS" "$1"; }
for svc in postgres inbucket; do
  u=$(up_image "$svc"); o=$(our_image "$svc")
  if [ "$u" = "$o" ]; then printf '  %-10s %s\n' "$svc" "$o"
  else printf '  %-10s DRIFT: upstream %s, ours %s\n' "$svc" "${u:-<none>}" "${o:-<none>}"; rc=1; fi
done
# minio is deliberately not identical: same tag, different registry, because docker.io/minio/minio
# was withdrawn. Compare the tag only.
u=$(up_image minio); o=$(our_image minio)
if [ "${u##*:}" = "${o##*:}" ]; then printf '  %-10s %s  (registry redirected from %s)\n' minio "$o" "${u%%:*}"
else printf '  %-10s DRIFT: upstream tag %s, ours %s\n' minio "${u##*:}" "${o##*:}"; rc=1; fi
[ $rc = 0 ] && echo "  all pins match upstream at $(cd "${MM_SRC:-/tank/work/mattermost}" && git describe --tags --exact-match 2>/dev/null || echo '?')"
exit $rc
