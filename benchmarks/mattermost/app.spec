# App spec for vm/onboard-generic.sh -- Mattermost v11.11.0 (server + webapp, Postgres, MinIO,
# Inbucket). Sourced by bash; everything Mattermost-specific lives in the hooks beside this file.
#
# See mattermost.md §2 for which of these fields a drafter could have inferred from the
# repository and which needed a human to decide.
APP=mm
APP_REPO=https://github.com/sideworld/mattermost.git
APP_TAG=v11.11.0
APP_DIR=/tank/work/mattermost
PROJECT=mm
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# One self-contained file: their compose has no Mattermost server in it at all, and its Postgres
# is tmpfs. See compose/docker-compose.mm.yml for why there is no `extends:` and no config bind
# mount -- both break inside the guest. PROJECT_DIR is therefore not needed here; the knob exists
# in vm/onboard-generic.sh because the cold run against their own file could not start without it.
COMPOSE_FILES="$SPEC_DIR/compose/docker-compose.mm.yml"
ENV_FILE=$SPEC_DIR/compose/mm.env
VM_ENV_FILE=$SPEC_DIR/compose/vm.env      # guest only: bind the server on 0.0.0.0:8065

# service:container-path:dataset:uid -- the stores whose bytes must survive a snapshot.
# Inbucket is deliberately absent: it is an SMTP sink with nothing to keep. So is the server's
# own /mattermost/data, because files live in MinIO and the configuration lives in Postgres.
DATASETS="postgres:/var/lib/postgresql/data:tank/mm-pg:999 minio:/data:tank/mm-minio:0"

HOOK_PRE_UP="$SPEC_DIR/build-image.sh"    # compile the server from source, bake the image
HOOK_POST_UP="$SPEC_DIR/init-app.sh"      # bucket, admin, token -- via mmctl --local
PROBE="$SPEC_DIR/probe.sh"                # a round trip, not a health endpoint
GEN="$SPEC_DIR/scale/gen.sh"
GEN_ARGS="20000000 3000 2000"             # posts, channels, users

SNAPSHOT_NAME=mm-base
ZVOL_SIZE=64G
SIZE_MB=8192                              # rootfs: ~1.6 GB of images; measured in the ledger
# the microVM
GUEST_HTTP=8065 HEALTH_PATH=/api/v4/system/ping GUEST_PORTS="8065" MEM_MIB=4096 VCPUS=4 READY_WAIT=900
APP_UNIT=app.service APP_DIR_GUEST=/opt/app
