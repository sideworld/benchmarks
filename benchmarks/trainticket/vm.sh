#!/usr/bin/env bash
# Run the vm/ tooling against TrainTicket instead of the specimen: sets the generic knobs
# and execs the script. Every name stays inside what this exercise may create:
# vm/out/tt-*, tank/tt-*, /run/fc-tt*.
#   benchmarks/trainticket/vm.sh build|bake|boot|stop|snapshot|fork|unfork|net-ns ARGS...
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
cmd=${1:?cmd}; shift
export APP=tt
export APP_DIR=/tank/work/trainticket
export COMPOSE_FILES="/tank/work/trainticket/docker-compose.yml $HERE/compose/docker-compose.tt.yml"
export ENV_FILE=$HERE/compose/tt.env
export DATA_MAP=$HERE/vm-data.map
export SIZE_MB=${SIZE_MB:-24576}
export ROOTFS_IMG=$REPO/vm/out/tt-rootfs.ext4
export SNAPSHOT=tank/tt-vm-data@tt-base
export CLONE_PREFIX=tank/tt-vmfork
export SNAPFORK_PREFIX=tank/tt-snapfork
export FC_PREFIX=ttf
export GUEST_HTTP=8080 HEALTH_PATH=/ READY_FILE=/run/app-ready
export GUEST_PORTS="8080 12340 12346 12347"          # ui, auth, travel, contacts -> 3<kk>80/90/70/60
export APP_UNIT=app.service APP_DIR_GUEST=/opt/app
export MEM_MIB=${MEM_MIB:-24576} VCPUS=${VCPUS:-8}
case "$cmd" in
  build)  exec "$REPO/vm/build-rootfs-generic.sh" "$@" ;;
  bake)   FC_ID=tt${1:-9} exec "$REPO/vm/bake-rootfs.sh" "$@" ;;
  boot)   FC_ID=tt$1 exec "$REPO/vm/boot.sh" "$@" ;;
  stop)   FC_ID=tt$1 exec "$REPO/vm/stop.sh" "$@" ;;
  snapshot) FC_ID=tt$1 exec "$REPO/vm/snapshot.sh" "$@" ;;
  fork)   exec "$REPO/vm/fork.sh" "$@" ;;
  unfork) exec "$REPO/vm/unfork.sh" "$@" ;;
  net-ns) exec "$REPO/vm/net-ns.sh" "$@" ;;
  *) echo "unknown: $cmd" >&2; exit 2 ;;
esac
