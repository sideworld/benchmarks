#!/usr/bin/env bash
# The laptop's look at the shape, before the box: NOT the Migration Check, and not what the
# write-up reports as the result. A fresh world per change, native Docker Compose, the change run
# with psql under paraglobe's own replay (ops/migration-load.py, the four probes at 20 req/s),
# PgBouncer's pools and Postgres's lock waits sampled every second -- the numbers the README's
# "Checked locally" section quotes, so they can be had again.
#
#   ./local-check.sh [scale] [change...]     # default: scale 1; small huge batched
#
# Env: PARAGLOBE_DIR (default ../paraglobe beside this repository), DATA (the Postgres data
# directory, default $TMPDIR/cascade-pgdata; wiped per change), OUT (default $TMPDIR/cascade-local).
# Brings up and takes down only the compose project `cascade`.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARAGLOBE_DIR=${PARAGLOBE_DIR:-$(cd "$HERE/../../../../paraglobe" && pwd)}
SCALE=${1:-1}; shift || true
[ $# -gt 0 ] && runs=("$@") || runs=(small huge batched)
DATA=${DATA:-${TMPDIR:-/tmp}/cascade-pgdata}; OUT=${OUT:-${TMPDIR:-/tmp}/cascade-local}
mkdir -p "$OUT"
dc() { CASCADE_PG_DATA=$DATA docker compose -p cascade --env-file "$HERE/compose/cascade.env" -f "$HERE/compose/docker-compose.cascade.yml" "$@"; }
psql_() { docker exec -i -e PGPASSWORD=cascade cascade-db psql -U cascade -d cascade -X "$@"; }
file_of() { case $1 in small) echo delete-small-account ;; huge) echo delete-huge-account ;; batched) echo purge-huge-account-batched ;; *) return 1 ;; esac; }
trap 'dc down >/dev/null 2>&1 || true' EXIT
cat > "$OUT/probes.json" <<'J'
[{"name":"api_functions","method":"GET","url":"http://127.0.0.1:18480/functions","headers":{}},
 {"name":"billing_invoices","method":"GET","url":"http://127.0.0.1:18481/invoices","headers":{}},
 {"name":"dashboard_runs","method":"GET","url":"http://127.0.0.1:18482/runs","headers":{}},
 {"name":"ingest_event","method":"POST","url":"http://127.0.0.1:18483/events","headers":{"Content-Type":"application/json"},"body":"{\"name\":\"probe\"}"}]
J
"$HERE/build-image.sh"
for r in "${runs[@]}"; do
  f=$(file_of "$r") || { echo "unknown change '$r'" >&2; exit 2; }
  echo "== $r ($f.sql) on a fresh world at scale $SCALE"
  dc down >/dev/null 2>&1 || true; rm -rf "$DATA"; mkdir -p "$DATA"
  dc up -d --wait >/dev/null 2>&1; "$HERE/init-app.sh" >/dev/null
  "$HERE/scale/gen.sh" "$SCALE" 20000 2>&1 | grep -E 'done in|account 1:'
  sleep 40                                                   # the executor back at its steady rate
  rm -f "$OUT/$r".*
  # Two samplers, raw, kept as PAR-80's fixtures (fixtures/README.md has the formats):
  #   <r>.pgbouncer  every second, PgBouncer's whole SHOW POOLS row for the cascade pool
  #   <r>.pg         every second, the Migration Check sampler's row (ts|lock waiters|client
  #                  backends|modes granted on accounts|modes waiting on accounts)
  ( while [ ! -f "$OUT/$r.stop" ]; do
      p=$(docker exec -e PGPASSWORD=cascade cascade-pgbouncer psql -h 127.0.0.1 -U cascade -d pgbouncer -Atc "show pools" 2>/dev/null \
            | awk -F'|' '$1 == "cascade"')
      echo "$(date +%s.%N)|${p:-unavailable}"; sleep 1
    done > "$OUT/$r.pgbouncer" ) &
  ( while [ ! -f "$OUT/$r.stop" ]; do
      q=$(psql_ -Atc "select (select count(*) from pg_stat_activity where wait_event_type = 'Lock'), (select count(*) from pg_stat_activity where backend_type = 'client backend'), (select coalesce(string_agg(distinct mode, ','), '') from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'accounts' and l.granted), (select coalesce(string_agg(distinct mode, ','), '') from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'accounts' and not l.granted)" 2>/dev/null)
      echo "$(date +%s.%N)|${q:-unavailable}"; sleep 1
    done > "$OUT/$r.pg" ) &
  python3 "$PARAGLOBE_DIR/ops/migration-load.py" --probes "$OUT/probes.json" --rps 20 --out "$OUT/$r.load.jsonl" --stop-file "$OUT/$r.stop" & LP=$!
  sleep 30; T0=$(date +%s.%N)
  psql_ -c '\timing on' -f - < "$HERE/changes/$f.sql" > "$OUT/$r.psql" 2>&1 || true
  T1=$(date +%s.%N); echo "$T0 $T1" > "$OUT/$r.window"; sleep 40; touch "$OUT/$r.stop"; wait "$LP" || true; sleep 2
  docker logs --since 3m cascade-executor 2>/dev/null | grep '"role": "executor"' > "$OUT/$r.executor" || true
  python3 - "$OUT" "$r" "$T0" "$T1" <<'PY' | tee "$OUT/$r.summary"
import json, sys
out, r, t0, t1 = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
psql = open(f"{out}/{r}.psql").read()
L = [json.loads(x) for x in open(f"{out}/{r}.load.jsonl")]
ok = lambda s: isinstance(s, int) and 200 <= s < 300
print(f"  statement {t1 - t0:.1f} s; psql: " + " | ".join(x.strip() for x in psql.splitlines() if x.startswith(("DELETE", "CALL")) or "ERROR" in x or "purged" in x)[:200])
for w, (a, b) in {"before": (t0 - 30, t0), "during": (t0, t1), "after": (t1, t1 + 40)}.items():
    per = {}
    for x in L:
        if a <= x["t"] < b:
            d = per.setdefault(x["probe"], [0, 0, []]); d[0] += 1; d[1] += not ok(x["status"]); d[2].append(x["ms"])
    print(f"  {w:6} " + "; ".join(f"{k} {v[1]}/{v[0]} failed, p99 {sorted(v[2])[int(0.99 * (len(v[2]) - 1))]:.0f} ms" for k, v in sorted(per.items())))
# SHOW POOLS: database|user|cl_active|cl_waiting|cl_active_cancel_req|cl_waiting_cancel_req|sv_active|...
B = [x.rstrip("\n").split("|") for x in open(f"{out}/{r}.pgbouncer")]
B = {round(float(x[0])): (int(x[3]), int(x[4]), int(x[7])) for x in B if len(x) > 8}
G = [x.rstrip("\n").split("|") for x in open(f"{out}/{r}.pg")]
G = {round(float(x[0])): int(x[1]) for x in G if len(x) >= 5}
def peak(a, b):
    xs = [p for t, p in B.items() if a <= t <= b]
    ls = [n for t, n in G.items() if a <= t <= b]
    return (max(p[0] + p[1] for p in xs), max(p[1] for p in xs), max(p[2] for p in xs), max(ls, default=0)) if xs else None
before, during = peak(t0 - 30, t0), peak(t0, t1 + 1)
print(f"  pgbouncer clients (active+waiting) before {before[0] if before else '?'} peak during {during[0] if during else '?'}"
      f" (waiting {during[1] if during else '?'}); server connections active {during[2] if during else '?'} of 20; Postgres backends waiting on a lock {during[3] if during else '?'}")
ex = [json.loads(x) for x in open(f"{out}/{r}.executor") if x.strip().startswith("{")]
ex = [e for e in ex if t0 - 10 <= e.get("t", 0) <= t1 + 30]
tot = {}
for e in ex:
    for k, v in (e.get("errors") or {}).items(): tot[k] = tot.get(k, 0) + v
print(f"  executor, the change +/- a little: ok {sum(e.get('ok', 0) for e in ex)}, failed {sum(e.get('failed', 0) for e in ex)}, retries {sum(e.get('retries', 0) for e in ex)}, max in flight {max((e.get('inflight', 0) for e in ex), default=0)}; {tot}")
PY
done
echo "results in $OUT"
