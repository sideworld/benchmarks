#!/usr/bin/env bash
# PAR-73's last question: does paraglobe's ClickHouse quiesce/thaw recipe work with Keeper?
#
#   ./quiesce-check.sh <out-dir>
#
# The hard case: a snapshot taken mid-migration, with ch2's merges held so its replication queue
# still has the index-drop mutation and the ADD COLUMN's ALTER_METADATA waiting, and the writer
# inserting until just before. Then:
#   1  the guest recipe, as written: paraglobe's vm/guest-generic/usr/local/bin/quiesce, run on the
#      host with two shims -- `docker ps` sees only this check's containers, and `fsfreeze` is a
#      no-op (there is no guest /data here) -- so every docker exec it makes is its own
#   2  the instant: `docker pause` on Keeper and both replicas together (what fsfreeze does for the
#      guest's one filesystem: no write lands after it), the three volumes copied, `docker unpause`
#   3  thaw (the same shims) on the original; the copies started as a second project, par73r, and
#      thawed as post-restore would
#   4  both pairs verified: writable (no read-only replica), the queue and the mutation drained, the
#      column on both replicas, every row there was at the pause, a write through each replica read
#      back on the other (rehearse.py verify)
# What this cannot show: a Firecracker memory snapshot. A restored VM resumes its processes with
# STOP MERGES still in force until thaw runs; the copies here start fresh processes, as the native
# snapshot's (vm/app-snapshot-native.sh) clean stop and start do. The README says so.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:?out dir}; mkdir -p "$OUT"
PY=${PY:-python3}; SCEN=${SCENARIO:-$HERE/scenario.yml}
PARAGLOBE_DIR=${PARAGLOBE_DIR:-/tank/work/paraglobe}
GUEST=$PARAGLOBE_DIR/vm/guest-generic/usr/local/bin
[ -f "$GUEST/quiesce" ] && [ -f "$GUEST/thaw" ] || { echo "no $GUEST/quiesce or thaw (set PARAGLOBE_DIR)" >&2; exit 2; }
ROWS=${QUIESCE_ROWS:-5000000}
CF="$HERE/compose/replicated.yml"
R() { "$PY" "$HERE/rehearse.py" --scenario "$SCEN" "$@"; }
q() { curl -sS --fail-with-body "http://127.0.0.1:$1/" --data-binary "$2"; }
log() { echo "[$(date -u +%H:%M:%S)] quiesce: $*" | tee -a "$OUT/log"; }
WPID=""
cleanup() {
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null || true
  docker compose -f "$CF" -p par73q down -v >/dev/null 2>&1 || true
  CH1_PORT=18124 CH2_PORT=28124 docker compose -f "$CF" -p par73r down -v >/dev/null 2>&1 || true
  for v in keeper ch1 ch2; do docker volume rm -f "par73r_$v" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
cleanup

# ------------------------------------------------ the world, mid-migration
docker compose -f "$CF" -p par73q up -d --wait >"$OUT/up.log" 2>&1
R generate --world replicated --rows "$ROWS" >"$OUT/facts.json" 2>>"$OUT/log"
"$PY" "$HERE/writer.py" --version old --targets ch1=http://127.0.0.1:18123,ch2=http://127.0.0.1:28123 \
  --log "$OUT/writer.jsonl" --first-batch 1 --batches-per-s 4 --rows 1000 & WPID=$!
sleep 10
q 28123 "SYSTEM STOP MERGES events"
q 18123 "ALTER TABLE events DROP INDEX idx_payload"
q 18123 "ALTER TABLE events ADD COLUMN region LowCardinality(String) DEFAULT ''"
sleep 5
kill "$WPID"; wait "$WPID" 2>/dev/null || true; WPID=""
sleep 2
EXPECT=$(q 18123 "SELECT count() FROM events")
q 28123 "SELECT groupArray(type) FROM system.replication_queue WHERE table = 'events'" > "$OUT/ch2-queue-before.txt"
log "mid-migration: ch1 holds $EXPECT rows; ch2's queue: $(tr -d '\n' < "$OUT/ch2-queue-before.txt" | cut -c1-200)"

# ------------------------------------------------ 1. the guest recipe, shimmed to this project
SHIM=$OUT/shim; mkdir -p "$SHIM"
REAL_DOCKER=$(command -v docker)
cat > "$SHIM/docker" <<SH
#!/bin/sh
if [ "\$1" = ps ]; then shift; exec "$REAL_DOCKER" ps --filter "label=com.docker.compose.project=\$SHIM_PROJECT" "\$@"; fi
exec "$REAL_DOCKER" "\$@"
SH
printf '#!/bin/sh\necho "fsfreeze $* (shim: no guest /data here)"\n' > "$SHIM/fsfreeze"
chmod +x "$SHIM/docker" "$SHIM/fsfreeze"
log "the guest quiesce, on par73q's containers"
SHIM_PROJECT=par73q PATH="$SHIM:$PATH" sh "$GUEST/quiesce" > "$OUT/quiesce.out" 2>&1 && QRC=0 || QRC=$?
sed 's/^/    /' "$OUT/quiesce.out" | tee -a "$OUT/log"
STOPPED=$(q 18123 "SELECT count() FROM system.replication_queue WHERE table='events'" 2>/dev/null || echo "?")

# ------------------------------------------------ 2. the instant: pause, copy, unpause
C="par73q-keeper-1 par73q-ch1-1 par73q-ch2-1"
t0=$(date +%s.%N)
# shellcheck disable=SC2086
docker pause $C >/dev/null
IMG=clickhouse/clickhouse-server:25.8.33.6
for v in keeper ch1 ch2; do
  docker volume create "par73r_$v" >/dev/null
  docker run --rm --entrypoint sh -v "par73q_$v:/from:ro" -v "par73r_$v:/to" "$IMG" -c 'cp -a /from/. /to/'
done
# shellcheck disable=SC2086
docker unpause $C >/dev/null
FROZEN=$(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')
log "paused, copied the three volumes, unpaused: ${FROZEN}s"

# ------------------------------------------------ 3. thaw the original; start and thaw the copy
SHIM_PROJECT=par73q PATH="$SHIM:$PATH" sh "$GUEST/thaw" > "$OUT/thaw-original.out" 2>&1 || true
sed 's/^/    /' "$OUT/thaw-original.out" | tee -a "$OUT/log"
CH1_PORT=18124 CH2_PORT=28124 docker compose -f "$CF" -p par73r up -d --wait >"$OUT/up-restored.log" 2>&1 && UPRC=0 || UPRC=$?
SHIM_PROJECT=par73r PATH="$SHIM:$PATH" sh "$GUEST/thaw" > "$OUT/thaw-restored.out" 2>&1 || true
sed 's/^/    /' "$OUT/thaw-restored.out" | tee -a "$OUT/log"

# ------------------------------------------------ 4. verify both
R verify --world replicated --rows "$EXPECT" > "$OUT/verify-original.json" && VO=ok || VO=FAILED
if [ "$UPRC" = 0 ]; then
  CH1_PORT=18124 CH2_PORT=28124 R verify --world replicated --rows "$EXPECT" > "$OUT/verify-restored.json" && VR=ok || VR=FAILED
else VR="FAILED (the restored project did not come up; see up-restored.log)"; echo '{}' > "$OUT/verify-restored.json"; fi
log "original after thaw: $VO; restored copy: $VR"

"$PY" - "$OUT" "$QRC" "$FROZEN" "$EXPECT" "$VO" "$VR" "$STOPPED" <<'PY' > "$OUT/quiesce.md"
import json, os, sys
out, qrc, frozen, expect, vo, vr, stopped = sys.argv[1:]
rd = lambda f: open(os.path.join(out, f)).read().strip()
print("## Quiesce and thaw with Keeper\n")
print(f"Snapshot taken mid-migration: {int(expect):,} rows on ch1; ch2's merges held, its queue `{rd('ch2-queue-before.txt')[:160]}`. "
      f"The guest `quiesce` exited {qrc}; Keeper and both replicas paused, copied and unpaused in {frozen} s.\n")
print("| | |\n|---|---|")
print("| quiesce said | " + "<br>".join(rd("quiesce.out").splitlines()) + " |")
print("| thaw (original) said | " + "<br>".join(rd("thaw-original.out").splitlines()) + " |")
print("| thaw (restored) said | " + "<br>".join(rd("thaw-restored.out").splitlines()) + " |")
for label, f, v in (("original, after thaw", "verify-original.json", vo), ("restored copy", "verify-restored.json", vr)):
    try:
        j = json.load(open(os.path.join(out, f)))
        reps = "; ".join(f"{n}: read-only {x.get('readonly')}, queue {x.get('queue')}, open mutations {x.get('mutations_open')}, "
                         f"column {x.get('has_column')}, rows {x.get('rows')}, round trip {x.get('round_trip')}"
                         for n, x in (j.get("replicas") or {}).items())
    except (OSError, ValueError):
        reps = "no result"
    print(f"| {label} | **{v}** — {reps} |")
PY
cat "$OUT/quiesce.md"
[ "$VO" = ok ] && [ "$VR" = ok ]
