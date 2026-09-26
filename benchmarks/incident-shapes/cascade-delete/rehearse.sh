#!/usr/bin/env bash
# PAR-76 on the box: each change in changes/ opened as a pull request against the cascade world's
# pinned checkout, and judged by the Migration Check as any world's pull request is -- through
# paraglobe's ops/ci-runner-sim.sh, the same path a GitHub runner takes. Nothing here measures:
# the verdict, the lock and pool numbers, the per-service failures and the data-effect table are
# the Check's, in its result JSON and its pull-request comment.
#
#   ./rehearse.sh                    # small, huge, batched, in that order
#   ./rehearse.sh huge batched       # the ones named
#
# Beside each run it keeps the raw samples PAR-80 needs, which the Check does not judge: the
# Check's own lock and connection samples (copied from the run's mc/ directory), and PgBouncer's
# SHOW POOLS every second from inside the fork, which nothing in the Check samples. Recorded, not
# judged; the formats are in fixtures/README.md.
#
# Needs the world onboarded (vm/onboard-generic.sh app.spec) and its CI baseline built
# (ops/ci-baseline.sh cascade): see the README. Runs as root (the run directories and the fork's
# ssh key are root's). Env:
#   PARAGLOBE_DIR  the installed release, whose ops/ci-runner-sim.sh and comment renderer run
#                  (default /opt/paraglobe/current)
#   SRC            the world's pinned checkout, which the pull requests are branches of
#                  (default /tank/work/cascade; it is put back on the tag afterwards, always)
#   OUT            where the results go (default /tank/work/cache/incident-shapes/cascade-delete/<utc>)
# ops/ci-runner-sim.sh's own knobs (PARAGLOBE_CI_KEY, PARAGLOBE_ENTRY) pass through.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARAGLOBE_DIR=${PARAGLOBE_DIR:-/opt/paraglobe/current}
SRC=${SRC:-/tank/work/cascade}
TAG=cascade-delete-v1
OUT=${OUT:-/tank/work/cache/incident-shapes/cascade-delete/$(date -u +%Y%m%dT%H%M%SZ)}
RUNS=${CI_CACHE:-/tank/work/cache}/paraglobe-ci/runs/cascade
FORK_SSH=31722                                   # fork 17 (ops/ci/cascade.yml): ssh on 3<kk>22
KEY=$PARAGLOBE_DIR/vm/out/id_specimen_vm
REL=benchmarks/incident-shapes/cascade-delete
declare -A FILE=([small]=delete-small-account [huge]=delete-huge-account [batched]=purge-huge-account-batched)
declare -A PR=([small]=1 [huge]=2 [batched]=3)
[ $# -gt 0 ] && runs=("$@") || runs=(small huge batched)
for r in "${runs[@]}"; do [ -n "${FILE[$r]:-}" ] || { echo "unknown rehearsal '$r' (small, huge, batched)" >&2; exit 2; }; done
[ -x "$PARAGLOBE_DIR/ops/ci-runner-sim.sh" ] || { echo "no $PARAGLOBE_DIR/ops/ci-runner-sim.sh (set PARAGLOBE_DIR)" >&2; exit 2; }
git -C "$SRC" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "$SRC has no tag $TAG (onboard the world first)" >&2; exit 2; }
mkdir -p "$OUT"
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/log"; }
g() { git -C "$SRC" -c user.name=paraglobe-rehearsal -c user.email=rehearsal@paraglobe.invalid "$@"; }
# The baseline's suite runs from $SRC at its HEAD; leave it where it was found, whatever happens.
trap 'touch "$OUT"/*.pgbouncer.stop 2>/dev/null; g checkout -q --detach "$TAG"' EXIT
# PgBouncer's pools every second, from inside whichever fork is up on slot 17 (none, between
# phases: those seconds are skipped). Until <file>.stop exists.
sample_pgbouncer() {
  while [ ! -f "$1.stop" ]; do
    p=$(ssh -p "$FORK_SSH" -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR -o ConnectTimeout=2 -o BatchMode=yes root@127.0.0.1 \
          "docker exec -e PGPASSWORD=cascade cascade-pgbouncer psql -h 127.0.0.1 -U cascade -d pgbouncer -Atc 'show pools'" 2>/dev/null \
        | awk -F'|' '$1 == "cascade"' || true)
    [ -n "$p" ] && echo "$(date +%s.%N)|$p"
    sleep 1
  done >> "$1"
}

log "PAR-76 rehearsal: ${runs[*]} -> $OUT"
for r in "${runs[@]}"; do
  f=${FILE[$r]}; mig=$REL/migrations/0002_${f//-/_}.sql
  g checkout -q --detach "$TAG"
  g checkout -q -B "rehearsal/$r"
  cp "$HERE/changes/$f.sql" "$SRC/$mig"
  g add "$mig"; g commit -q -m "rehearsal: $f"
  log "$r: pull request #${PR[$r]} adds $mig; running it through the Migration Check"
  rc=0
  sample_pgbouncer "$OUT/$r.pgbouncer" & SP=$!
  BASE_REF=$TAG PARAGLOBE_SRC=$SRC OUT=$OUT/$r.json "$PARAGLOBE_DIR/ops/ci-runner-sim.sh" cascade "${PR[$r]}" "rehearsal/$r" smoke \
    2>"$OUT/$r.stderr" || rc=$?
  touch "$OUT/$r.pgbouncer.stop"; wait "$SP" 2>/dev/null || true
  # the Check's own raw samples, from the run's directory
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run_id") or "")' "$OUT/$r.json" 2>/dev/null || true)
  if [ -n "$id" ] && [ -d "$RUNS/$id/mc" ]; then
    mkdir -p "$OUT/$r.check"
    # naive-waits.txt and naive-pooler.txt are PAR-80's lanes (row-lock waits, and PgBouncer's
    # queue from the Check's own sampler); migrations.json makes the directory a whole run to fold
    cp "$RUNS/$id"/mc/naive-samples.txt "$RUNS/$id"/mc/naive-locks.txt "$RUNS/$id"/mc/naive-load.jsonl \
       "$RUNS/$id"/mc/naive-statements.json "$RUNS/$id"/mc/naive-data-* "$RUNS/$id"/mc/naive-pglog.txt \
       "$RUNS/$id"/mc/naive-waits.txt "$RUNS/$id"/mc/naive-pooler.txt "$RUNS/$id"/mc/migrations.json \
       "$RUNS/$id"/mc/workload.json "$OUT/$r.check/" 2>/dev/null || true
  else
    log "  $r: no run directory for '${id:-?}' under $RUNS; the Check's samples were not copied"
  fi
  if command -v node >/dev/null && [ -s "$OUT/$r.json" ]; then
    node "$PARAGLOBE_DIR/ops/ci/workflows/paraglobe-comment.js" "$OUT/$r.json" > "$OUT/$r.md" 2>>"$OUT/$r.stderr" || true
  fi
  python3 - "$OUT/$r.json" "$r" "$rc" <<'PY' | tee -a "$OUT/log"
import json, sys
path, name, rc = sys.argv[1:4]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"  {name}: no result ({type(e).__name__}); runner exited {rc}, see {name}.stderr"); sys.exit()
mc = d.get("migration_check") or {}
v, n = mc.get("verdict") or {}, mc.get("naive") or {}
print(f"  {name}: {d.get('status')} -- {v.get('emoji', '')} {v.get('phrase', 'no verdict')}; migration {n.get('duration_s')} s, "
      f"peak waiting backends {(n.get('locks') or {}).get('blocked_max')}; run {d.get('run_id')}")
for why in (v.get("reasons") or [])[:4]:
    print(f"      {why}")
PY
done
log "done: $OUT (<name>.json is the Check's result, <name>.md its comment, <name>.check/ its raw samples, <name>.pgbouncer PgBouncer's; the run itself under $RUNS/)"
