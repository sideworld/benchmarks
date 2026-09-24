# Bulk-load profile (generic, all generators)

> **Paths.** This document was written in a monorepo that has since been split. Paths beginning with
> `../specimen/` or `../paraglobe/` point into the sibling repositories, expected to be checked out
> next to this one (`SPECIMEN_DIR` / `PARAGLOBE_DIR` in the scripts). Paths without that prefix are in this repo.

What every data-plane generator in this repo does around its load, regardless of store. The
specimen's Go generator (`../specimen/data/scale`), TrainTicket's Mongo generator (`benchmarks/trainticket/scale`)
and Mastodon's SQL generator (`benchmarks/mastodon/scale`) follow it; the Postgres half is code
(`pg-bulk-load-begin.sql` / `pg-bulk-load-end.sql`, concatenated around the generator's SQL).

1. **Session, not server**: `synchronous_commit=off`, big `work_mem`, and — Postgres —
   `session_replication_role = replica`, which **disables RI (foreign-key) triggers for the
   session**. Without it Postgres queues one after-trigger event per row per FK and runs them all,
   single-threaded, at statement end: a 100M-row insert into a table with four FKs spent 37 min
   writing its heap and then >25 min in `afterTriggerInvokeEvents` (Mastodon, 2026-09-21, see
   `benchmarks/mastodon.md`). Ids from a generator are correct by construction; prove it after.
   Server-side bulk settings (`max_wal_size`, `checkpoint_*`, `wal_compression`) stay in the
   compose override, never in the probe runs.
2. **Secondary indexes dropped** for the load and rebuilt after (definitions saved first, and
   restored on any exit).
3. **Validate after, every FK pair**: re-enable triggers, then for each foreign key on a loaded
   table count child rows whose non-null key has no parent — the count must be 0 and is recorded.
   `pg-bulk-load-end.sql` derives the pairs from `pg_constraint` (single-column FKs; composite ones
   are reported as skipped). Stores without RI (Mongo) validate their own invariants
   (TrainTicket: `check.js`, orders ↔ payments ↔ users).
4. `VACUUM ANALYZE` (or the store's equivalent) before anything is timed.
