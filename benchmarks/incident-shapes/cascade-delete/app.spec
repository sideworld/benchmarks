# App spec for vm/onboard-generic.sh -- PAR-76's cascade world: Postgres 16 behind PgBouncer
# (transaction pooling), four unrelated services and a retrying executor, 20,000 accounts with an
# ON DELETE CASCADE graph of 24 tables under each, skewed so a few are huge (scale/gen.sql).
#
# APP_REPO is this repository: the world's "source" is this directory, pinned at a tag, and a
# rehearsal is a pull request against that checkout (rehearse.sh), as for any world.
APP=cascade
APP_REPO=https://github.com/sideworld/benchmarks.git
APP_TAG=cascade-delete-v1
APP_DIR=/tank/work/cascade
PROJECT=cascade
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

COMPOSE_FILES="$SPEC_DIR/compose/docker-compose.cascade.yml"
ENV_FILE=$SPEC_DIR/compose/cascade.env
VM_ENV_FILE=$SPEC_DIR/compose/vm.env      # guest only: the services on 0.0.0.0:8080-8083

# The one store. PgBouncer keeps nothing; the services and the executor are stateless.
DATASETS="db:/var/lib/postgresql/data:tank/cascade-pg:999"

HOOK_PRE_UP="$SPEC_DIR/build-image.sh"    # the app image (app/Dockerfile)
HOOK_POST_UP="$SPEC_DIR/init-app.sh"      # the schema, once
PROBE="$SPEC_DIR/probe.sh"                # every service reaches Postgres through PgBouncer
GEN="$SPEC_DIR/scale/gen.sh"
GEN_ARGS="2 20000"                        # scale 2: ~52M rows, account 1 ~12.7M of them (~6 GB)

SNAPSHOT_NAME=cascade-base
ZVOL_SIZE=64G
SIZE_MB=6144                              # rootfs: postgres, pgbouncer, python images, well under 1 GB
# the microVM
GUEST_HTTP=8080 HEALTH_PATH=/healthz GUEST_PORTS="8080 8081 8082 8083" MEM_MIB=8192 VCPUS=4 READY_WAIT=900
APP_UNIT=app.service APP_DIR_GUEST=/opt/app
