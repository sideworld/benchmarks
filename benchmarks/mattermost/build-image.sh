#!/usr/bin/env bash
# HOOK_PRE_UP -- compile the server from source and bake it into the release image layout.
# See image/Dockerfile for why the image is assembled this way rather than with their Dockerfile.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${MM_SRC:-/tank/work/mattermost}/server
IMG=${MM_SERVER_IMAGE:-sideworld/mattermost-server:v11.11.0}
t0=$(date +%s.%N)
echo "==> make build-cmd-linux (their recipe)"
# `make -C` is wrong here: their Makefile builds GOBIN from $(PWD), which make takes from the
# invoking shell, not from -C. It produced
#   go: cannot write multiple packages to non-directory /tank/work/paraglobe/bin
( cd "$SRC" && make build-cmd-linux BUILD_NUMBER=${BUILD_NUMBER:-dev} SKIP_SETUP_GO_WORK=false >/dev/null )
echo "    t_go_build=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
t1=$(date +%s.%N)
echo "==> docker build $IMG"
docker build -q -t "$IMG" -f "$SPEC_DIR/image/Dockerfile" "$SRC" | sed 's/^/    /'
echo "    t_image=$(echo "$t1 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
docker run --rm --entrypoint /mattermost/bin/mattermost "$IMG" version 2>/dev/null | grep -E 'Version|Build Hash' | sed 's/^/    /'
