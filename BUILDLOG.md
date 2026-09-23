# BUILDLOG (benchmarks)

What was hard, per world, from the evidence side: the generators, the probes, the adapters, and
the mistakes made writing them. The runtime's own log is `../sideworld/docs/BUILDLOG.md`. Earlier
worlds' equivalents live inside their ledgers (`benchmarks/<world>.md`, "where the time went");
this file starts with PostHog.

## PostHog — 100M events into a schema that was built for them (2026-09-23)

Ledger: `benchmarks/posthog.md`. Adapter: `benchmarks/posthog/` (749 lines + their hobby file
with one `sed`). Zero application changes.

**The generator.** Persons first, in Postgres under the bulk-load profile (2M persons + 2M distinct
ids, 41 s, 0 orphans on three FK pairs), then *copied* into ClickHouse rather than recomputed —
Postgres has no `cityHash64`, so the Postgres table is the one source and ClickHouse gets a
`COPY … | INSERT FORMAT CSV`. Events server-side in ClickHouse, 10M per batch, 94,800 rows/s;
`OPTIMIZE FINAL` 167 s. Inserting into `sharded_events` triggered PostHog's own materialized
views exactly as ingestion does: one table written, three produced (`sharded_events_recent`,
`sharded_sessions`). Four ClickHouse facts the dry runs paid for: `offset` is a reserved word and
cannot be a parameter name (the error says `CANNOT_PARSE_QUOTED_STRING`, which is misleading);
`DateTime` parameters arrive as quoted literals — pass an epoch; a `CROSS JOIN` on `numbers()`
needs an alias; and the CSV reader rejects Postgres's `+00` suffix. Two mistakes kept: the
recency skew came out backwards (`u^0.6` crowds the *old* end), and 50,000 persons per project is
too few for 23.6M events, so funnels convert everyone. Both recorded, neither reloaded.

**The probes found no query pathology, and the ledger says so.** Trends 94 ms, funnel 311 ms
(2.49M rows read, 310 of 5,256 granules after partition + primary-key pruning), persons 105 ms,
property filter 229 ms at 101M events. `ORDER BY (team_id, toDate(timestamp), event, …)` is the
product-analytics query written as a sort key. PostHog's costs are elsewhere: 23.5 minutes of
first boot (2,618 Django migrations plus a race in their own `bin/migrate`), 18.8 GiB idle, and a
`capture` service that exits 0 six seconds after a snapshot restore.

**Three readiness lessons in one world.** (1) With email pointed at a sink, the first login is
gated on a 6-digit code PostHog mails out; the probe reads it from the sink and submits it, so the
gate is a real SMTP round trip. (2) Query results are cached with a target hours away: a poll that
reads the cache never sees the row it waits for — `refresh=force_blocking` on every readiness and
isolation query. (3) `/_health` was green on forks that had no ingestion; only the round trip saw
it. And the CSRF cookie is `posthog_csrftoken`, not `csrftoken`; a script reading the wrong name
gets every write refused.

**The migration replays were the opposite of Mattermost's.** Django `1342` back and forward:
17 s each, all `manage.py` startup, DDL on an empty table — the recent Django migrations do not
touch what gets large. ClickHouse `0293` (`ADD INDEX` + `MATERIALIZE INDEX` on 101M rows): 0.2 s +
**2.5 s**, no reader or writer blocked, 361 MiB of index — a mutation is a background rewrite, not a
lock. The async framework cannot run off cloud, by their design.

**The alternative is good and the ledger leads with it.** ZFS branches + `compose up`: 234 s to a
working PostHog, 84/52 ms trends, isolation correct, 85 MB delta — for 18.2 GiB of host RAM per
branch and a first failure mode (a duplicate YAML key I wrote) that started nothing and waited
twenty minutes.

