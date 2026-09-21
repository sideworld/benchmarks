#!/usr/bin/env bash
# Kick the home-feed rebuild for a local user, the way a web sign-in does (User#regenerate_feed!:
# sets account:<id>:regeneration, enqueues RegenerationWorker; private, hence send). An API read of a missing feed
# does NOT trigger it -- it serves 200 [] -- so the probes call this first and then time the
# 206 -> 200 transition.   benchmarks/mastodon/regen-feed.sh [username] [compose-project]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); U=${1:-heavyfollower}
MD_PROJECT=${2:-${MD_PROJECT:-md}} "$HERE/md.sh" exec -T web bin/rails runner "u = Account.find_local!('$U').user; u.send(:regenerate_feed!); puts 'regeneration enqueued for $U'" 2>/dev/null | tail -1
