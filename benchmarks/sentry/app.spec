# App spec for vm/onboard-generic.sh -- Sentry self-hosted 26.9.0.
# First pass: deliberately minimal, to find out where the generic runbook stops on a system whose
# Compose project is not runnable from a clean clone. The hooks are empty on purpose here; the
# ledger records what the cold attempt reported.
APP=se
APP_REPO=https://github.com/sideworld/self-hosted.git
APP_TAG=26.9.0
APP_DIR=/tank/work/sentry-self-hosted
PROJECT=sentry-self-hosted
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILES="$APP_DIR/docker-compose.yml"
ENV_FILE=$APP_DIR/.env
# service:container-path:dataset:uid -- the stores whose bytes must survive a snapshot.
# Memcached is deliberately absent: it holds only cache and has no volume at all.
DATASETS="postgres:/var/lib/postgresql/data:tank/se-pg:70 clickhouse:/var/lib/clickhouse:tank/se-ch:101 kafka:/var/lib/kafka/data:tank/se-kafka:1000 redis:/data:tank/se-redis:999 seaweedfs:/data:tank/se-seaweedfs:0"
SNAPSHOT_NAME=se-base
ZVOL_SIZE=64G
SIZE_MB=40960                          # rootfs: Sentry's images are large; measured in the ledger
# the microVM
GUEST_HTTP=9000 HEALTH_PATH=/_health/ GUEST_PORTS="9000" MEM_MIB=16384 VCPUS=8 READY_WAIT=1800
APP_UNIT=app.service APP_DIR_GUEST=/opt/app
