# FORK-EXPERIMENT-1 — three concurrent forks of the 10M-row baseline

First fork experiment, 2026-09-21, on the box: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu
24.04, Postgres and Kafka data on ZFS (lz4, `ashift=12`). Baseline: the 10M-conversation load from
`data/scale/README.md`, snapshotted as `tank@baseline-10m` (13.2 GB on disk). Branch: **main**.

## Method

| step | how |
|------|-----|
| 1. fork state | `zfs clone` of the five datasets (`pg-gateway`, `pg-conversations`, `pg-assignments`, `pg-billing`, `kafka`) from `tank@baseline-10m` |
| 2. fork config | a generated per-fork Compose override (`mkfork.sh` + `mkfork.py`) that bind-mounts the clones, offsets every published port by N×1000, and renames the networks per project |
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
(`docs/PROBE-10M.md`), now hit on **every create and every assign**, because both handlers re-read the
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
