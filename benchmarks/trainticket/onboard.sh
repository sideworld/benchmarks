#!/usr/bin/env bash
# The whole TrainTicket onboarding in order, from nothing to a snapshotted VM. Encodes the
# decisions the repeat-onboarding run had to make from memory: the clone target and tag, the
# step order, freeing the native stack before a 24 GiB guest, and the bake's ready wait.
#   benchmarks/trainticket/onboard.sh            # stops before forking; then vm.sh fork / fork.sh
# Added after the repeat-onboarding run; that run used the individual scripts below by hand.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TT=${TT_DIR:-/tank/work/trainticket}; TAG=${TT_TAG:-v0.2.0}
MICROMONKIS_DIR=${MICROMONKIS_DIR:-$(cd "$HERE/../../../micromonkis" 2>/dev/null && pwd || echo "$HERE/../../../micromonkis")}  # sibling checkout of the fork runtime
LOG=${LOG:-$MICROMONKIS_DIR/vm/out/tt-onboard.log}; mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
CUR=start
step() { CUR=$*; printf '\n\033[1;37m[%s] %s\033[0m\n' "$(date -u +%T)" "$*"; }
trap 'rc=$?; printf "\n\033[1;31mFAILED (exit %s) during: %s -- see %s\033[0m\n" "$rc" "$CUR" "$LOG"' ERR
step "clone FudanSELab/train-ticket @ $TAG -> $TT"
[ -d "$TT/.git" ] || git clone -q --branch "$TAG" --depth 1 https://github.com/FudanSELab/train-ticket.git "$TT"
step "25 empty datasets";                       "$HERE/reset-state.sh"
step "native boot to healthy";                  "$HERE/tt.sh" up -d --wait 2>&1 | grep -iE 'unhealthy|error' || true; "$HERE/probe.sh"
step "populate: 1M orders";                     "$HERE/scale/gen.sh"
step "snapshot @tt-base (quiesced)";            "$HERE/snapshot.sh" tt-base
step "data zvol from @tt-base";                 "$HERE/vm-data.sh" tt-base
step "rootfs";                                  "$HERE/vm.sh" build
step "native down: a 24 GiB guest needs the RAM"; "$HERE/tt.sh" down >/dev/null 2>&1
step "bake";                                    READY_WAIT=1500 "$HERE/vm.sh" bake
step "boot slot 1 and snapshot as ttbase";      "$HERE/vm.sh" boot 1; "$HERE/vm.sh" snapshot 1 ttbase
echo; echo "next: $HERE/vm-fork-measure.sh ttbase <k> [--probe]   $HERE/pr-swap.sh <k>   $HERE/fork.sh <n> (Compose fork; needs tt.sh up)"
