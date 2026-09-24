# PostHog — the five numbers

Paraglobe onboarded `PostHog/posthog` at `posthog-live-20260907-105219` (the hobby stack: Django,
Celery, Temporal, seven Node consumers, eleven Rust/Go sidecars, Postgres, ClickHouse + ZooKeeper,
Redpanda, Redis, MinIO, SeaweedFS — 38 containers) onto a fork-per-pull-request runtime on one
machine (Ryzen 7 7700, 64 GB, 2×1 TB NVMe). Every number was measured on that box on
2026-09-23 and is traceable to a command in [`benchmarks/posthog.md`](../posthog.md).

- **Onboarding: `git clone` to two running Firecracker forks in 3 h 01 min**, zero changes to
  PostHog's code. 23 of those minutes were PostHog's own first boot (2,618 Django migrations and
  a race in `bin/migrate` that costs a restart); about 55 were three generic runtime defects your
  stack was the first to expose. The adapter is 749 lines plus your hobby file with one `sed`.
- **A fork of a 38-container, 101-million-event PostHog restores in 4.8 seconds** — process
  tree, queues and ClickHouse caches resumed, not restarted — for ~9.5 GB of host memory each.
  Two ran side by side in 19.1 GB. Native idle for *one* instance is 18.8 GiB.
- **What scale exposed was not query latency.** At 101M events trends take 94 ms, a funnel
  311 ms, a persons page 105 ms: your `ORDER BY (team_id, toDate(timestamp), event, …)` reads
  310 of 5,256 granules for a funnel. What it exposed: `capture` **exits 0 six seconds after a
  snapshot restore** (its Kafka-sink monitor calls the frozen window a stall) and `restart:
  on-failure` leaves it down — `/_health` green, no ingestion; an unlicensed instance allows
  **one project** (HTTP 403 past it); and query results are cached with a target hours away.
- **A one-line Python change reaches a fork serving it in 315 s**, of which 252 s is Django
  restarting (`migrate-check` + Unit) — the swap itself is under a minute. A pull request gets a
  verdict against a 101M-event baseline in **421 s (363 of them PostHog restarting Django)**, and a regression that only breaks the
  persons list comes back **naming `persons_list`** with the other checks green.
- **Migrations at full size are cheap in ClickHouse and expensive at boot.** `MATERIALIZE INDEX`
  over 101M rows: 2.5 s, nothing blocked. Your ten async migrations cannot run off cloud by design.
  The 23-minute first boot is what a warm fork never pays again.

**The honest caveat.** For PostHog the conventional alternative is good: ZFS clones of the eight
datasets plus `docker compose up` give a working, isolated PostHog in **234 s** with queries as
fast as the baseline's (84 ms cold / 52 ms warm trends) — for **18.2 GiB of host RAM per copy**
with no ceiling, and cold processes: Celery beat, Temporal workers, consumer offsets and 13 GB of
configured ClickHouse caches all start from nothing. If your pain is "a second PostHog by
lunchtime", a snapshot and `compose up` already solve it. If it is "a production-shaped PostHog
per pull request, twelve at a time, without twelve times 18 GiB and a four-minute boot each",
that is what the fork is for — and at 16 GiB per guest this box carries two of them, not twelve.
