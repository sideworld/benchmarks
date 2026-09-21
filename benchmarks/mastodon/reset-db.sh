#!/usr/bin/env bash
# Put the database back to its post-init state: schema from schema.rb (every index included),
# seeds, the admin, and a fresh token. The Redis and media datasets are emptied too.
#   benchmarks/mastodon/reset-db.sh
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$HERE/md.sh" stop web sidekiq streaming >/dev/null 2>&1 || true
"$HERE/md.sh" run --rm -T -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1 web bin/rails db:drop db:create db:schema:load db:seed 2>&1 | grep -vE 'level=warning|^Container|^\s*$' | tail -2
"$HERE/md.sh" exec -T redis redis-cli FLUSHALL >/dev/null
find /tank/md-system -mindepth 1 -delete 2>/dev/null || true
"$HERE/md.sh" up -d --wait >/dev/null 2>&1
"$HERE/md.sh" run --rm -T web bin/tootctl accounts create admin --email admin@mastodon.test --confirmed --role Owner --approve 2>&1 | grep -vE 'level=warning|^Container' | tail -1
"$HERE/make-token.sh" admin
