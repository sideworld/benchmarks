# App spec for vm/onboard-generic.sh -- everything the generic runbook needs to know about
# Mastodon, and nothing else. Sourced by bash. Mastodon-specific logic lives in the hooks.
APP=md
APP_REPO=https://github.com/mastodon/mastodon.git
APP_TAG=v4.7.2
APP_DIR=/tank/work/mastodon
PROJECT=md
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILES="$APP_DIR/docker-compose.yml $SPEC_DIR/compose/docker-compose.md.yml"
ENV_FILE=                              # Mastodon's compose reads .env.production itself
VM_ENV_FILE=$SPEC_DIR/compose/vm.env   # guest only: bind web/streaming on 0.0.0.0:3000/4000
EXTRA_COPY=.env.production             # copied next to the compose files in the guest
# service:container-path:dataset:uid -- one line per stateful service
DATASETS="db:/var/lib/postgresql/data:tank/md-pg:70 redis:/data:tank/md-redis:999 web:/mastodon/public/system:tank/md-system:991 sidekiq:/mastodon/public/system:tank/md-system:991"
HOOK_PRE_UP="$SPEC_DIR/init-env.sh"    # mint .env.production
HOOK_POST_UP="$SPEC_DIR/init-app.sh"   # db:setup + admin + token (first boot only)
PROBE="$SPEC_DIR/probe.sh"
GEN="$SPEC_DIR/scale/gen.sh"
GEN_ARGS="100000000 3500000 5000000 3000000"
SNAPSHOT_NAME=md-base
ZVOL_SIZE=128G                         # ~100 GB of Postgres logical after the 100M load
SIZE_MB=12288                          # rootfs: 2.5 GB of images; 24 GiB (the default) only lengthens the snapshot copy
# the microVM
GUEST_HTTP=3000 HEALTH_PATH=/health GUEST_PORTS="3000 4000" MEM_MIB=8192 VCPUS=4 READY_WAIT=900
APP_UNIT=app.service APP_DIR_GUEST=/opt/app
