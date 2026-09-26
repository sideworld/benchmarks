# Rehearsal: a cascading account delete exhausts the pool (PAR-76)

**The shape.** An account is hard-deleted with one `DELETE`, and `ON DELETE CASCADE` carries it
through dozens of tables while live traffic runs. The statement holds every row lock it takes
until the whole cascade is done, and the work, and so the time, scales with how much data the
account has. Workers that write for that account block on those locks and retry. Every blocked
statement also holds one of PgBouncer's few server connections, so the pool is soon all
theirs. New work keeps arriving, and client connections pile up behind the pool. Services that
never touch the account queue with them and fail. The shape comes from Inngest's public account
of its incident of 18 September 2026.

This directory is an **adapter** for a paraglobe world named `cascade`, plus the changes it
rehearses. It does no measuring of its own. Each change is opened as a pull request against the
world's pinned checkout and judged by the **real Migration Check**, the same code path and
verdict as a GitHub pull request. The result is either "Paraglobe caught it" or "it didn't". The
world config and its suite are in paraglobe: `ops/ci/cascade.yml`,
`ops/ci/suites/cascade-smoke.sh`.

The write-up, with the workload stated and the box's results, is
[`../cascade-delete.md`](../cascade-delete.md).

## What it reproduces

| | |
|---|---|
| the world | Postgres 16 (`max_connections` 100) behind PgBouncer 1.24.1 in **transaction** pooling mode, with **20** server connections for the one database/user every client shares and `query_wait_timeout` 20 s. Four HTTP services and an executor, all through that PgBouncer (`compose/docker-compose.cascade.yml`). |
| the graph | An `accounts` root and **24 tables** under it, **30** foreign keys, every one `ON DELETE CASCADE` and every one indexed. Seven levels at the deepest: accounts › workspaces › apps › functions › function_runs › run_steps › step_outputs. Some tables are reached by more than one path (`migrations/0001_schema.sql`). |
| the skew | 20,000 accounts; account *a* has max(5, 600000·scale / a^1.3) function runs, and every other table follows from that. At the box's scale 2 that is about **52M rows**, about 12.7M of them account 1's (1.2M runs). Account 1,000 has 150 runs; from about 13,800 on, every account has the minimum, 5. The generator is deterministic and follows `benchmarks/lib`'s bulk-load profile (`scale/gen.sql`). |
| the unrelated services | `api`, `billing`, `dashboard` and `ingest` (reads, and one write path). Each request picks an account from 2000–14000, never one the changes delete. Each service has a 10-connection pool, a 10 s `statement_timeout`, and 3 tries per request. These are the Migration Check's four probes, so its per-probe table is a per-service table. |
| the retrying executor | Function runs arrive at **150/s**, open loop, for accounts picked in proportion to their size, so account 1 gets about a quarter of them. Each run has its own client connection until it is done, with **5 tries** (0.25 s doubling, to at most 4 s apart) under a 30 s `statement_timeout`. At most 600 are in flight; past that a run is shed and counted. A run is one transaction: its account row `FOR KEY SHARE` first, then the event, the run, its steps and events, and the account's usage counter. |
| the changes | `changes/delete-small-account.sql`: account 15000 (5 runs, about 150 rows). `changes/delete-huge-account.sql`: account 1. Each is one `DELETE FROM accounts`. |
| the safe form | `changes/purge-huge-account-batched.sql`: the same account purged leaf-first in batches of 2,000. Each batch is its own transaction, and each statement runs under `lock_timeout` 2 s, retried with growing waits. The account row goes last, when its cascade reaches only rows written since. It runs as its own pull request, on the same baseline and workload, and is judged the same way. A DELETE has no mechanical safe form for the Check to derive (`safe_form: none`). |
| the judging | The Check replays the four probes at 20 req/s through a 30 s warm-up and a 60 s before-window, then runs the migration (the change) with its sampler on, then a 60 s after-window. Each file is judged by the world's thresholds (`lock_s` 5, `p99_factor` 10). It reports lock waits, Postgres client backends over time, failures per probe, and the data-effect table: rows removed per table, each reached-from path, all expected (`paraglobe: expect-row-loss`). |

### One condition, stated because it matters

The executor locks its account row first. Without that, the rehearsal does not reproduce. A
run's first insert takes its foreign-key lock on the workspace row before the one on the account
row, while the cascade locks the account and then its workspaces. On the laptop, Postgres's
deadlock detector ended the huge delete after **1.0 s** (`deadlock detected`), and nothing piled
up. That was a trial run by hand at scale 0.3, with the executor as it was before this change;
`local-check.sh` does not reproduce it, because the executor now takes the lock. An app that loads and holds its tenant row first behaves like the rehearsal. One that
doesn't may see a delete that fails fast, which is another outcome, and this rehearsal does not
measure it.

## Checked locally, not on the box

`./local-check.sh 1` on the laptop: Docker Desktop, 10 CPUs, scale 1 (half the box's), each
change on a fresh world. This is **not** the Migration Check. It runs the change with psql under
the same probe replay (paraglobe's `ops/migration-load.py`, 20 req/s) and samples PgBouncer's
pools every second.

| change | how long | unrelated services during it (each) | PgBouncer | Postgres | executor |
|---|---|---|---|---|---|
| small delete (account 15000) | 0.1 s | 0 failed | no queue | 0 waiting on a lock | untouched |
| **huge delete (account 1)** | **31.6 s** | **13–14 of ~158 failed** (30 s timeouts), p99 30.0 s against 13–20 ms before; 0 failed after, p99 ~1.6 s | clients 19 → **644**, 624 queued; 20 of 20 server connections busy | **20** waiting on the delete's locks | at its 600-in-flight cap; 3,952 runs shed, 600 retries (580 `query_wait_timeout`, 20 `statement_timeout`) |
| batched purge (account 1, 6.39M rows, 668 batches) | 30.1 s | 0 failed, p99 12–27 ms | no queue, at most 9 server connections busy | at most 1 waiting | 5 runs failed on the vanished account, nothing shed |

The raw samples behind this table are `fixtures/local-scale1/`, recorded for PAR-80. The
earlier run it replaced (same script, same scale) gave 32.8 s and 12% failed for the huge delete,
and 38.6 s with none failed for the batched purge. At the box's scale 2 the huge delete has
twice the rows to cascade through.

## What it does not claim

- **Not Inngest's system.** It has their shape, not their schema, data, pool sizes, retry
  policy, traffic or hardware. It says what this world did under this workload, and nothing
  about what they saw or should have done.
- **The executor locks its account first**, as described above. The lock order decides whether
  a hard delete piles up or deadlocks, and the rehearsal chose the order that piles up.
- **One PgBouncer, one pool.** Every service and the executor share one database/user pair, so
  one pool. With per-service pools, or `max_db_connections`, or a second PgBouncer, "unrelated
  services fail" might not follow.
- **The Check samples Postgres, not PgBouncer.** Its connection counts are server-side, so they
  top out near the pool's 20. PgBouncer's client queue, where the "about 14× normal" of the
  incident would show, is not among its numbers. That is PAR-80, not this rehearsal.
  `local-check.sh` and `rehearse.sh` record PgBouncer's pools beside each run anyway, as raw
  samples for PAR-80 (`fixtures/`).
- **A DELETE takes row locks.** Its table lock is `RowExclusiveLock`, which the Check's
  blocking-lock rule does not count. If the Check calls the huge delete red, the reason is the
  unrelated probes failing, not a lock verdict. If they only slow down, it is 🟡 contention.
  Row-lock waits as a finding of their own are PAR-80's too.
- **The safe form does not stop new writes.** A real purge would first mark the account disabled
  so writers stop. This one chases the executor's new runs until it catches up.

## Files

| file | what |
|---|---|
| `app.spec` | the world, for `vm/onboard-generic.sh`: repository and tag, compose, datasets, hooks, generator (`GEN_ARGS="2 20000"`), guest |
| `compose/` | `docker-compose.cascade.yml` (everything inline; only the database's dataset is mounted), with an nginx gateway routing `/api`, `/billing`, `/dashboard` and `/ingest` to the four services; `cascade.env` (host: services 18480–18483, gateway 18484), `vm.env` (guest: the gateway on 8080, the one port a fork forwards) |
| `app/` | the one image: `cascade_app.py` (the four services and the executor, `ROLE` picks) and its Dockerfile |
| `migrations/0001_schema.sql` | the schema, applied once by `init-app.sh`; a pull request's `0002_*.sql` is the change |
| `changes/` | the three changes, each opened as a pull request by `rehearse.sh` |
| `scale/` | the generator |
| `migration-check.yml` | the Migration Check adapter: probes, how it reaches Postgres, the workload notes |
| `build-image.sh`, `init-app.sh`, `probe.sh` | onboarding's hooks and readiness probe |
| `rehearse.sh` | the box: each change as a pull request through `ops/ci-runner-sim.sh`, its result and comment kept |
| `local-check.sh` | the laptop's look, above |
| `fixtures/` | the raw samples PAR-80 needs (PgBouncer's pools, Postgres's lock waits, the probes, the executor), per change; the laptop's now, the box's when it has run |
| `tests/` | the app against fakes, the files against each other, each change through the Check's own extractor (`python3 -m unittest discover -s tests`) |

## Run it

The box's exact steps are on PAR-76. In short:
1. Merge this and paraglobe's `ops/ci/cascade.yml`, install the release, and tag this repository
   `cascade-delete-v1`.
2. `vm/onboard-generic.sh <this dir>/app.spec`.
3. `ops/ci-baseline.sh cascade`.
4. `./rehearse.sh`.

**v2, the gateway (PAR-83).** Up to `cascade-delete-v1`, the fork forwarded four guest ports and
three probes named theirs through `${CI_KK}`, which the Migration Check never substitutes: PAR-76's
first run judged one probe of four. From `cascade-delete-v2` the world has one front door, and
every probe is `http://127.0.0.1:${PORT}/<service>/…`. The guest's ports are part of the snapshot,
so an existing cascade world must be **re-onboarded**: merge this and paraglobe's matching
`ops/ci/cascade.yml` (`pinned: cascade-delete-v2`, `guest.ports: "8080"`), tag this repository
`cascade-delete-v2`, then steps 2 and 3 again.
