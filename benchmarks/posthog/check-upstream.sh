#!/usr/bin/env bash
# compose/docker-compose.hobby.sideworld.yml is THEIR hobby file with one mechanical edit. This
# proves it, so the derived file cannot drift from the pinned original without anyone noticing.
#   benchmarks/posthog/check-upstream.sh   -> exit 0 when the derived file == sed of the original
set -uo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${PH_SRC:-/tank/work/posthog}
want=$(sed 's#\./posthog/#./#g' "$SRC/docker-compose.hobby.yml")
have=$(sed '1,/^# Regenerate:/d' "$SPEC_DIR/compose/docker-compose.hobby.sideworld.yml")   # drop our header (ends at the Regenerate line)
if diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") >/dev/null; then
  echo "  derived hobby file == sed 's#./posthog/#./#g' of theirs at $(git -C "$SRC" describe --tags --exact-match 2>/dev/null || git -C "$SRC" rev-parse --short HEAD)"
else
  echo "  DRIFT between the derived hobby file and the pinned original:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") | head -20; exit 1
fi
up=$(grep -oE 'minio/minio:[A-Za-z0-9.T-]+' "$SRC/docker-compose.hobby.yml" | head -1); ours=$(grep -oE 'quay.io/minio/minio:[A-Za-z0-9.T-]+' "$SPEC_DIR/compose/docker-compose.ph.yml" | head -1)
[ "${up##*:}" = "${ours##*:}" ] && echo "  minio tag ${up##*:} matches (registry redirected to quay.io)" || { echo "  minio DRIFT: upstream ${up##*:}, ours ${ours##*:}"; exit 1; }
