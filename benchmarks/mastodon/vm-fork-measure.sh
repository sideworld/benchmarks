#!/usr/bin/env bash
# Restore snapshot <name> as fork <k> of the Mastodon VM and measure it: t_load /
# t_restore_to_api_response (from vm/fork.sh), PSS+RSS at t+10/60/120 s with no requests
# in between, then one status posted through this fork's API (isolation: it must exist
# only in this fork's Postgres), streaming health, Sidekiq having processed the post's
# fan-out, storage delta on the zvol clone, host headroom. Appends to vm/out/md-forks.csv.
#   benchmarks/mastodon/vm-fork-measure.sh <name> <k> [--probe]   (--probe: heavy home timeline too)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../.." && pwd); OUT=$REPO/vm/out
NAME=${1:?name}; K=${2:?k}; PROBE=${3:-}
KK=$(printf '%02d' "$K"); P_WEB=3${KK}80; P_STREAM=3${KK}90; P_SSH=3${KK}22
H=(-H "X-Forwarded-Proto: https" -H "Host: mastodon.test")
TOK=$(cat "$HERE/.token"); TOK_HEAVY=$(cat "$HERE/.token-heavy" 2>/dev/null || true)
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
CSV=$OUT/md-forks.csv
[ -f "$CSV" ] || echo "fork,t_load_s,t_restore_to_api_response_s,pss_mb_10,rss_mb_10,pss_mb_60,rss_mb_60,pss_mb_120,rss_mb_120,pss_anon_120,pss_file_120,storage_delta_mib,isolation_http,streaming,sidekiq,home_s,host_avail_gib_after" > "$CSV"

log "fork $K of $NAME"
"$REPO/vm/app.sh" "$HERE/app.spec" fork "$NAME" "$K" > "$OUT/md-fork-$K.log" 2>&1 || { tail -20 "$OUT/md-fork-$K.log"; exit 1; }
T0=$(date +%s)
val() { sed -n "s/^$1=//p" "$OUT/md-fork-$K.log" | tail -1; }
T_LOAD=$(val t_load); T_READY=$(val t_restore_to_api_response)
grep -E 'post-restore' "$OUT/md-fork-$K.log" | sed 's/^/    /' | head -4
log "t_load=${T_LOAD}s  t_restore_to_api_response=${T_READY}s (first 200 on :$P_WEB/health)"

PID=$(cat "$OUT/fc-mdf$K.pid")
roll() { awk '/^Rss:/{r=$2} /^Pss:/{p=$2} /^Pss_Anon:/{a=$2} /^Pss_File:/{f=$2} END{printf "%d %d %d %d\n", p/1024, r/1024, a/1024, f/1024}' "/proc/$PID/smaps_rollup"; }
declare -A S
for off in 10 60 120; do
  while [ $(( $(date +%s) - T0 )) -lt "$off" ]; do sleep 1; done
  S[$off]=$(roll); read -r p r a f <<<"${S[$off]}"
  log "t+${off}s  pss=${p} MiB rss=${r} MiB (anon ${a} / file ${f})"
done

SSH="ssh -p $P_SSH -i $OUT/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1"
rcli() { $SSH "docker exec app-redis-1 redis-cli --raw $*" 2>/dev/null; }
STREAM=$(curl -s -m 10 "http://127.0.0.1:$P_STREAM/api/v1/streaming/health" | tr -d '\n')
P0=$(rcli get stat:processed); P0=${P0:-0}
ISO=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "${H[@]}" -H "Authorization: Bearer $TOK" \
      -X POST "http://127.0.0.1:$P_WEB/api/v1/statuses" -d "status=vmfork-$K-probe")
SIDEKIQ=stuck
for _ in $(seq 1 60); do
  q=$(rcli 'eval "local n=0 for _,k in ipairs(redis.call(\"keys\",\"queue:*\")) do n=n+redis.call(\"llen\",k) end return n" 0')
  p1=$(rcli get stat:processed); p1=${p1:-0}
  [ "${q:-1}" = 0 ] && [ "$p1" -gt "$P0" ] && { SIDEKIQ="ok+$((p1 - P0))"; break; }
  sleep 1
done
# by the admin's (account_id, id) index -- a bare `text LIKE` is a 25 GB seq scan that pulls the whole
# statuses heap through the guest page cache and turns an idle 1 GB fork into a 6.8 GB one (series 1)
seen=$($SSH "docker exec app-db-1 psql -U postgres -d mastodon_production -Atc \"select coalesce(string_agg(text, ','), 'none') from statuses where account_id = (select id from accounts where username='admin' and domain is null) and text like 'vmfork-%-probe'\"" 2>/dev/null || echo "?")
log "isolation: POST status -> HTTP $ISO; probe statuses in fork $K: $seen; streaming=$STREAM sidekiq=$SIDEKIQ"

HOME_S=-
if [ -n "$PROBE" ] && [ -n "$TOK_HEAVY" ]; then
  # the feed is whatever the snapshot holds; if it is missing, ask for the rebuild the way a sign-in does
  $SSH "docker exec app-web-1 bin/rails runner \"Account.find_local!('heavyfollower').user.send(:regenerate_feed!) unless \$redis.exists?('feed:home:' + Account.find_local!('heavyfollower').id.to_s)\"" >/dev/null 2>&1 || true
  t=$(date +%s.%N)
  for _ in $(seq 1 300); do
    code=$(curl -s -m 30 -o "$OUT/md-fork-$K-home.json" -w '%{http_code}' "${H[@]}" -H "Authorization: Bearer $TOK_HEAVY" "http://127.0.0.1:$P_WEB/api/v1/timelines/home?limit=20")
    [ "$code" = 200 ] && [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$OUT/md-fork-$K-home.json")" -gt 0 ] && break
    sleep 1
  done
  HOME_S=$(echo "$t $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
  log "home timeline (heavyfollower) in fork $K: HTTP $code after ${HOME_S}s"
fi

STOR=$(( $(zfs get -Hp -o value used "tank/md-snapfork$K") / 1048576 ))
AVAIL=$(free -g | awk '/^Mem:/{print $7}')
read -r p10 r10 _ _ <<<"${S[10]}"; read -r p60 r60 _ _ <<<"${S[60]}"; read -r p120 r120 a120 f120 <<<"${S[120]}"
echo "$K,$T_LOAD,$T_READY,$p10,$r10,$p60,$r60,$p120,$r120,$a120,$f120,$STOR,$ISO,$STREAM,$SIDEKIQ,$HOME_S,$AVAIL" >> "$CSV"
log "fork $K: storage_delta=${STOR} MiB  host available after: ${AVAIL} GiB"
