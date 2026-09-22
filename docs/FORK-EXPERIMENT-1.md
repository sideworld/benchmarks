# FORK-EXPERIMENT-1 — three concurrent forks of the 10M-row baseline

> **Paths.** This document was written in a monorepo that has since been split. Paths beginning with
> `../specimen/` or `../snowglobe/` point into the sibling repositories, expected to be checked out
> next to this one (`SPECIMEN_DIR` / `SNOWGLOBE_DIR` in the scripts). Paths without that prefix are in this repo.

First fork experiment, 2026-09-21, on the box: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu
24.04, Postgres and Kafka data on ZFS (lz4, `ashift=12`). Baseline: the 10M-conversation load from
`../specimen/data/scale/README.md`, snapshotted as `tank@baseline-10m` (13.2 GB on disk). Branch: **main**.

## Method

| step | how |
|------|-----|
| 1. fork state | `zfs clone` of the five datasets (`pg-gateway`, `pg-conversations`, `pg-assignments`, `pg-billing`, `kafka`) from `tank@baseline-10m` |
| 2. fork config | a generated per-fork Compose override (`../snowglobe/mkfork.sh` + `../snowglobe/mkfork.py`) that bind-mounts the clones, offsets every published port by N×1000, and renames the networks per project |
| 3. boot | `docker compose -p forkN up --wait` |

`docker-compose.fork1.yml` is committed as an example of the generated override; the others are
generated and git-ignored.

## Results

| measurement | value |
|-------------|-------|
| clone time, all five datasets (13.2 GB referenced) | **0.097 s** |
| space used per clone at creation | 8 KB |
| boot-to-healthy, fork1 (alone) | 43.5 s |
| boot-to-healthy, fork2 (beside fork1) | 43.4 s |
| boot-to-healthy, fork3 (beside fork1 + fork2) | 43.6 s |
| cold boot on empty databases, for comparison | 31.9 s |
| row count verified on the clone | 4,000,202 conversations in `conv_acme` |

Boot time did not move with one or two neighbours running: forks do not contend at this density.

## Memory per fork

From the project cgroup's `memory.current`:

| fork | state | memory |
|------|-------|-------:|
| fork1 | after the API suite and probes | 1,799 MB |
| fork2 | booted | 1,697 MB |
| fork3 | fresh | 1,438 MB |

Per-container breakdown, fork2:

| container | MB | kind |
|-----------|---:|------|
| kafka | 407 | JVM heap |
| idp | 367 | JVM heap |
| assignments-db | 287 | Postgres buffers |
| billing-db | 287 | Postgres buffers |
| gateway | 50 | Node |
| billing | 50 | Python |
| notifications | 48 | Python |
| conversations-db | 38 | Postgres buffers |
| otel-collector | 30 | Go |
| gateway-db | 28 | Postgres buffers |
| frontend | 13 | nginx |
| conversations | 6 | Go |
| assignments | 6 | Go |
| stripe-fake | 2 | Go |
| **sum of containers** | **1,619** | (project cgroup: 1,697) |

About 90% of a fork's memory is JVM heaps and Postgres buffers (1,414 of 1,619 MB) — pages that are
identical across forks of the same baseline. The application code itself is ~175 MB.

ZFS ARC: 17.1 GB with fork1, 17.9 GB with two forks, 18.8 GB with three. `free` counts ARC as used, so
per-fork memory **must be read from cgroups**, not from `free`.

## Copy-on-write deltas

| dataset | at clone | after boot (unquiesced baseline) | after `make test-api` |
|---------|---------:|---------------------------------:|----------------------:|
| pg-assignments | 8 KB | 414 MB | — |
| pg-billing | 8 KB | 387 MB | — |
| pg-conversations | 8 KB | 8.3 MB | 200 MB |
| pg-gateway | 8 KB | 280 KB | — |
| kafka | 8 KB | 1 MB | — |

**Root cause of the boot delta**, from the `assignments-db` log on the fork:

```
database system was not properly shut down; automatic recovery in progress
redo ... 3.44 s            (~183 MB of WAL replayed)
end-of-recovery checkpoint: wrote 32,760 buffers (100%)
```

The snapshot was taken of a running, unquiesced Postgres, so every fork starts with crash recovery:
it replays the WAL and then writes out the whole buffer pool, and copy-on-write turns that into
hundreds of MB of private blocks per fork.

**Conclusion:** the baseline job must `CHECKPOINT` every Postgres (and let Kafka flush) **before**
snapshotting. Expected effect: boot delta in the low MB instead of ~800 MB, and ~10 s less boot time
(43.5 s → close to the 31.9 s cold boot).

## The suite finding

`make test-api` against fork1: **14 pass / 18 fail / 1 skip**. All 18 failures were the same:

```
POST /v1/conversations -> 502  "upstream conversations:8081 unreachable (timeout)"   after 10 s
```

| observation | value |
|-------------|-------|
| single create via curl | 201 in 2.30 s |
| conversations log, `POST /internal/conversations` | 2,294 ms |
| conversations log, `POST /internal/conversations/{id}/assign` | 2,007 ms |
| Postgres slow log, the query below, alone | 1,960–2,000 ms |
| the same query under the suite's concurrency | 9,300 ms |

```sql
SELECT id, conversation_id, author_type, author_id, body, created_at
FROM messages WHERE conversation_id = $1 ORDER BY created_at ASC, id ASC
```

This is the same missing `messages(conversation_id, created_at)` index as probe 3
(`../specimen/docs/PROBE-10M.md`), now hit on **every create and every assign**, because both handlers re-read the
conversation with its messages to build the response. Two seconds alone, nine under concurrency, and
the gateway's 10 s upstream timeout turns it into a 502. On the 200-row seed the same suite passes in
~2 s.

**The full API suite passed at 200 rows and failed 18 of 32 at 4M on the first fork, before any
scenario branch was checked out.**

## Observations / todo

- The Go conversations service emits only the HTTP span, no DB spans. Add `otelpgx` so traces carry
  `db.statement`; the slow query above had to be found in the Postgres slow log instead of the trace.
- Cap the ZFS ARC (`zfs_arc_max`) to reserve RAM for forks; at 17–19 GB it competes with them.
- A Kafka-producing scale mode is needed before Kafka branching can be measured: the 10M baseline has
  no topic history (`kafka_events 0`), so the kafka clone delta of 1 MB says nothing yet.
- `make sessions` tokens expire in 5 minutes: mint right before use, not at the start of a long run.
- Quiesce before snapshot (`CHECKPOINT`, Kafka flush) — see the conclusion above.

## What these numbers mean

- **State forking is solved and free.** 13.2 GB of databases and broker data clone in 0.097 s for 8 KB,
  and three forks boot side by side without slowing each other down.
- **Compute is the cost.** A fork is ~1.5 GB of RAM and ~43 s of boot, almost all of it JVM start-up,
  `depends_on` chains and healthcheck intervals — the same software-bound path as a cold boot.
- **~90% of per-fork memory is shareable pages** (JVM heaps, Postgres buffers, identical across forks).
  A memory-snapshot engine that forks processes the way ZFS forks blocks plausibly brings a fork from
  ~1.5 GB / 43 s to ~200 MB / ~1 s.
- **Worst-case density today is ~25–30 forks per 64 GB box**, with the ARC capped and no page sharing.

---

# Experiment 2: clean snapshot

Same box, same baseline data, same day. Experiment 1 concluded that the ~12 s and ~800 MB each fork
paid at boot came from snapshotting a running Postgres. This experiment tests that by snapshotting
after a clean shutdown.

## Method

| step | how |
|------|-----|
| 1. quiesce | on the baseline project: `docker compose stop gateway-db conversations-db assignments-db billing-db kafka` (clean shutdown: Postgres writes its shutdown checkpoint, Kafka flushes and closes its logs) |
| 2. snapshot | `zfs snapshot -r tank@baseline-10m-clean` |
| 3. resume | restart the stopped services |
| 4. fork | `SNAP=baseline-10m-clean ./mkfork.sh 1` — `../snowglobe/mkfork.sh` now takes `SNAP=<snapshot>` (default `baseline-10m`) to select the clone origin — then `docker compose -p fork1 … up --wait` |

## Results, fork1 from the clean snapshot

| measurement | hot snapshot (`baseline-10m`) | clean snapshot (`baseline-10m-clean`) |
|-------------|------------------------------:|--------------------------------------:|
| boot to healthy | 43.5 s | **31.9 s** (baseline cold boot on empty DBs: 31.9 s) |
| `assignments-db` recovery | redo 3.44 s + end-of-recovery checkpoint of 32,760 buffers (100%) | **zero recovery lines** |
| CoW delta after boot, total | ~800 MB | **~2 MB** (2.9 MB summed, below) |
| fork RAM (`memory.current`) | 1,438–1,697 MB | **941 MB** |

CoW delta after boot, per dataset:

| dataset | hot snapshot | clean snapshot |
|---------|-------------:|---------------:|
| pg-assignments | 414 MB | 384 KB |
| pg-billing | 387 MB | 388 KB |
| pg-conversations | 8.3 MB | 740 KB |
| pg-gateway | 280 KB | 332 KB |
| kafka | 1 MB | 1.1 MB |

Fork RAM, 941 MB:

| container | MB | share |
|-----------|---:|------:|
| kafka | 404 | |
| idp | 360 | |
| **JVMs together** | **764** | **81%** |
| gateway, billing, notifications | ~50 each | |
| everything else (four Postgres, otel-collector, frontend, Go services) | remainder | |

The Postgres containers no longer hold hundreds of MB each: without crash recovery and its full
end-of-recovery checkpoint they never pull the buffer pool in at boot, which is where the ~500–750 MB
difference from experiment 1 went.

## Conclusions

- **The 12 s and ~800 MB attributed to recovery are eliminated by quiescing before the snapshot.** The
  baseline job must stop (or at least `CHECKPOINT`) the stateful services before capture.
- **The engine-less fork cost is 31.9 s / ~2 MB / 941 MB.** The 31.9 s is the software's own boot —
  identical to a cold boot on empty databases, so state adds nothing — and ~80% of the RAM is JVM pages
  identical across forks.
- **The engine's target is therefore roughly ~1 s and ~200 MB per fork**: skip the boot by restoring
  memory, and share the JVM pages.

Note: `VACUUM ANALYZE` was **not** run before this snapshot. A vacuumed `baseline-10m-clean2` follows.

---

# Experiment 3: vacuumed clean snapshot and suite-run delta

## Method

| step | how |
|------|-----|
| 1. vacuum | `VACUUM ANALYZE` on every database of the baseline |
| 2. quiesce | clean stop of the four Postgres services and Kafka, as in experiment 2 |
| 3. snapshot | `zfs snapshot -r tank@baseline-10m-clean2` |
| 4. fork | `SNAP=baseline-10m-clean2 ./mkfork.sh 1`, boot with `docker compose -p fork1 … up --wait` |
| 5. exercise | `GATEWAY=http://localhost:19080 make test-api` against the fork (fork1 publishes the gateway on 18080 + 1×1000) |

## Results, fork1 from `baseline-10m-clean2`

| measurement | value |
|-------------|-------|
| boot to healthy | **31.9 s** |
| RAM idle (`memory.current`) | 935 MB |
| RAM after the suite | 1,509 MB (Postgres buffers warmed) |
| `make test-api` | **23 pass / 9 fail / 1 skip**, shards 18–49 s |
| previous run (unvacuumed hot-snapshot fork, experiment 1) | 14 pass / 18 fail / 1 skip, with 10 s timeouts |

The remaining 9 failures are the create-path scan from experiment 1: `POST /v1/conversations` and
`/assign` re-read the conversation's messages through the missing `messages(conversation_id, created_at)`
index. Vacuuming (visibility map, fresh statistics, no hint-bit writes on first read) halved the
failures but cannot fix a sequential scan of a 3.6 GB heap; the suite that takes ~2 s on the 200-row
seed takes 18–49 s per shard here.

Copy-on-write delta per dataset:

| dataset | after boot | after `make test-api` |
|---------|-----------:|----------------------:|
| kafka | 1.16 MB | 1.73 MB |
| pg-assignments | 376 KB | 976 KB |
| pg-billing | 364 KB | 1.02 MB |
| pg-conversations | 1.10 MB | 12.1 MB |
| pg-gateway | 332 KB | 540 KB |
| **total** | **~3.3 MB** | **~16 MB** |

A full API suite run against a fork of 13.2 GB of state costs ~16 MB of private blocks. On the
unvacuumed hot-snapshot fork of experiment 1 the same suite grew `pg-conversations` alone to 200 MB:
most of that was hint-bit and visibility writes on pages the suite merely *read*, which a vacuumed
baseline has already paid for once, before the snapshot.

## Note: `/dev/shm` and parallel VACUUM

Parallel `VACUUM` failed on `conv_acme` and `assignments` with

```
could not resize shared memory segment … No space left on device
```

That is Docker's default 64 MB `/dev/shm`, not the disk: Postgres allocates its parallel-worker
dynamic shared memory there. Fixed in `docker-compose.yml`: `shm_size: 1g` on the four Postgres
services (set once on the shared `x-postgres` anchor, so the ZFS and per-fork overrides inherit it).
The same limit would bite any parallel query on the 10M baseline, not only VACUUM.

---

# Summary: the engine-less fork

What one fork of the 10M-row baseline (13.2 GB on disk) costs today, with ZFS clones and plain
`docker compose up`, by snapshot quality:

| | exp. 1: hot snapshot | exp. 2: clean stop | exp. 3: vacuumed + clean stop |
|---|---:|---:|---:|
| snapshot | `baseline-10m` | `baseline-10m-clean` | `baseline-10m-clean2` |
| clone, five datasets | 0.097 s, 8 KB each | same | same |
| boot to healthy | 43.5 s | 31.9 s | **31.9 s** |
| crash recovery at boot | redo 3.44 s + 100% checkpoint | none | none |
| CoW delta after boot | ~800 MB | ~2–3 MB | **~3.3 MB** |
| CoW delta after `make test-api` | `pg-conversations` alone 200 MB | — | **~16 MB total** |
| RAM idle | 1,438–1,697 MB | 941 MB | **935 MB** |
| RAM after the suite | 1,799 MB | — | 1,509 MB |
| `make test-api` (pass / fail / skip) | 14 / 18 / 1 | — | 23 / 9 / 1 |

| engine-less fork, best case (exp. 3) | cost | what it is |
|---|---:|---|
| state | 0.097 s, ~3 MB at boot, ~16 MB per suite run | solved and free |
| time | 31.9 s | the software's own boot: JVM start-up, `depends_on` chains, healthcheck intervals — identical to a cold boot on empty databases |
| memory | 935 MB idle, ~1.5 GB warmed | ~80% JVM pages identical across forks; the rest of the growth is Postgres buffers of identical baseline pages |
| engine target | ~1 s, ~200 MB | restore memory instead of booting; share the identical pages |

Baseline job requirements that fell out of the three experiments: `VACUUM ANALYZE`, then a clean stop
(or at minimum `CHECKPOINT` + Kafka flush) of the stateful services, then `zfs snapshot -r`; Postgres
containers need `shm_size` well above Docker's 64 MB default.
