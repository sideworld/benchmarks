# Rehearsal: replicated ClickHouse, an index drop, then an added column (PAR-73)

**The shape.** Two ClickHouse migrations back to back on a large replicated events table. The
first drops an unused data-skipping index, which ClickHouse carries out as a background
mutation on every replica. The second adds a column. On a replica still working through the
mutation, the ADD COLUMN's metadata change waits behind it. The migration runner waits only for
the replica it ran on (`alter_sync=1`, the default), so it reports success in well under 2 s.
The new writer version then inserts the new column. Its inserts to the lagging replica fail
(`NO_SUCH_COLUMN_IN_TABLE`), and after 3 retries the batches are dropped. The shape comes from
Trigger.dev's public write-up of its incident of 3 September 2026.

This directory rehearses that shape on a scratch world and measures:
- how long the runner took to say "done";
- when the column was actually visible on each replica;
- what each writer version lost.

It runs in the Migration Check's shape: a naive form and a safe form, the compatibility matrix
during settling, and a round trip at the end.

## What it reproduces

| | |
|---|---|
| the world | ClickHouse Keeper plus two replicas `ch1`, `ch2` (25.8.33.6, pinned). An `events` table on `ReplicatedMergeTree` with two skip indexes (`idx_name` bloom filter, `idx_payload` tokenbf). 30 million rows of history. |
| the skew | 20,000 orgs, heavy-headed: about a third of all events are in the top 1% of orgs. 40 event names in the same shape, production-heavy environments, and timestamps weighted toward the last few days of 90. The generator is deterministic (row hashes, not `rand()`), so every world of the same size is identical: `sql/generate.sql`. |
| the migration (naive) | `DROP INDEX idx_payload`, then `ADD COLUMN region`, both on `ch1` with default settings. The new writer deploys the moment the runner returns. |
| the safe form | `ADD COLUMN … SETTINGS alter_sync = 2`. The new writer deploys only once **every replica shows the column** (a gate on `system.columns`, not on the statement returning). Then `DROP INDEX`. |
| the writers | `writer.py --version old` inserts the old columns. `--version new` also inserts `region`, named in the INSERT's column list. Both send batches round-robin to both replicas, retry a failed insert 3 times on the same replica (0.5 s, 1 s, 2 s apart) and then drop it. Each reads every acked batch back. |
| the matrix | Cell **old-app-new-schema** runs the old writer throughout. Cell **new-app-new-schema** runs the new writer from the deploy on. Each cell is judged on its own round trip. |
| the round trip | Writers stop, every replica runs `SYSTEM SYNC REPLICA`, then every batch either writer *attempted* is looked for on *every* replica. |
| the verdict | 🔴 when any attempted batch never landed on every replica: dropped after its retries, or acked and then missing. Not judged, only reported: how long the runner took, and when the column was visible on every replica. |
| the single-node variant | The same table as plain `MergeTree` on one server, no Keeper, the same migration and writers. It documents whether the shape needs replication. |
| the quiesce check | Whether paraglobe's ClickHouse quiesce/thaw recipe (`vm/guest-generic/usr/local/bin/quiesce`, `thaw`) survives Keeper plus two replicas snapshotted mid-migration: `quiesce-check.sh`. |

### Why a replica lags: `pool` and `held`

PAR-73 says the ADD COLUMN "waits behind the mutation on writer replicas". The rehearsal makes
`ch2` that replica in one of two ways, and every run records which:

- **pool.** `ch2`'s background pool is shrunk to 2 threads (`config/lagging.xml`), so under
  continuous inserts the index-drop mutation competes with merges for slots. Nothing else is done
  to it. Whether `ch2` lags at 30 million rows, and for how long, is what the run measures. It
  may not lag at all: a `DROP INDEX` mutation mostly hard-links parts and deletes the index files.
- **held.** `ch2`'s merges and mutations on `events` are stopped (`SYSTEM STOP MERGES events`)
  from just before the migration, for `hold_s` (120 s), then started again. This stands in for a
  replica whose queue is backed up. It is **induced**, and the results say so on every row.

## Checked locally, not on the box

The laptop ran every run at 2 million rows with short windows: Docker Desktop, 10 CPUs,
ClickHouse 25.8.33.6. The mechanism behaves as PAR-73 describes:

- **Replicated, held.** `ADD COLUMN` returned in **0.01 s**. `ch2`'s replication queue showed 16
  `MUTATE_PART` entries ahead of the `ALTER_METADATA`, and `ch2` did not have the column until its
  merges were started again. An insert naming `region` on `ch2` failed with `Code: 16 … No such
  column region … (NO_SUCH_COLUMN_IN_TABLE)`.
  - End to end (`naive-held`): the runner returned after 0.6 s, and the column was on every
    replica 21.2 s later.
  - The new writer lost 5 of its 64 batches, all sent to `ch2`, all dropped after 3 retries. 🔴
  - The old writer lost none.
- **Safe form, held.** 🟢 `ch2` applies an ADD COLUMN with no mutation ahead of it even while its
  merges are stopped. The `DROP INDEX` that follows the deploy waited out the hold and held up
  nothing.
- **Single node, held.** The **`DROP INDEX` statement itself blocked** for as long as merges were
  stopped (22.5 s against a 20 s hold; 209 s in a manual trial). The runner could not report early
  success, the column was there when it returned, and nothing was dropped. 🟢 The single node does
  not reproduce the shape: the runner waits instead.
- **pool, at 2 million rows.** `ch2` did not lag (the column was everywhere 0.5 s after the start).
  The box's 30 million rows under the same inserts are what `naive-pool` is for.
- **The quiesce check passed.** Snapshotted mid-migration, with `ch2` holding 5 `MUTATE_PART` and 1
  `ALTER_METADATA`, both the original after thaw and the restored copy were writable, drained the
  queue and the mutation, had the column on both replicas and every row there was at the pause,
  and carried a write through each replica to the other. One wart: the recipe matches images on
  `*clickhouse*`, which includes `clickhouse/clickhouse-keeper`. It therefore runs
  `clickhouse-client` inside Keeper, which has none, and logs `clickhouse-client failed on …keeper…
  (snapshot will still be crash-consistent)` and `could not restart merges on …keeper…`. The run is
  harmless, but the lines are misleading. The fix belongs in paraglobe (a `*clickhouse-keeper*`
  case ahead of `*clickhouse*`), not here.

The box's numbers replace these once it has run. They go in `RESULTS.md` beside this file.

## What it does not claim

- **Not Trigger.dev's system.** It has their shape, not their schema, versions, hardware, pool
  sizes, Keeper topology, row counts, migration tool or writer. Whether their replica lagged for
  the reason `pool` models, or for another, this rehearsal cannot say.
- **`held` is induced.** A red under `held` shows what the naive order does *when* a replica lags
  behind a mutation. It does not show that a replica will lag. Only `pool` measures that, and
  only for this table on this box.
- **One Keeper node, one shard, two replicas.** Keeper quorum loss, more replicas, distributed
  tables and `ON CLUSTER` DDL queues are out of scope. The migration is run on `ch1` directly,
  which on a `ReplicatedMergeTree` replicates through Keeper's log either way.
- **The writer is a stand-in.** It is one process per version, single-threaded, retrying on the
  same replica, round-robin over both. A real writer pool with more concurrency, failover to
  another replica, or `input_format_skip_unknown_fields` inserts would lose more or less, or lose
  silently. (Without the column list, JSONEachRow drops the unknown field and the insert
  "succeeds".)
- **Not through paraglobe's Migration Check harness: a one-off rig.** `ops/migration-check.sh`
  and the PR check speak Postgres (psql, `pg_locks`, table snapshots) and fork a CI baseline VM.
  This world is neither Postgres nor onboarded as a VM world, so `rehearse.py` runs the Migration
  Check's phases itself on Docker Compose on the host: naive and safe forms, a sampler, the
  matrix cells, a round trip, a verdict. Its verdict is this rig's, not Paraglobe's. The measuring
  it does moves into the engine under PAR-79 (a Migration Check for ClickHouse), and this rig is
  not to be grown in the meantime. PAR-76's rehearsal (`../cascade-delete/`), a Postgres world, is
  the other kind: an adapter only, judged by the real Check.
- **The quiesce check is not a Firecracker snapshot.** It runs the guest's own `quiesce` and `thaw`
  (shimmed to see only this check's containers, with `fsfreeze` a no-op). It pauses Keeper and both
  replicas together and copies their volumes, as fsfreeze plus a ZFS snapshot would capture them,
  then restores the copies into fresh processes. A restored VM resumes its processes from memory
  with `STOP MERGES` still in force until `thaw` runs, and that part is not exercised here.

## Where the issue and this directory differ

PAR-73 asks for the write-up at `benchmarks/clickhouse-replicated/INCIDENT-SHAPE.md`. The
rehearsals were asked for under `benchmarks/incident-shapes/`, so it is here: this README, plus
`RESULTS.md` once the box has run.

## Files

| file | what |
|---|---|
| `compose/replicated.yml`, `compose/single.yml` | the two worlds. Host ports bind 127.0.0.1 only: 18123, 28123 and 38123 (`CH1_PORT`, `CH2_PORT`, `CH_PORT`). |
| `config/` | Keeper, the cluster and macros, and `lagging.xml` (`ch2`'s 2-thread pool, also used by the single node) |
| `sql/` | the two schemas and the deterministic generator |
| `scenario.yml` | the scenario: forms, windows, lag, matrix, the runs |
| `writer.py` | the writer, old and new (standard library only) |
| `rehearse.py` | `generate`, `run`, `verify`, `report` |
| `run.sh` | the box's entry point: every run on a fresh world, the quiesce check, `RESULTS.md` |
| `quiesce-check.sh` | the quiesce/thaw check |
| `tests/` | the runner and the writers against a fake cluster (`python3 -m unittest discover -s tests`) |

## Run it

```sh
cd /tank/work/benchmarks/benchmarks/incident-shapes/clickhouse-replicated
python3 -m unittest discover -s tests            # the fakes; seconds
PARAGLOBE_DIR=/tank/work/paraglobe ./run.sh      # every run + the quiesce check; under an hour
```

`run.sh` needs Docker with Compose v2, `curl`, and a `python3` with PyYAML (`PY=` to choose one).
It brings up and destroys only its own compose projects (`par73`, `par73single`, `par73q`,
`par73r`). Results go to `/tank/work/cache/incident-shapes/clickhouse-replicated/<utc>/`
(`OUT=` to move them), with `RESULTS.md` at the top.
