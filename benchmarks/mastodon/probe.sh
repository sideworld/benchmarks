#!/usr/bin/env bash
# Readiness for a running Mastodon: web serves /api/v1/instance, streaming's health says OK,
# and Sidekiq actually processes: a status posted through the API fans out (jobs enqueued
# and completed, queues drained). production.rb has force_ssl = true, so requests carry
# X-Forwarded-Proto: https (Rack trusts it) and Host: $LOCAL_DOMAIN for the host allow-list.
#   benchmarks/mastodon/probe.sh [host] [web_port] [streaming_port]
# Needs an access token in $MD_TOKEN (see make-token.sh) for the Sidekiq part; without one
# the probe reports web+streaming only and exits 3.
set -uo pipefail
HOST=${1:-127.0.0.1}; WEB=${2:-3300}; STREAM=${3:-4300}
DOMAIN=${LOCAL_DOMAIN:-$(sed -n 's/^LOCAL_DOMAIN=//p' "${MD_DIR:-/tank/work/mastodon}/.env.production" 2>/dev/null)}
H=(-H "X-Forwarded-Proto: https" -H "Host: ${DOMAIN:-localhost}")
inst=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${H[@]}" "http://$HOST:$WEB/api/v1/instance")
stream=$(curl -s -m 10 "http://$HOST:$STREAM/api/v1/streaming/health" | tr -d '\n')
sidekiq=-; post=-
if [ -n "${MD_TOKEN:-}" ]; then
  before=$(curl -s -m 10 "${H[@]}" -H "Authorization: Bearer $MD_TOKEN" "http://$HOST:$WEB/api/v1/instance" >/dev/null; echo)
  post=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "${H[@]}" -H "Authorization: Bearer $MD_TOKEN" \
        -X POST "http://$HOST:$WEB/api/v1/statuses" -d "status=probe $(date -u +%T) $RANDOM")
  # Sidekiq: wait for the queues to drain and the processed counter to move.
  sidekiq=$(MD_PROJECT=${MD_PROJECT:-md} "$(dirname "$0")/md.sh" exec -T web bin/rails runner '
    require "sidekiq/api"
    t0 = Time.now; p0 = Sidekiq::Stats.new.processed
    loop do
      s = Sidekiq::Stats.new
      break if s.enqueued.zero? && s.processed > p0
      break if Time.now - t0 > 60
      sleep 0.5
    end
    s = Sidekiq::Stats.new
    puts(s.enqueued.zero? && s.processed > p0 ? "ok processed=#{s.processed - p0} in #{(Time.now - t0).round(1)}s" : "stuck enqueued=#{s.enqueued} processed=#{s.processed - p0}")' 2>/dev/null | tail -1)
fi
printf 'instance=%s streaming=%s post=%s sidekiq=%s\n' "$inst" "${stream:-none}" "$post" "$sidekiq"
[ "$inst" = 200 ] && [ "$stream" = OK ] || exit 1
[ -n "${MD_TOKEN:-}" ] || exit 3
[ "$post" = 200 ] && [[ "$sidekiq" == ok* ]]
