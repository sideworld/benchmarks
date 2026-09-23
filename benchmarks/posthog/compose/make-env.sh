#!/usr/bin/env bash
# Generate compose/hobby.env and compose/vm.env exactly the way PostHog's bin/deploy-hobby writes
# its .env -- fresh random secrets, our domain, the pinned image tag. The generated files are
# gitignored: they hold this box's throwaway secrets and nothing else. Run once after cloning.
#   benchmarks/posthog/compose/make-env.sh [app-tag-sha]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAG=${1:-$(git -C "${PH_SRC:-/tank/work/posthog}" rev-parse HEAD)}
[ -f "$HERE/hobby.env" ] && { echo "$HERE/hobby.env exists; delete it to regenerate (the running world's secrets live in it)" >&2; exit 1; }
POSTHOG_SECRET=$(head -c 28 /dev/urandom | sha224sum -b | head -c 56)
cat > "$HERE/hobby.env" <<EOF
POSTHOG_SECRET=$POSTHOG_SECRET
ENCRYPTION_SALT_KEYS=$(openssl rand -hex 16)
BROWSERLESS_SECRET=$(openssl rand -hex 32)
DOMAIN=localhost
TLS_BLOCK=
REGISTRY_URL=posthog/posthog
CADDY_TLS_BLOCK=
CADDY_HOST="localhost, http://, https://"
POSTHOG_APP_TAG=$TAG
EOF
{ printf '%s\n' '# Guest-only: identical to hobby.env except the front door binds every interface, because the host' '# forwards a port into the VM. Same secrets on purpose -- a fork is the baseline, byte for byte.' 'PH_BIND=0.0.0.0' 'PH_PORT=8100' 'PH_SITE_URL=http://localhost:8100'; grep -E '^(POSTHOG_SECRET|ENCRYPTION_SALT_KEYS|BROWSERLESS_SECRET|DOMAIN|TLS_BLOCK|REGISTRY_URL|CADDY_TLS_BLOCK|CADDY_HOST|POSTHOG_APP_TAG)=' "$HERE/hobby.env"; } > "$HERE/vm.env"
chmod 600 "$HERE/hobby.env" "$HERE/vm.env"; echo "wrote $HERE/hobby.env and vm.env for tag $TAG"
