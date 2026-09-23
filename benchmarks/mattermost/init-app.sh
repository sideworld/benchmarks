#!/usr/bin/env bash
# HOOK_POST_UP -- bootstrap the Mattermost world once, through the project's own tooling.
#
# Everything here goes through `mmctl --local`, the admin CLI the release image already carries,
# talking to the server over its local socket. No passwords on a command line that a `ps` would
# show, and no HTTP session that expires out from under a snapshot taken today and restored in
# a month: the token minted at the end is a personal access token, which does not expire.
set -euo pipefail
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADMIN_USER=${MM_ADMIN_USER:-sideworld}
ADMIN_EMAIL=${MM_ADMIN_EMAIL:-sideworld@example.test}
ADMIN_PASS=${MM_ADMIN_PASS:-Sideworld-1234}
BUCKET=${MM_BUCKET:-mattermost-files}
mmctl() { docker exec mm-server /mattermost/bin/mmctl --local "$@"; }

echo "==> waiting for the server's local socket"
for i in $(seq 1 120); do mmctl system status >/dev/null 2>&1 && break; sleep 2; done
mmctl system status | sed 's/^/    /'

echo "==> MinIO bucket $BUCKET"
docker exec mm-minio mc alias set local http://127.0.0.1:9000 minioaccesskey miniosecretkey >/dev/null 2>&1
docker exec mm-minio mc mb --ignore-existing "local/$BUCKET" 2>&1 | sed 's/^/    /'

echo "==> admin user"
if mmctl user search "$ADMIN_USER" >/dev/null 2>&1; then
  echo "    $ADMIN_USER already exists"
else
  mmctl user create --email "$ADMIN_EMAIL" --username "$ADMIN_USER" --password "$ADMIN_PASS" --system-admin 2>&1 | sed 's/^/    /'
fi
mmctl roles system-admin "$ADMIN_USER" >/dev/null 2>&1 || true

echo "==> personal access token"
# A non-empty .token file is NOT evidence of a working token. The file outlives the database:
# after `down -v` and a fresh initdb the old token is a 26-char string that authenticates
# nothing, and every later step failed with "Invalid or expired session" while this step
# reported success. Ask the server.
BASE=${MM_BASE:-http://127.0.0.1:8065}
tok_ok() {
  [ -s "$SPEC_DIR/.token" ] || return 1
  [ "$(curl -sS -o /dev/null -m 10 -w '%{http_code}' -H "Authorization: Bearer $(cat "$SPEC_DIR/.token")" \
        "$BASE/api/v4/users/me")" = 200 ]
}
if ! tok_ok; then
  rm -f "$SPEC_DIR/.token"
  mmctl user activate "$ADMIN_USER" >/dev/null 2>&1 || true
  tok=$(mmctl token generate "$ADMIN_USER" sideworld 2>&1 | grep -oE '[a-z0-9]{26}' | tail -1)
  [ -n "$tok" ] || { echo "could not mint a token" >&2; mmctl token generate "$ADMIN_USER" sideworld; exit 1; }
  umask 077; printf '%s\n' "$tok" > "$SPEC_DIR/.token"
fi
tok_ok || { echo "the token still does not authenticate" >&2; exit 1; }
echo "    token in $SPEC_DIR/.token (gitignored), verified against /api/v4/users/me"
