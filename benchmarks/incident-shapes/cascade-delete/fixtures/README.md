# Raw runs, for PAR-80

PAR-80 is the Migration Check's two blind spots that this rehearsal shows:
- **row-lock waits:** backends queued behind a DELETE's row locks, which the blocking-lock rule
  doesn't count;
- **PgBouncer's client queue:** the Check samples Postgres, not the pooler in front of it.

These are the rehearsal's raw samples for those two. They are recorded and not judged, so the
work on PAR-80 has real runs to test against.

`local-scale1/` is the laptop, from `../local-check.sh 1` (Docker Desktop, 10 CPUs, scale 1),
one directory per change on a fresh world. It is **not** a Migration Check run: the change ran
with psql under the Check's probe replay. The box's runs are added beside it as `box/` when it
has run: `../rehearse.sh` writes the same PgBouncer file, plus the Check's own samples from the
run.

## Files, per change

| file | what | format |
|---|---|---|
| `window` | when the change ran | `<t_start> <t_end>`, epoch seconds |
| `pgbouncer` | PgBouncer's pool, every second | `<ts>\|` then the `cascade` row of `SHOW POOLS` (1.24.1): `database\|user\|cl_active\|cl_waiting\|cl_active_cancel_req\|cl_waiting_cancel_req\|sv_active\|sv_active_cancel\|sv_being_canceled\|sv_idle\|sv_used\|sv_tested\|sv_login\|maxwait\|maxwait_us\|pool_mode\|load_balance_hosts` |
| `pg` | Postgres, every second: the Check's sampler row | `<ts>\|<backends waiting on a lock>\|<client backends>\|<modes granted on accounts>\|<modes waiting on accounts>`, the shape of the Check's `<tag>-samples.txt` (at 1 s rather than 0.2 s) |
| `load.jsonl` | every probe request | paraglobe's `ops/migration-load.py` output: `{"t", "probe", "status", "ms", ...}` |
| `executor` | the executor's counters, every 10 s | one JSON line: `ok`, `failed`, `retries`, `errors` by class (`shed` = past the 600 in-flight cap), `p50_ms`, `p99_ms`, `inflight` |
| `psql` | what the change printed | psql with `\timing` |
| `summary` | `local-check.sh`'s reading of the above | text |

The box adds `<change>.check/`, the Check's own files from the run's `mc/` directory:
- `naive-samples.txt` (0.2 s);
- `naive-locks.txt` (every lock on the touched tables, by backend);
- `naive-load.jsonl`, `naive-statements.json`, `naive-data-*`, `naive-pglog.txt`;
- `naive-waits.txt` (every lock waited for, with `pg_blocking_pids`) and `naive-pooler.txt`
  (PgBouncer's `SHOW POOLS` every 0.2 s from the Check's own sampler): PAR-80's two lanes;
- `migrations.json` and `workload.json`, so the directory folds as a whole run.

It also adds `<change>.pgbouncer`, in the format above, sampled from inside the fork.

## What the fixtures show

Local, scale 1. The huge delete is the row-lock case:
- Postgres backends waiting on a lock sit at 20 (all of PgBouncer's server connections) for the
  whole delete;
- `cl_waiting` in `pgbouncer` climbs into the hundreds;
- none of it is a table lock the Check's rule would count.

The batched purge and the small delete are the controls.
