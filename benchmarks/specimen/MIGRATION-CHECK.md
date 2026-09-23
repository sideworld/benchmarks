# Migration Check — `specimen`: scenario B — add messages.sentiment (NOT NULL, backfilled, indexed), one transaction

Measured on `box` at 20260923T213345Z against a fork of the CI baseline `ci-specimen` (restored in 3.3 s), under a replayed workload of **1 requests/s** across 4 probes for 60 s before (after a 30 s warm-up that is not counted), throughout, and 60 s after the migration; each request times out at 30 s and a timeout counts as an error. Nothing here is a prediction; it is what this migration did to this database under that load.

| | |
|---|---|
| migration file | `services/conversations/migrations/tenant/0011_messages_sentiment.sql` |
| database | `messages`: **4917 MB**, **19,936,865 rows** (avg row 189 B); database 6192 MB |
| duration | **600.3 s** (one transaction) |
| longest lock | **`AccessExclusiveLock` held 599.3 s** on `messages`, after queueing 1.1 s for it; also `ShareLock` 23.0 s, `ExclusiveLock` 0.6 s, `RowExclusiveLock` 599.3 s, `AccessShareLock` 1.1 s |
| estimated rewrite | **4.25 GB** — every message row gets a new tuple version (UPDATE of a NOT NULL DEFAULT column added in the same transaction), plus one index entry each |
| table after | **9084 MB** (was 4917 MB), 19,935,304 dead tuples awaiting vacuum |

**Statements**

| # | statement | time |
|--:|---|--:|
| 1 | `ALTER TABLE messages ADD COLUMN sentiment text NOT NULL DEFAULT 'neutral'` | 944.7 ms |
| 2 | `UPDATE messages SET sentiment = CASE WHEN body ILIKE '%thank%' OR body ILIKE '%resolved%' OR body ILIKE '%grea…` | 576.1 s |
| 3 | `CREATE INDEX messages_sentiment_idx ON messages (sentiment)` | 23.0 s |

**Workload replay** — 1 rps, p99 per probe (ms), errors = non-2xx or transport

| probe | before | during | after |
|---|--:|--:|--:|
| `list_open` | 782 (n=15) | 7510 (n=150) | 6158 (n=16) |
| `list_tag_vip` | 1798 (n=15) | 8151 (n=150) | 10005 (1 err / 15) |
| `conversation_get` | 2552 (n=15) | 11018 (150 err / 150) | 13622 (12 err / 15) |
| `post_message` | 36 (n=15) | 10568 (147 err / 150) | 2605 (n=15) |

During the migration the sampler saw **4 backends waiting on a lock at peak** (1900 of 1906 samples had any), **max 8 client connections** (baseline windows: 8), waiting lock modes seen: `AccessExclusiveLock`, `AccessShareLock`, `RowExclusiveLock`; longest wait per mode: `AccessExclusiveLock` 1.1 s, `RowExclusiveLock` 115.7 s, `AccessShareLock` 235.7 s.
After the last statement returned, the backlog took **31 s** to drain (settled = the `conversation_get` probe answering 2xx in under 6312 ms, 3x its own median before the migration, five times running).

**Plan changes on the probe queries** (`EXPLAIN (ANALYZE, BUFFERS)`, before → after)

| query | before | after |
|---|---|---|
| `messages_by_conversation` | Seq Scan, 2 rows, hit 128 / read 474764, 3.7 s | Seq Scan, 2 rows, hit 21546 / read 952760, 5.1 s |
| `latest_message` | Seq Scan, 2 rows, hit 224 / read 474668, 662.5 ms | Seq Scan, 2 rows, hit 21642 / read 952664, 4.4 s |
| `list_open_page1` | Limit, 50 rows, hit 268 / read 65502, 808.1 ms | Limit, 50 rows, hit 2211 / read 63559, 669.5 ms |

**Smoke, suite `api`**

- unmodified fork, for reference (the CI baseline taken 2026-09-22T20:31:40Z, 5 repeats): **20 of 33 tests fail before any migration**, 9 of them every time; a smoke result below is judged against that set, as CI judges a pull request
- old app, new schema (the running image after the migration): **16 passed, 16 failed of 33** — **0 new** failure(s) against the unmodified fork; 4 of the known failures passed this time; 16 known failures still failing; the suite's own words: 16× `POST /v1/conversations: expected 201, got 502`
- new app, new schema (`sideworld-mc/specimen/conversations:scenario-b`) — the recreated service had **not answered a round trip 1802 s** after the swap (last code 401); the smoke ran against it anyway: **14 passed, 18 failed of 33** — **0 new** failure(s) against the unmodified fork; 2 of the known failures passed this time; 18 known failures still failing; the suite's own words: 17× `POST /v1/conversations: expected 201, got 502`; 1× `GET unknown conversation: expected 404, got 502`
  - what its migrator logged while the harness waited:
    - `"msg":"meta migrations applied","service":"conversations","applied":0,"migration_ms":18}`
    - `{"ts":"2026-09-23T21:48:24.056279304Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"acme","database":"conv_acme","applied":0,"migration_ms":11,"ok":true}`
    - `{"ts":"2026-09-23T21:48:24.090028524Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"globex","database":"conv_globex","applied":1,"migration_ms":32,"ok":true}`
    - `{"ts":"2026-09-23T21:51:52.713001953Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"scale02","database":"conv_scale02","applied":1,"migration_ms":208622,"ok":tr`
    - `{"ts":"2026-09-23T21:53:49.016519257Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"scale03","database":"conv_scale03","applied":1,"migration_ms":116299,"ok":tr`
    - `{"ts":"2026-09-23T21:55:05.20313194Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"scale04","database":"conv_scale04","applied":1,"migration_ms":76183,"ok":true`
    - `{"ts":"2026-09-23T21:56:06.944049933Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"scale05","database":"conv_scale05","applied":1,"migration_ms":61739,"ok":tru`
    - `{"ts":"2026-09-23T21:56:07.008577522Z","level":"info","msg":"tenant migrate-forward","service":"conversations","tenant_id":"t-47dc9c26","database":"conv_t_47dc9c26","applied":1,"migration_ms":61,"ok":`
  - the new image's own migrator (goose) found 0011 recorded as applied for acme (applied=0) and applied it to every other tenant before listening: the fork has six tenant databases (acme 7.0 GB, scale02 3.2 GB, scale03 2.3 GB, scale04 1.8 GB, scale05 1.5 GB, globex 8 MB) and the hand-run migration plus its bookkeeping covered one of them

**The safe pattern, same workload** — column with a DEFAULT (metadata-only since PG11; new rows get it), backfill by ctid page range (4096 pages ~ 170k rows per batch, committed per batch; ids are uuids so there is no integer key to walk), CHECK NOT VALID + VALIDATE, SET NOT NULL, CREATE INDEX CONCURRENTLY

| # | statement | time |
|--:|---|--:|
| 1 | `ALTER TABLE messages ADD COLUMN sentiment text DEFAULT 'neutral'` | 818.3 ms |
| 2 | `DO $$ DECLARE lo bigint := 0; npages bigint; step bigint := 4096; BEGIN SELECT pg_relation_size('messages') / …` | 4389.4 s |
| 3 | `ALTER TABLE messages ADD CONSTRAINT messages_sentiment_not_null CHECK (sentiment IS NOT NULL) NOT VALID` | 5.4 s |
| 4 | `ALTER TABLE messages VALIDATE CONSTRAINT messages_sentiment_not_null` | 8.7 s |
| 5 | `ALTER TABLE messages ALTER COLUMN sentiment SET NOT NULL` | 5.8 s |
| 6 | `ALTER TABLE messages DROP CONSTRAINT messages_sentiment_not_null` | 6.3 s |
| 7 | `CREATE INDEX CONCURRENTLY messages_sentiment_idx ON messages (sentiment)` | 47.7 s |


Table after the safe pattern: **8955 MB** (was 4917 MB), 19,949,077 dead tuples.
Total **4464.4 s**; longest lock `ExclusiveLock` held 0.8 s; peak waiting backends 4. p99 during the safe pattern: `list_open` 3441 ms, `list_tag_vip` 6461 ms, `conversation_get` 10020 ms, `post_message` 1248 ms.

After the last statement returned, the backlog took **33 s** to drain (settled = the `conversation_get` probe answering 2xx in under 6446 ms, 3x its own median before the migration, five times running).

- Workload: 4 probes round-robin through the gateway as tenant-agent on tenant acme; one of them writes a message into the conversation the migration is rewriting. 1 rps, because the conversations service holds 4 connections per tenant and its list queries take 1-3.5 s at 10M conversations: at 10 rps the pool is full before any migration.
- Run 20260923T144327Z (superseded): 10 rps, one 300 s token. Every read probe was a gateway 502 (upstream 10 s timeout) from the warm-up on, the token expired 276 s in and the rest was 401; the smoke after the migration failed 17 of 33 on the same 502s, i.e. on the backlog, not the schema. Its safe pattern also failed at once: min(uuid) does not exist, the batched backfill had assumed an integer key. Measured all the same: the naive migration took 597.6 s (UPDATE 578.5 s, CREATE INDEX 18.7 s) and messages_by_conversation went from 3.6 s to 14.4 s afterwards.
- Run 20260923T150714Z (superseded, same numbers: naive 604.8 s, safe 4455.8 s): the readiness check before the new-image smoke was made with an expired token, so that smoke began while the recreated service was still coming up and three tests failed on 'fetch failed' rather than on anything the migration did.
- The smoke's failures are all gateway 502s on writes (POST /v1/conversations: expected 201, got 502): the upstream took longer than the gateway's 10 s. The CI baseline records 20 of these 33 tests failing on an unmodified fork at this scale, and the plans table shows why the migration makes it worse: the two queries on messages read twice the pages afterwards (the rewrite left 19.9M dead tuples) and went from 1.8 s and 0.6 s to 4.5 s and 4.8 s. The schema itself is compatible with both images.
- The new image's own migrator (goose) found 0011 recorded as applied for tenant acme (applied=0) and applied it to the other tenant, globex (applied=1): that is what shipping the file does to every tenant the hand-run migration did not touch.
- Resolved (runs 20260923T172353Z, 191051Z, 193238Z had it as an unexplained new failure): on the new image every test that reaches conversations failed with 'upstream unreachable (fetch failed)', a connect failure, while the same tests on the old image failed only by the gateway's timeout. Reproduced on a fresh fork with the swap alone: the recreated container stays 'health: starting' and refuses connections while its migrator runs 0011 against the tenants the hand-run migration never touched. The fork has six tenant databases; recording 0011 as applied for acme left scale02-05 (8.7 GB of messages between them) to be rewritten at start-up, with the service not listening until the last one finished. TestSuperadminCreatesTenant was simply the test whose one-minute retry loop made the outage visible. The report now measures how long the new image takes to answer a round trip, and shows what its migrator logged meanwhile.
- Run 20260923T213345Z (superseded for one number): the first pass to wait for the recreated service and log its migrator per tenant. The round trip reported 401 for its whole 1802 s because the harness's own 300 s token expired during the wait (fixed: it re-mints while waiting); the migrator's timestamps in that same report put the service up 470 s after the swap (21:48:17 to 21:56:07: scale02 208.6 s, scale03 116.3 s, scale04 76.2 s, scale05 61.7 s). The smoke that followed, against the service once up, had 0 new failures against the unmodified fork.
- The safe pattern under the same 1 rps: 74 minutes against 10, and nothing failed. Its backfill batches wait on disk (DataFileRead) behind the probes' own full scans of messages, which the naive form had simply blocked; and it leaves the same 19.9M dead tuples for vacuum, because every row still gets a new version.

<sub>Sideworld Migration Check · run `20260923T213345Z` · fork restore 3.3 s / 3.1 s · the safe pattern's numbers are from run `20260923T172353Z`, same baseline, same workload; everything else is from this run on this box</sub>
