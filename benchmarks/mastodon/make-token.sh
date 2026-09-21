#!/usr/bin/env bash
# Mint an OAuth access token for a local user, the way a client app would end up with one.
# Prints the token. Idempotent per (app name, user).
#   benchmarks/mastodon/make-token.sh [username] [scopes]
set -euo pipefail
U=${1:-admin}; SCOPES=${2:-"read write follow push"}
exec "$(dirname "$0")/md.sh" exec -T web bin/rails runner "
user = User.find_by!(account: Account.find_local!('$U'))
app = Doorkeeper::Application.find_or_create_by!(name: 'benchmark-probe') { |a| a.redirect_uri = 'urn:ietf:wg:oauth:2.0:oob'; a.scopes = '$SCOPES' }
tok = Doorkeeper::AccessToken.find_by(application: app, resource_owner_id: user.id, revoked_at: nil) ||
      Doorkeeper::AccessToken.create!(application: app, resource_owner_id: user.id, scopes: '$SCOPES')
puts tok.token" 2>/dev/null | tail -1
