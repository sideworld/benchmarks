# BENCHMARK — evidence ladder and system fork ledger

> **Paths.** This document was written in a monorepo that has since been split. Paths beginning with
> `../specimen/` or `../sideworld/` point into the sibling repositories, expected to be checked out
> next to this one (`SPECIMEN_DIR` / `SIDEWORLD_DIR` in the scripts). Paths without that prefix are in this repo.

What has been shown, on which systems, with which numbers. Every figure below is measured and comes
from a linked document; a `?` is a system not yet attempted and "not measured" is a gap, not a zero.
Box for all measurements: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu 24.04, ZFS (lz4),
Firecracker v1.17.0.

## 1. Evidence ladder

| level | claim | status | evidence |
|---|---|---|---|
| **L1** | Forks the system it was built for | **done** | [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md), [`-2.md`](docs/FORK-EXPERIMENT-2.md), [`-3.md`](docs/FORK-EXPERIMENT-3.md) |
| **L2** | Forks a large foreign microservice architecture with zero application changes | **done** | [`benchmarks/trainticket.md`](benchmarks/trainticket.md) |
| **L3** | Forks a foreign system from a different architectural family | **done** — Mastodon v4.7.2 (Rails monolith + Sidekiq + Node streaming, one 100M-row Postgres, Redis as application state); **and Sentry self-hosted 26.9.0** — 53 containers, six state stores including ClickHouse and Kafka, a Compose project an installer has to make runnable, 50M events restored and serving in 3.0 s | [`benchmarks/mastodon.md`](benchmarks/mastodon.md), [`benchmarks/sentry.md`](benchmarks/sentry.md) |
| **L4** | Forks a company's proprietary system, with their data model and operational weirdness | **next** — requires a design partner | — |
| **L5** | The company keeps using forks without us present | pending | — |

Each level removes one excuse the level below leaves open: L1 could be a system shaped to fit the
tool; L2 could be one architectural family (Compose, JVM microservices, a database per service); L3
could still be open source with a clean deployment; L4 could be us driving it; L5 cannot be any of those.

## 2. System fork ledger

| | **Specimen** (Helpdesk) | **TrainTicket** 0.2.0 | **Mastodon** | **Sentry** self-hosted 26.9.0 |
|---|---|---|---|---|
| **First useful fork** (clone → fork, wall-clock) | n/a — the runtime was built around it; no cold onboarding was measured | **first run 71 min** (clone 05:17 → Compose fork healthy 06:28; 90 min to the first Firecracker fork). **Scripted third run, images purged, zero decisions: 9 m 46 s** to a snapshotted VM, **14 m 42 s** to a changed build serving | **first run 4 h 01 min** (clone 13:16 → Compose fork healthy + isolated 17:17; **4 h 14 min** to the first Firecracker fork). 3 h 11 min of it was the 100M-row load, including a run aborted in its RI-trigger tail; with the bulk-load profile that run left behind, the same onboarding is ~2 h 40 min. Native ready at 12 min. No scripted rerun yet | **first run 3 h 38 min** (clone 23:46 → Firecracker fork serving 02:54). Native ready at **26 min**, Compose fork at 1 h 29 min. Half the elapsed time was the Firecracker path: six defects, seven rootfs builds, six bakes |
| **Total onboarding effort** (hours) | n/a — not separable from building the runtime | **1.9 h** first run (05:17–07:12, continuous) incl. 1.1 h on the data generator; **3.1 h** including the repeat and third runs that turned it into scripts | **4.8 h** of activity in 5.5 h of wall clock (13:16–18:45; the gap is waiting on the generator); no reruns yet | **3.6 h** of activity, continuous (23:46–03:24). No reruns yet |
| **Application changes** | 0 | **0** | **0** | **0** |
| **Persistent technologies** | 4 × PostgreSQL 16 (database-per-tenant and `tenant_id`-column tenancy), Kafka (KRaft) | 24 × MongoDB 4.4, MySQL 5.7, Redis (no volume upstream: stateless) | PostgreSQL 14 (one database; a 108M-row `statuses`), Redis 7 (home feeds and Sidekiq queues — application state, not just cache), local file storage (`public/system`, shared by web and Sidekiq) | PostgreSQL 14 behind pgbouncer, **ClickHouse**, Kafka, Valkey 8 (Redis), **Memcached** (cache only — no volume, nothing to snapshot), SeaweedFS. 53 containers; Snuba, Relay, Symbolicator, celery/cron. First world needing a ClickHouse quiesce |
| **Data scale** | 10,000,000 conversations, 49,868,338 messages, 96.4M rows; 19.17 GB in Postgres, 13.2 GB on ZFS (1.60×) | 1,000,004 orders, 809,242 × 2 payments, 10,002 users, 1,010 trips; 607 MiB on ZFS (1.13×) | 107,947,907 statuses (100M originals + 7.9M reblogs), 49,942,192 notifications, 19,982,123 follows, 22,012,162 favourites, 100M conversations, 3.5M accounts + users; **338M rows**; **89 GB in Postgres, 45.8 GB on ZFS (2.27×)**; five accounts with 3,000,001 followers each | **50,000,404 error events / 20,160 issues** across 8 projects with a power-law skew (checkout 36.8 M, admin 335 k). ClickHouse 23.36 GiB → **2.63 GiB** (8.88×); Postgres 102 MB; 7.2 GB total on ZFS. Generated server-side in **274 s** at 182 k rows/s |
| **Cold ready** | native `compose up --wait` **31.9 s**; microVM cold boot **27.2 s** (baked rootfs, Phase 1 measurement in `../sideworld/vm/README.md`; not re-measured) | native **81.9 s** (68/68 healthy, seeding included); microVM **96.4 s** all 68 healthy (UI answers at 16–22 s) | native **61.9 s** (`up --wait`, 7/7 healthy; 65.6 s to the full probe: streaming OK + a post processed by Sidekiq); microVM **64.3 s** all healthy (web `/health` 40.4 s), full probe confirmed inside the VM | native `compose up --wait` **55.9 s** with state present; **5 m 02 s installer + 55.9 s** from nothing; microVM boot **119 s** unbaked, **56.5 s** baked |
| **Warm fork ready** | **2.4 s** (`t_load` 25 ms) | **5.4 s p50 / 5.5 s p95** steady-state. The first restore of a fresh snapshot is 13–18 s without pre-faulting the memory file through a mapping; 5.5 s with it | **2.434 s p50 / 2.467 s p95** over 10 forks (`t_load` 25 ms); warm restore series p50 2.434 / p95 2.479 s (n = 10). First restore of the fresh snapshot **2.415 s**: pre-faulted through a mapping, there is no cold case | **3.0 s** (`t_load` 30 ms, disks 0.26 s) for 53 containers and six state stores |
| **PR → changed system serving** | — (not measured) | **9.0–10.8 s** (runs 1–2, by hand; 4.8 s of it inside the fork); 7.5 s scripted (`pr-swap.sh`, run 3) | **66.9 s** (`pr-swap.sh`, run 3): 1.7 s build + 2.6 s ship + 3.8 s load/swap, then **58.8 s of Rails booting** in the recreated container; siblings kept serving 4.7.2 | **18.6 s** swap; **33.3 s** for a whole CI run (restore 3.7 s, build 0.8 s, suite 8.6 s) |
| **CI: a PR gets a fork** | baseline **20 of 33 known-failing** (9 always, 11 flaky over 5 runs) — the suite is a fixture suite meeting 10M rows; green PR **41.7 s** end to end, restore 3.1 s; red names `TestOpenAPIContract`. **Live on github.com** | baseline **5/5 stable**; green **2 m 52 s**; red names `search_status` and `search_trips`; a second PR queued 2 m 48 s on the world lock and said so. **Live on github.com** | baseline **5/5 stable**; green **1 m 37 s**, with `instance` answering `4.7.2+pr1` — which is what proves the swapped image is the PR's code. **Live on github.com** | baseline **6/6 stable in 145 s**, gate = the event round trip; green **33.3 s** (restore 3.7 s, swap 18.6 s, suite 8.6 s); red = the app will not start, so no check is named. Green is **live on github.com** (`sideworld/self-hosted` #1, 34.5 s there); the red is runner-sim only, deliberately |
| **PSS per idle fork** | **473 MB** @120 s (6 GiB guest; 449 MB in a 2 GiB guest); marginal fork ~400–500 MB from the third on; 2–5× once the fork does work | **3.0–3.6 GB** @120 s (24 GiB guest); ~5 GB after serving a search | **462 MB** median @120 s (8 GiB guest); 1,206 MB for the first fork alone, 395 MB by the tenth; ~245 MB private per fork; 564–999 MB after a post, its jobs and a timeline | **3,097 / 1,941 / 1,377 MB** for forks 1–3 (16 GiB guest); falls as forks share pages |
| **Concurrent forks reached** | **5+** — five measured (2.3 GB summed idle), not a ceiling; ~100 projected on memory | **6 + source** — stopped by a ≥ 10 GiB host-headroom rule, not by failure (40.4 GB summed PSS); Compose+ZFS path: 2 forks + native | **10 + source** — measurement ended at the target, not at a ceiling: 35 GiB still available (5.6 GB summed PSS), ~35 more idle forks projected on memory. Compose+ZFS path: 1 fork measured beside native (2.1 GB cgroup) | **3** measured, leaving 40.5 GiB free against the 10 GiB floor. `slots.exclusive: true` in CI — the nominal 16 GiB guest, not the measured PSS, is what admission uses |
| **Customer-specific runtime code** | **0 lines** (the runtime's first builder, `../sideworld/vm/build-rootfs.sh` + `../sideworld/vm/guest/`, was written against it and later generalised) | **0 lines** — TrainTicket appears in the runtime in two comments. Adapters live outside the runtime: 704 lines in `benchmarks/trainticket/` plus a 727-line generated Compose override | **0 lines** — Mastodon appears in four comments (`app-snapshot-native.sh`, `app-datasets.sh`, `onboard-generic.sh`). Adapters beside it: 812 lines in 20 files (252 onboard, 225 generate, 335 measure) | **0 lines**. Six generic fixes were needed and all are generic |
| **Generic tooling added** (lines, from git) | **2,781** lines in 33 files: `../sideworld/vm/` + `mkfork.{sh,py}` as of `e5b854b`, the commit before TrainTicket | **+559 / −59** in the same paths (`91d9375^..HEAD`): `build-rootfs-generic.sh` 276, `mkfork-generic.{sh,py}` 102, `guest-generic/` 70, env knobs on 8 `../sideworld/vm/` scripts | **+190 / −1** in `../sideworld/vm/` (`bcc2f6b..HEAD`): the spec-driven runbook layer `onboard-generic.sh` 34, `app.sh` 27, `app-datasets.sh` 26, `app-snapshot-native.sh` 36, `app-zvol.sh` 24, `restore-series.sh` 19, `prefault.py` 13 + `PREFAULT=1` in `snapshot.sh` (+9), `unfork.sh` busy-retry (+2/−1); plus **58** lines of bulk-load profile in `benchmarks/lib/` (RI triggers off, FK validation after) that the specimen's and TrainTicket's generators inherit | **+147 lines** across 6 `vm/` files, plus `vm/check-image-archive.py` (73) and the generic guests' `quiesce`/`thaw` (55) brought into the repo; **179** lines of CI config and suite |
| **Bugs / pathologies exposed at scale** | Missing `messages(conversation_id, created_at)` index: create and assign take 2 s alone, 9.3 s under load, and the API suite that passes at 200 rows **fails 18 of 32 at 4M**; inbox list p95 403 ms, tag filter 905 ms, N+1 99 s per page; `/all` 502 after 10 s; sample migration holds `AccessExclusiveLock` 12.5 min; the probe itself reported that 502 as PASS; parallel VACUUM dies on Docker's 64 MB `/dev/shm`; snapshotting an unquiesced Postgres costs every fork 12 s and ~800 MB | Ticket search is O(trips × orders): 0.14 s on seed data, **104 s at 1M orders** (order stores carry only the `_id` index); seed data is incoherent (dangling orders, payment, stations) and lies about the schema (`seatNumber` that `parseInt` cannot read); seeding is not idempotent (one extra order per boot); `ts-voucher-service` crash-loops until MySQL's first-boot init ends; untagged `mongo`/`mysql` now resolve to versions the drivers cannot speak to; no healthchecks, and `/health` is 403 behind the app's own JWT filter | **Followers page of a 3M-follower account: 354 ms p50 warm, 1.7–3.4 s cold** (4 followers: 14 ms; 1,775: 45 ms) — `ORDER BY follows.id DESC LIMIT 40` with only `(target_account_id, account_id)` indexed walks 17M rows of `follows_pkey` backwards, 2.5 GB of buffers per page; needs `(target_account_id, id)`. Everything else ≤ 181 ms p95 at 100M (home timeline 55 ms, grouped notifications 43 ms p50). Migration on the 108M-row table: naive index **87 s under ShareLock**, `SET NOT NULL` **45 s under AccessExclusive**; safe forms 150 s / 39 s + 0.1 s with nothing blocked | In the runtime: `docker save` of 18 images writing an archive `docker load` cannot use; an image (`vroom`) whose amd64 blob is absent locally and so cannot be baked at all; 44 services with `pull_policy: never` turning one missing image into a total failure; six `external: true` volumes an installer creates; 11 bind-mount sources the guest lacked; **a readiness check that called zero running containers "ready"**. In Sentry: Compose `environment:` silently overrides image `ENV`, so an image-level change can be invisible. In my own generator: groups written without a `metadata` blob made 70 of 100 issues serialize as `null` and turned a 77 ms issues list into 908 ms of exception handling |
| **Equivalent alternative the team would use today** | fixtures (the API-driven `make seed`, 200 conversations) | a conventional shared environment | a database branch (a Neon-style clone; here a ZFS clone of `@md-base`) plus a conventional deploy of the changed image with a fresh Redis and Sidekiq | cloned volumes plus a conventional `docker compose up` — the installer is already idempotent, so this is the natural move |
| **Alternative → equivalent-state time** | **Cannot reach it.** Fixtures: 31.9 s boot + 6.7 s seed gives changed code serving and workers running — but **no production-scale data** (200 rows, where every pathology above is invisible) and **cold caches**. Rebuilding scale per environment instead: 765.9 s load + 31.9 s boot ≈ **13.3 min**, caches still cold; forking that state without the engine (Compose+ZFS): 31.9–43.5 s, caches cold | **Not measured** for a shared environment (deploy time there is the team's pipeline, not ours). A shared environment has the data, warm caches and running workers, but **cannot provide isolation or concurrent changed builds**: one change at a time, and every write lands in everyone's state. A fresh private environment instead: 44 s pull + 81.9 s boot + 97.5 s generator ≈ **3.7 min**, caches cold, and only if the team owns a generator (1.1 h to write here) | **Cannot reach it.** DB clone + fresh deploy: changed code serving at **63.7 s**, the heavy account's home feed warm at **74 s** (two runs, `alt-baseline.sh`) — but no other user's feed, no Sidekiq schedule/retry state, cold `shared_buffers` and page cache, nothing in flight; the fork has all of it 2.4 s after restore and the changed code 67 s later | **55.9 s**, and it is genuinely not bad — Sentry's Postgres is 102 MB and ClickHouse is column-compressed. What it cannot reach: **Kafka consumer offsets** (groups restart and replay or skip), **ClickHouse merge state** (a mid-merge clone makes every fork redo the work), **Redis** (rate-limit counters, digest queue, buffers — empty on a redeploy) and the 7.6 GB image store already unpacked. The fork's advantage is less data volume than the number of moving parts resumed at one instant |

### Row definitions

So that future entries are comparable. When a system cannot supply a number, write "not measured" or
"n/a" with the reason — never a blank and never an estimate.

- **First useful fork** — wall-clock from `git clone` of the *upstream* system to the first fork that
  is healthy by that system's user-level readiness probe and proves isolation with one write. Includes
  reading, debugging, data generation and every failed attempt. Report the first run (a human
  discovering the system) and, separately, the best scripted rerun from a full teardown; say whether
  images were re-pulled and how many decisions the rerun needed.
- **Total onboarding effort** — operator hours of activity, summed from the system's time ledger,
  including reruns done to turn the onboarding into scripts. State whether it equals wall-clock.
- **Application changes** — lines changed in the system's own source, images or upstream deployment
  files. Overrides, env files, init scripts, fakes and data generators are adapters, not application
  changes. Version pins count as fidelity trades and are listed in the system's ledger.
- **Persistent technologies** — every stateful store that had to survive quiesce, snapshot and restore
  (or clone), with versions and counts. Note stores that are stateless in this deployment.
- **Data scale** — row/document counts of the dominant entities, logical size in the stores, and
  on-disk size with compression ratio, at the snapshot the forks are taken from.
- **Cold ready** — a fresh start on the prepared state to *all* services healthy: natively
  (`docker compose up --wait`) and inside the microVM. Not "first port answers".
- **Warm fork ready** — firecracker exec to the first HTTP 200 from the system's front door
  (`t_restore_to_api_response`) for a restore of an existing snapshot, p50 / p95 over ≥ 10 restores.
  Report separately the first restore of a fresh snapshot (cold page cache). Excludes clock
  convergence, which is measured on its own.
- **PR → changed system serving** — from a source change on disk to the changed behaviour being served
  by one fork while its siblings still serve the old one: build, ship, load, swap, first changed response.
- **PSS per idle fork** — `Pss` from `/proc/<firecracker pid>/smaps_rollup` 120 s after that fork's own
  restore, with no requests sent to it; median across forks, with the guest size. Give the figure
  after real work separately. PSS, not RSS and not guest RAM: shared memory-file pages are split
  between the forks that map them.
- **Concurrent forks reached** — forks of one snapshot simultaneously healthy and isolated on the box,
  and what stopped the count: a ceiling, a headroom rule, or simply where measurement ended.
- **Customer-specific runtime code** — lines inside the fork runtime (`../sideworld/vm/`, `mkfork*`) that name or
  branch on a particular system's application. Comments do not count; adapters that live beside the
  system do not count but must be reported with their line count.
- **Generic tooling added** — lines added to the runtime while onboarding that system, from
  `git diff --numstat <commit before>..<commit after> -- vm ../sideworld/mkfork.sh ../sideworld/mkfork.py`; reusable by the next
  system by construction. The first system's entry is the runtime's size when the second began.
- **Bugs / pathologies exposed at scale** — defects of the *application* (or its tooling) that were
  invisible on seed data and appeared at the ledger's data scale, each with its small-scale and
  at-scale number. Runtime bugs belong in the experiment docs' "what broke".
- **Equivalent alternative the team would use today** — what this team would actually reach for,
  without the fork runtime, to try a change against realistic state.
- **Alternative → equivalent-state time** — time for that alternative to reach a state with **the
  changed code serving, caches warm, workers running and production-scale data present**. Mark every
  component the alternative cannot provide at all; if it cannot provide one, the honest entry is
  "cannot reach it" plus the time to the nearest state it can reach.

## How to reproduce

Runtime: [`../sideworld/vm/`](../sideworld/vm/) (start at [`../sideworld/vm/README.md`](../sideworld/vm/README.md)) and `mkfork*.sh`
([`../sideworld/mkfork.sh`](../sideworld/mkfork.sh) for the specimen, [`../sideworld/vm/mkfork-generic.sh`](../sideworld/vm/mkfork-generic.sh) for any
Compose project). Specimen state: `make scale N=10000000` ([`../specimen/data/scale/README.md`](../specimen/data/scale/README.md)),
probes in [`../specimen/docs/PROBE-10M.md`](../specimen/docs/PROBE-10M.md). TrainTicket, end to end from a clean box:
[`benchmarks/trainticket/onboard.sh`](benchmarks/trainticket/onboard.sh), then the two commands it
prints (`vm-fork-measure.sh`, `pr-swap.sh`); everything it uses is in
[`benchmarks/trainticket/`](benchmarks/trainticket/). Mastodon: `../sideworld/vm/onboard-generic.sh benchmarks/mastodon/app.spec`
(the spec-driven runbook: clone → datasets → hooks → up → probe → generate → native snapshot → zvol →
rootfs → bake → boot → VM snapshot), then `benchmarks/mastodon/vm-fork-measure.sh mdbase <k>`,
`../sideworld/vm/app.sh benchmarks/mastodon/app.spec restore-series mdbase 11 10`, `pr-swap.sh <k>`, `alt-baseline.sh up`;
the probes and the migration are `probes.sh` and `migration.sh`.

## Sources

- [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md) — Compose+ZFS forks of the 10M baseline; hot, clean and vacuumed snapshots; the create-path finding
- [`docs/FORK-EXPERIMENT-2.md`](docs/FORK-EXPERIMENT-2.md) — Firecracker snapshot/restore forks, 2.4 s, isolation, what the engine must do
- [`docs/FORK-EXPERIMENT-3.md`](docs/FORK-EXPERIMENT-3.md) — where a fork's memory goes: 473 MB idle, churn is the cost
- [`benchmarks/trainticket.md`](benchmarks/trainticket.md) — TrainTicket ledger: time, adapters, protocol results, repeat and third runs, restore variance
- [`benchmarks/mastodon.md`](benchmarks/mastodon.md) — Mastodon ledger: time, adapters, the 100M-row load and what it taught, probes, migration, Compose and Firecracker forks, PR swap, the alternative baseline
- [`benchmarks/lib/BULK-LOAD.md`](benchmarks/lib/BULK-LOAD.md) — the bulk-load profile every generator follows

## Sentry, in one paragraph

The heaviest world onboarded: 53 containers across Postgres, ClickHouse, Kafka, Valkey, Memcached
and SeaweedFS, with a Compose project that is not runnable from a clean clone because the ordering
and builder constraints live in an installer's shell. Natively ready in 26 minutes and serving 50
million error events; a Firecracker fork restores and serves in **3.0 seconds** for **8 KB** of
disk. Getting there took six defects out of the generic tooling — all of them now fixed in `vm/`,
none of them Sentry-specific — and one defect of my own that made a 77 ms issues list look like
908 ms until it was found. Full ledger: [`benchmarks/sentry.md`](benchmarks/sentry.md).
