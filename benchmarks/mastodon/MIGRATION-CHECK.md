# Migration Check — `mastodon`: statuses: CREATE INDEX (language, id DESC) without CONCURRENTLY, then ALTER COLUMN language SET NOT NULL

Measured on `box` at 20260923T170300Z against a fork of the CI baseline `ci-mastodon` (restored in 3.3 s), under a replayed workload of **10 requests/s** across 4 probes for 60 s before (after a 30 s warm-up that is not counted), throughout, and 60 s after the migration; each request times out at 30 s and a timeout counts as an error. Nothing here is a prediction; it is what this migration did to this database under that load.

| | |
|---|---|
| migration file | `(not in their history: the two shapes strong_migrations refuses, from benchmarks/mastodon/migration.sh)` |
| database | `statuses`: **53 GB**, **107,947,908 rows** (avg row 234 B); database 89 GB |
| duration | **338.8 s** (statements committed one by one) |
| longest lock | **`AccessExclusiveLock` held 39.3 s** on `statuses`, after queueing 126.6 s for it; also `ShareLock` 172.9 s, `AccessShareLock` 172.8 s |
| estimated rewrite | **0 MB** — neither statement rewrites tuples: the index build writes a new index (statuses has 107.9M rows; the (language, id) index is ~2.3 GB measured), SET NOT NULL scans the heap once and writes nothing |

**Statements**

| # | statement | time |
|--:|---|--:|
| 1 | `CREATE INDEX index_statuses_on_language_and_id ON statuses (language, id DESC)` | 172.6 s |
| 2 | `ALTER TABLE statuses ALTER COLUMN language SET NOT NULL` | 165.8 s |

**Workload replay** — 10 rps, p99 per probe (ms), errors = non-2xx or transport

| probe | before | during | after |
|---|--:|--:|--:|
| `public_timeline` | 109 (n=150) | 30182 (788 err / 847) | 934 (n=150) |
| `account_statuses` | 112 (n=150) | 30194 (788 err / 846) | 1003 (n=151) |
| `home_timeline` | 120 (n=150) | 30211 (788 err / 847) | 1062 (n=150) |
| `post_status` | 51 (n=150) | 30196 (798 err / 847) | 1074 (n=150) |

During the migration the sampler saw **15 backends waiting on a lock at peak** (1081 of 1083 samples had any), **max 17 client connections** (baseline windows: 17), waiting lock modes seen: `AccessExclusiveLock`, `AccessShareLock`, `RowExclusiveLock`; longest wait per mode: `AccessExclusiveLock` 126.6 s, `RowExclusiveLock` 338.4 s, `AccessShareLock` 164.2 s.
After the last statement returned, the backlog took **8 s** to drain — the floor of this measurement, i.e. at once (settled = the `public_timeline` probe answering 2xx in under 2 s, five times running).

**Plan changes on the probe queries** (`EXPLAIN (ANALYZE, BUFFERS)`, before → after)

| query | before | after |
|---|---|---|
| `public_timeline` | Index Scan on `statuses_pkey`, 20 rows, hit 0 / read 24, 11.8 ms | Index Scan on `statuses_pkey`, 20 rows, hit 253 / read 15, 0.9 ms |
| `account_statuses` | Index Only Scan on `index_statuses_20190820`, 20 rows, hit 3 / read 6732, 236.9 ms | Index Only Scan on `index_statuses_20190820`, 20 rows, hit 12 / read 7649, 751.8 ms |
| `statuses_by_language` | Index Scan on `statuses_pkey`, 20 rows, hit 24 / read 0, 0.2 ms | Index Only Scan on `index_statuses_on_language_and_id`, 20 rows, hit 11 / read 1, 0.4 ms |

**Smoke, suite `smoke`**

- unmodified fork, for reference (the CI baseline taken 2026-09-22T20:36:11Z, 3 repeats): **0 of 5 tests fail before any migration**; a smoke result below is judged against that set, as CI judges a pull request
- old app, new schema (the running image after the migration): **5 passed, 0 failed of 5** — **0 new** failure(s) against the unmodified fork
- new app, new schema (same image, recreated): **5 passed, 0 failed of 5** — **0 new** failure(s) against the unmodified fork
  - these statements are not from Mastodon's history and ship with no code change; the same v4.7.2 image is recreated for the second smoke

**The safe pattern, same workload** — CREATE INDEX CONCURRENTLY; then CHECK (language IS NOT NULL) NOT VALID, VALIDATE (ShareUpdateExclusive, reads and writes continue), SET NOT NULL (Postgres uses the validated CHECK and skips the scan), drop the helper

| # | statement | time |
|--:|---|--:|
| 1 | `CREATE INDEX CONCURRENTLY index_statuses_on_language_and_id ON statuses (language, id DESC)` | 323.8 s |
| 2 | `ALTER TABLE statuses ADD CONSTRAINT statuses_language_not_null CHECK (language IS NOT NULL) NOT VALID` | 6.4 ms |
| 3 | `ALTER TABLE statuses VALIDATE CONSTRAINT statuses_language_not_null` | 70.8 s |
| 4 | `ALTER TABLE statuses ALTER COLUMN language SET NOT NULL` | 2.7 ms |
| 5 | `ALTER TABLE statuses DROP CONSTRAINT statuses_language_not_null` | 4.5 ms |

Total **395.0 s**; longest lock `ShareUpdateExclusiveLock` held 394.5 s; peak waiting backends 1. p99 during the safe pattern: `public_timeline` 682 ms, `account_statuses` 639 ms, `home_timeline` 551 ms, `post_status` 786 ms.

After the last statement returned, the backlog took **8 s** to drain — the floor of this measurement, i.e. at once (settled = the `public_timeline` probe answering 2xx in under 2 s, five times running).

- Workload: 4 probes round-robin, the home timeline as heavyfollower (5,000 followed), the reads as ordinary local users with three tokens per probe (Mastodon allows 300 requests / 5 min per token), the status post spread over six accounts (300 new statuses per account per 3 hours); one probe writes a status, i.e. an INSERT into the table being altered.
- Run 20260923T142311Z (superseded): three tokens per probe but one posting account; the migration itself measured the same (CREATE INDEX 192.3 s, SET NOT NULL 137.5 s of which 97.8 s queued for the AccessExclusiveLock and 39.7 s holding it; every probe timed out at 30 s throughout), and 139 of the 151 post_status requests in the after window were 429 from the per-account status limit, which the queued posts had exhausted the moment the lock released.
- Run 20260923T140318Z (superseded): one token, unauthenticated public timeline; 429s on a third of the authenticated probes before the migration and on the smoke's followers page after it. The lock and duration numbers of that run were consistent with this one (CREATE INDEX 132.9 s, SET NOT NULL 150.3 s, AccessExclusiveLock 38.3 s).

<sub>Paraglobe Migration Check · run `20260923T170300Z` · fork restore 3.3 s / 4.5 s · every number above is from this run on this box</sub>
