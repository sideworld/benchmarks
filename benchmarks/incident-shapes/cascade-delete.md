# Cascading account delete — did the Migration Check catch it? (PAR-76)

Can Paraglobe's Migration Check tell, before a change ships, that hard-deleting a large account
through `ON DELETE CASCADE` will lock up the account's writers, take every pooled connection,
and take down services that never touch that account? A small account's delete is the control,
and a batched purge under `lock_timeout` is measured beside it. Each is a pull request against
the `cascade` world, judged by the Check's own code path and verdict
([`cascade-delete/`](cascade-delete/), paraglobe `ops/ci/cascade.yml`). Nothing here describes
or predicts Inngest's system, whose public account of 18 September 2026 gave the shape; it is
what these changes did to this world under this workload.

**Status: prepared, not yet run on the box.** The results section is filled from the box's
`rehearse.sh` output when it has run. The laptop's look at the same mechanism, which is not the
Check, is in the rehearsal's [README](cascade-delete/README.md#checked-locally-not-on-the-box).

## Workload, every run

- **The world.** Postgres 16, `max_connections` 100, behind PgBouncer 1.24.1:
  - transaction pooling;
  - 20 server connections for the single database/user pair every client uses;
  - `max_client_conn` 1000, `query_wait_timeout` 20 s.

  All in one 8 GiB, 4-vCPU microVM forked from the CI baseline `ci-cascade`.
- **The data** (`GEN_ARGS="2 20000"`). 20,000 accounts under an `accounts` root, 24 more tables and
  30 foreign keys, all `ON DELETE CASCADE`, all indexed, seven levels deep:
  - account *a* has max(5, 1,200,000 / a^1.3) function runs, and every other table follows from
    that;
  - about 52M rows in all;
  - **account 1: 1.2M runs, ~12.7M rows** across the tables it reaches;
  - account 15000: 5 runs, about 150 rows.
- **The Check's replay.** Four probes, one per unrelated service (`api_functions`,
  `billing_invoices`, `dashboard_runs`, `ingest_event`):
  - 20 requests/s in all, round-robin;
  - each request for an account in 2000–14000;
  - 30 s warm-up, 60 s before the migration, the migration, 60 s after;
  - 30 s request timeout.
- **The traffic the Check does not drive.** The world's executor sends 150 function runs/s, open
  loop, to accounts in proportion to their size, so account 1 gets about a quarter. Each run:
  - has its own PgBouncer client connection until it is done;
  - locks its account row first (`FOR KEY SHARE`);
  - retries up to 5 times under a 30 s `statement_timeout`;
  - is shed past 600 in flight.
- **The services.** 10 client connections each, a 10 s `statement_timeout`, 3 tries per request.
- **Thresholds.** `lock_s` 5, `p99_factor` 10, the Check's defaults otherwise (PAR-71's intervals
  included).

## Results

*To be filled from the box's run. For each of `small`, `huge` and `batched`:*
- *the Check's verdict and the reasons it gives;*
- *the migration's duration;*
- *peak backends waiting on a lock, and Postgres client connections over time;*
- *failures per unrelated service during and after;*
- *the data-effect table (rows removed per table, and the cascade path to each);*
- *the run id.*

*For `huge`, the question is whether it was red, and on which rule. For `batched`, whether it
was clean, and how long it took.*

## What this does not claim

The rehearsal's README lists these in full; in short:
- **Not Inngest's schema, data, pool sizes or traffic.**
- **The executor locks its account row first.** Without that, the laptop's huge delete died of a
  deadlock in 1.0 s instead of piling up, so which of the two a real app gets depends on its
  lock order.
- **One shared pool.**
- **The Check samples Postgres, not PgBouncer.** The client-side pile-up is not among its numbers.
- **A DELETE's row locks are not counted by its blocking-lock rule.** Red can come only from the
  unrelated probes failing.

  Both are PAR-80. The raw samples for it (PgBouncer's pools and the lock waits, per run) are in
  [`cascade-delete/fixtures/`](cascade-delete/fixtures/).
- **The batched purge does not stop the account's writers first.**
