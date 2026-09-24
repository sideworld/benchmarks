# Migration Check — `mattermost`: 000102_posts_originalid_index — CREATE INDEX idx_posts_original_id ON Posts(originalid), not CONCURRENTLY

Measured on `box` at 20260923T190335Z against a fork of the CI baseline `ci-mattermost` (restored in 4.5 s), under a replayed workload of **10 requests/s** across 4 probes for 60 s before (after a 30 s warm-up that is not counted), throughout, and 60 s after the migration; each request times out at 30 s and a timeout counts as an error. Nothing here is a prediction; it is what this migration did to this database under that load.

| | |
|---|---|
| migration file | `server/channels/db/migrations/postgres/000102_posts_originalid_index.up.sql` |
| database | `posts`: **11 GB**, **19,999,064 rows** (avg row 225 B); database 14 GB |
| duration | **8.2 s** (statements committed one by one) |
| longest lock | **`ShareLock` held 8.4 s** on `posts`; also `AccessShareLock` 2.1 s |
| estimated rewrite | **138 MB** — an index build writes a new index, not the heap: 132 MB measured for this index on 20M rows |
| table after | **11 GB** (was 11 GB), 0 dead tuples awaiting vacuum |

**Statements**

| # | statement | time |
|--:|---|--:|
| 1 | `CREATE INDEX IF NOT EXISTS idx_posts_original_id ON Posts(originalid)` | 7.9 s |

**Workload replay** — 10 rps, p99 per probe (ms), errors = non-2xx or transport

| probe | before | during | after |
|---|--:|--:|--:|
| `history_page1` | 8 (n=150) | 9 (n=20) | 8 (n=150) |
| `history_deep` | 281 (n=150) | 378 (n=21) | 308 (n=150) |
| `search` | 77 (n=150) | 151 (n=21) | 87 (n=150) |
| `post_message` | 18 (n=150) | 7578 (n=20) | 20 (n=150) |

During the migration the sampler saw **19 backends waiting on a lock at peak** (23 of 26 samples had any), **max 24 client connections** (baseline windows: 24), waiting lock modes seen: `RowExclusiveLock`; longest wait per mode: `RowExclusiveLock` 7.5 s.
After the last statement returned, the backlog took **8 s** to drain — the floor of this measurement, i.e. at once (settled = the `history_page1` probe answering 2xx in under 1000 ms, 3x its own median before the migration, five times running).

**Plan changes on the probe queries** (`EXPLAIN (ANALYZE, BUFFERS)`, before → after)

| query | before | after |
|---|---|---|
| `channel_history_page1` | Index Scan on `idx_posts_channel_id_delete_at_create_at`, 60 rows, hit 9 / read 181, 11.8 ms | Index Scan on `idx_posts_channel_id_delete_at_create_at`, 60 rows, hit 233 / read 0, 0.7 ms |
| `posts_by_original_id` | Seq Scan, 0 rows, hit 36 / read 594042, 9.9 s | Index Scan on `idx_posts_original_id`, 0 rows, hit 1 / read 2, 0.1 ms |
| `search_deployment` | Index Scan on `idx_posts_create_at`, 20 rows, hit 6 / read 194, 4.8 ms | Index Scan on `idx_posts_create_at`, 20 rows, hit 522 / read 0, 1.9 ms |

**Smoke, suite `smoke`**

- unmodified fork, for reference (the CI baseline taken 2026-09-23T05:30:54Z, 2 repeats): **0 of 7 tests fail before any migration**; a smoke result below is judged against that set, as CI judges a pull request
- old app, new schema (the running image after the migration): **7 passed, 0 failed of 7** — **0 new** failure(s) against the unmodified fork
- new app, new schema (same image, recreated): **7 passed, 0 failed of 7** — **0 new** failure(s) against the unmodified fork
  - a migration from their own history; the v11.11.0 image already matches the schema and is recreated for the second smoke

**The safe pattern, same workload** — CREATE INDEX CONCURRENTLY: ShareUpdateExclusive only, writes continue

| # | statement | time |
|--:|---|--:|
| 1 | `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_posts_original_id ON Posts(originalid)` | 14.4 s |


Table after the safe pattern: **11 GB** (was 11 GB), 0 dead tuples.
Total **14.7 s**; longest lock `ShareUpdateExclusiveLock` held 14.5 s; peak waiting backends 0. p99 during the safe pattern: `history_page1` 16 ms, `history_deep` 456 ms, `search` 176 ms, `post_message` 18 ms.

After the last statement returned, the backlog took **8 s** to drain — the floor of this measurement, i.e. at once (settled = the `history_page1` probe answering 2xx in under 1000 ms, 3x its own median before the migration, five times running).

- Workload: 4 probes round-robin as the admin; one of them writes a post into the busiest channel, i.e. an INSERT into Posts while the index builds.

<sub>Paraglobe Migration Check · run `20260923T190335Z` · fork restore 4.5 s / 4.1 s · every number above is from this run on this box</sub>
