#!/usr/bin/env bash
# First-boot application init for Mastodon: schema + seeds, the admin, an API token.
# Idempotent: skips when the admin exists. Called by onboard-generic.sh after the first
# `up --wait` (db and redis are healthy; web may be crash-looping until the schema exists).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if "$HERE/md.sh" exec -T db psql -U postgres -d mastodon_production -Atc "select 1 from users u join accounts a on a.id=u.account_id where a.username='admin'" 2>/dev/null | grep -q 1; then
  echo "init-app: admin exists"; exit 0
fi
"$HERE/md.sh" run --rm -T web bin/rails db:setup 2>&1 | grep -vE 'level=warning|^Container|^\s*$' | tail -1
"$HERE/md.sh" run --rm -T web bin/tootctl accounts create admin --email admin@mastodon.test --confirmed --role Owner --approve 2>&1 | grep -vE 'level=warning|^Container' | tail -1
"$HERE/md.sh" up -d --wait >/dev/null 2>&1
"$HERE/make-token.sh" admin > "$HERE/.token"; chmod 600 "$HERE/.token"
echo "init-app: admin + token ($(wc -c < "$HERE/.token") chars) in $HERE/.token"
