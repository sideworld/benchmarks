#!/usr/bin/env bash
# Restore snapshot <name> as fork <k> of the TrainTicket VM and measure it:
# t_load / t_restore_to_api_response (from vm/fork.sh), PSS+RSS at t+10/60/120 s,
# storage delta on the zvol clone, one contact written through this fork's API, and the
# host's memory headroom afterwards. Appends a row to vm/out/tt-forks.csv.
#   benchmarks/trainticket/vm-fork-measure.sh <name> <k> [--probe]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../.." && pwd); OUT=$REPO/vm/out
NAME=${1:?name}; K=${2:?k}; PROBE=${3:-}
KK=$(printf '%02d' "$K"); P_UI=3${KK}80; P_AUTH=3${KK}90; P_TRAVEL=3${KK}70; P_CONTACTS=3${KK}60; P_SSH=3${KK}22
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
CSV=$OUT/tt-forks.csv
[ -f "$CSV" ] || echo "fork,t_load_s,t_restore_to_api_response_s,pss_mb_10,rss_mb_10,pss_mb_60,rss_mb_60,pss_mb_120,rss_mb_120,pss_anon_120,pss_file_120,storage_delta_mib,isolation_http,host_avail_gib_after" > "$CSV"

log "fork $K of $NAME"
"$HERE/vm.sh" fork "$NAME" "$K" > "$OUT/tt-fork-$K.log" 2>&1 || { tail -20 "$OUT/tt-fork-$K.log"; exit 1; }
T0=$(date +%s)
val() { sed -n "s/^$1=//p" "$OUT/tt-fork-$K.log" | tail -1; }
T_LOAD=$(val t_load); T_READY=$(val t_restore_to_api_response)
grep -E 'post-restore' "$OUT/tt-fork-$K.log" | sed 's/^/    /' | head -4
log "t_load=${T_LOAD}s  t_restore_to_api_response=${T_READY}s (first 200 on :$P_UI)"

PID=$(cat "$OUT/fc-ttf$K.pid")
roll() { awk '/^Rss:/{r=$2} /^Pss:/{p=$2} /^Pss_Anon:/{a=$2} /^Pss_File:/{f=$2} END{printf "%d %d %d %d\n", p/1024, r/1024, a/1024, f/1024}' "/proc/$PID/smaps_rollup"; }
declare -A S
for off in 10 60 120; do
  while [ $(( $(date +%s) - T0 )) -lt "$off" ]; do sleep 1; done
  S[$off]=$(roll); read -r p r a f <<<"${S[$off]}"
  log "t+${off}s  pss=${p} MiB rss=${r} MiB (anon ${a} / file ${f})"
done

# isolation write through this fork's own API, as a generated user
TOK=$(curl -s -m 10 -X POST "http://127.0.0.1:$P_AUTH/api/v1/users/login" -H 'Content-Type: application/json' \
      -d '{"username":"user_0000042","password":"111111","verificationCode":""}' \
      | python3 -c 'import sys,json; d=json.load(sys.stdin)["data"]; print(d["token"], d["userId"])' 2>/dev/null || echo "- -")
read -r tok uid <<<"$TOK"
if [ "$tok" != "-" ]; then
  ISO=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$P_CONTACTS/api/v1/contactservice/contacts" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" \
    -d "{\"accountId\":\"$uid\",\"name\":\"vmfork-$K-probe\",\"documentType\":1,\"documentNumber\":\"V$K\",\"phoneNumber\":\"000$K\"}")
else ISO=nologin; fi
SSH="ssh -p $P_SSH -i $OUT/id_specimen_vm -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
seen=$($SSH root@127.0.0.1 'docker exec app-ts-contacts-mongo-1 mongo --quiet ts --eval "db.contacts.find({name:/^vmfork-.*-probe$/},{_id:0,name:1}).toArray().map(function(x){return x.name}).join(\",\")"' 2>/dev/null || echo "?")
log "isolation: POST contact -> HTTP $ISO; probe contacts visible in fork $K: ${seen:-none}"
[ -n "$PROBE" ] && { log "full probe inside fork $K (search at 1M)"; $SSH root@127.0.0.1 'bash -s 127.0.0.1 12340 12346 8080' < "$HERE/probe.sh" || log "probe FAILED"; }

STOR=$(( $(zfs get -Hp -o value used "tank/tt-snapfork$K") / 1048576 ))
AVAIL=$(free -g | awk '/^Mem:/{print $7}')
read -r p10 r10 _ _ <<<"${S[10]}"; read -r p60 r60 _ _ <<<"${S[60]}"; read -r p120 r120 a120 f120 <<<"${S[120]}"
echo "$K,$T_LOAD,$T_READY,$p10,$r10,$p60,$r60,$p120,$r120,$a120,$f120,$STOR,$ISO,$AVAIL" >> "$CSV"
log "fork $K: storage_delta=${STOR} MiB  host available after: ${AVAIL} GiB"
