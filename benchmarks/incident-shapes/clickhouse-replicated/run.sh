#!/usr/bin/env bash
# PAR-73 on the box: every run in scenario.yml, each on a fresh world, then the quiesce check, then
# RESULTS.md. Docker Compose on the host; no VM, no fork, no CI baseline (see the README).
#
#   ./run.sh                 # every run, then the quiesce check
#   ./run.sh naive-held      # just the runs named (no quiesce check unless "quiesce" is named)
#
# Env: OUT      where results go (default /tank/work/cache/incident-shapes/clickhouse-replicated/<utc>)
#      PY       a python3 with PyYAML (default python3)
#      SCENARIO default scenario.yml beside this file
#      PARAGLOBE_DIR  the paraglobe checkout whose guest quiesce/thaw the quiesce check runs
#                     (default /tank/work/paraglobe)
# Brings up and destroys only its own compose projects: par73, par73single, par73q, par73r.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PY=${PY:-python3}; SCEN=${SCENARIO:-$HERE/scenario.yml}
OUT=${OUT:-/tank/work/cache/incident-shapes/clickhouse-replicated/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
R() { "$PY" "$HERE/rehearse.py" --scenario "$SCEN" "$@"; }
field() { "$PY" -c 'import sys, yaml; s = yaml.safe_load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$SCEN" "$1"; }
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

if [ $# -gt 0 ]; then runs=("$@"); else
  runs=(); while read -r r; do runs+=("$r"); done < <(field '"\n".join(r["name"] for r in s["runs"])'); runs+=(quiesce); fi
CUR=""
dc() { docker compose -f "$HERE/$(field "s['worlds']['$1']['compose']")" -p "$2" "${@:3}"; }
cleanup() { [ -n "$CUR" ] && dc ${CUR% *} ${CUR#* } down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "PAR-73 rehearsal: ${runs[*]}  ->  $OUT"
cp "$SCEN" "$OUT/scenario.yml"
for name in "${runs[@]}"; do
  if [ "$name" = quiesce ]; then
    log "quiesce check"; PY=$PY SCENARIO=$SCEN "$HERE/quiesce-check.sh" "$OUT/quiesce" 2>&1 | tee -a "$OUT/run.log" || log "quiesce check: FAILED (see $OUT/quiesce)"
    continue
  fi
  world=$(field "next(r['world'] for r in s['runs'] if r['name'] == '$name')")
  proj=$([ "$world" = single ] && echo par73single || echo par73)
  mkdir -p "$OUT/$name"; CUR="$world $proj"
  log "$name: a fresh $world world ($proj)"
  dc "$world" "$proj" down -v >/dev/null 2>&1 || true
  dc "$world" "$proj" up -d --wait >"$OUT/$name/up.log" 2>&1
  t0=$(date +%s); R generate --world "$world" >"$OUT/$name/facts.json" 2>>"$OUT/run.log"
  log "$name: history generated in $(( $(date +%s) - t0 )) s; running"
  R run --run "$name" --out "$OUT/$name" >"$OUT/$name/run.log" 2>&1 || log "$name: rehearse.py FAILED (see $OUT/$name/run.log)"
  grep -E 'writer started|hold|migration started|runner returned|deploy|settled|writers stopped|"red"' "$OUT/$name/run.log" | tee -a "$OUT/run.log" || true
  dc "$world" "$proj" logs --no-color >"$OUT/$name/compose.log" 2>&1 || true
  dc "$world" "$proj" down -v >/dev/null 2>&1; CUR=""
done
done_dirs=(); for d in "$OUT"/*/; do [ -f "$d/result.json" ] && done_dirs+=("$d"); done
if [ ${#done_dirs[@]} -gt 0 ]; then R report "${done_dirs[@]}" > "$OUT/RESULTS.md"; log "report: $OUT/RESULTS.md"; fi
[ -f "$OUT/quiesce/quiesce.md" ] && { echo; cat "$OUT/quiesce/quiesce.md"; } >> "$OUT/RESULTS.md"
log "done: $OUT"
