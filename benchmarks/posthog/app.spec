# App spec for vm/onboard-generic.sh -- PostHog at posthog-live-20260907-105219 (e04da21b).
# The cold passes (posthog.md §3) pointed this at their docker-compose.hobby.yml with nothing else and
# stopped three times: no installer .env, a withdrawn MinIO registry, and the installer's
# parent-directory layout. This is the spec that came out of that.
APP=ph
APP_REPO=https://github.com/PostHog/posthog.git
APP_TAG=posthog-live-20260907-105219
APP_DIR=/tank/work/posthog
PROJECT=ph
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Their hobby file with its `./posthog/` layout prefix folded (compose/docker-compose.hobby.paraglobe.yml),
# plus the Paraglobe override. Both `extends:` docker-compose.base.yml in the checkout, so that
# file must travel into the guest too: EXTRA_COPY.
COMPOSE_FILES="$SPEC_DIR/compose/docker-compose.hobby.paraglobe.yml $SPEC_DIR/compose/docker-compose.ph.yml"
# hobby.env / vm.env are what bin/deploy-hobby writes, with this box's throwaway secrets; both are
# gitignored. compose/make-env.sh regenerates them after a clone (hobby.env.example shows the shape).
ENV_FILE=$SPEC_DIR/compose/hobby.env
VM_ENV_FILE=$SPEC_DIR/compose/vm.env        # guest only: bind the front door on 0.0.0.0
# base file (extends target), .env.services (env_file), and the two the installer generates
EXTRA_COPY="docker-compose.base.yml .env.services compose share"
# service:container-path:dataset:uid
# service:container-path:dataset:uid -- every store whose bytes must survive a snapshot. Valkey is
# cache (allkeys-lru, no volume); elasticsearch is started by hobby but Temporal runs with
# ENABLE_ES=false, so it holds nothing; caddy holds only TLS state and we serve plain http.
# Temporal's own store is INSIDE Postgres (DB=postgres12, seeds=db) -- covered by ph-pg.
DATASETS="db:/var/lib/postgresql/data:tank/ph-pg:70 clickhouse:/var/lib/clickhouse:tank/ph-ch:101 zookeeper:/data:tank/ph-zk:1000 zookeeper:/datalog:tank/ph-zklog:1000 kafka:/var/lib/redpanda/data:tank/ph-kafka:101 redis7:/data:tank/ph-redis:999 objectstorage:/data:tank/ph-minio:0 seaweedfs:/data:tank/ph-seaweedfs:0"
SNAPSHOT_NAME=ph-base
ZVOL_SIZE=128G
SIZE_MB=40960
# the front door inside the guest is Caddy on PH_PORT (vm.env), not Django on 8000
GUEST_HTTP=8100 HEALTH_PATH=/_health GUEST_PORTS="8100" MEM_MIB=16384 VCPUS=8 READY_WAIT=1800
APP_UNIT=app.service APP_DIR_GUEST=/opt/app
