# Sentry self-hosted — onboarding ledger

Written from minute one; every timing is wall clock on the box unless it says otherwise.
Start: **2026-09-22 23:46 UTC**. Time box: 16 hours of activity, with a 4-hour checkpoint on
"natively ready" — if it is not serving by then, stop and write why.

| | |
|---|---|
| repo | `sideworld/self-hosted` (fork of `getsentry/self-hosted`) |
| pinned at | **26.9.0**, released 2026-09-16 — the newest release tag at the time of this run |
| box | Ryzen 7 7700, 64 GB, 2×1 TB NVMe, Ubuntu 24.04; ZFS `tank`, lz4, ashift=12 |
| free at start | 773 GB pool, 44 GB RAM available, no forks or CI runs live |

Why this world: it is the heaviest onboarded so far — roughly 40 containers across Postgres,
Kafka, ClickHouse, Redis and Memcached, with Snuba, Relay, Symbolicator, a celery/cron tier, and
a Compose file that does not exist until an installer generates it. Every one of those is a
first for the generic tooling except Postgres and Redis.

## Log

| when (UTC) | step | outcome |
|---|---|---|
| 23:46 | gate: `/run/fc-*` empty, no firecracker, 0 netns | clear to start |
| 23:47 | pinned tag chosen: 26.9.0 | newest release; 26.8.0 is the fallback if it will not build |

## 1. Inventory (23:47–00:05 UTC)

`sideworld/self-hosted` @ **26.9.0** (`667094a`), a fork of `getsentry/self-hosted`. Cloned in
0.9 s (shallow). The Compose file ships in the repo — what the installer generates is the
*configuration around it*, not the file itself.

### Containers: 53 services, 16 named volumes

| profile | count | what |
|---|--:|---|
| default (`errors-only` path) | 28 | web, nginx, relay, the errors ingest chain, Snuba's errors/outcomes consumers, the state stores, cron |
| `feature-complete` only | 25 | transactions, replays, metrics, profiling, monitors, uptime, feedback, spans, EAP items and their Snuba consumers |

`.env` ships `COMPOSE_PROFILES=feature-complete`, so an unmodified `install.sh` brings up all 53.
Minimum requirements the installer enforces: **14 GB RAM / 4 CPU** for feature-complete, 7 GB / 2
for `errors-only`.

**Images.** Four are built locally by the installer — `sentry-self-hosted-local`,
`sentry-cleanup-self-hosted-local`, `clickhouse-self-hosted-local` and the SeaweedFS variant — the
rest are pulled: `ghcr.io/getsentry/{sentry,snuba,relay,symbolicator,taskbroker,vroom,uptime-checker,launchpad}:26.9.0`,
plus `postgres:14.24-trixie`, `confluentinc/cp-kafka:7.6.13`, `valkey/valkey:8.1.10-alpine`,
`memcached:1.6.45-alpine`, `edoburu/pgbouncer`, `nginx:1.31.5-alpine`, `chrislusf/seaweedfs`.

**State stores:** Postgres 14 (behind pgbouncer), ClickHouse, Kafka, Redis/Valkey, Memcached,
SeaweedFS. Of these only Postgres and Redis are already handled by the generic quiesce —
ClickHouse, Kafka and SeaweedFS are new, and Memcached holds nothing that must survive a snapshot.

### install.sh: 31 sourced steps, 51 lines of its own

Classified by whether they touch a running system:

| kind | steps | note |
|---|---|---|
| **pre-flight / host detection** (7) | `detect-platform`, `dc-detect-version`, `_detect-container-engine`, `check-minimum-requirements`, `check-latest-commit`, `parse-cli`, `error-handling` | `check-latest-commit` phones GitHub; a **sink** |
| **config generation** (9) | `ensure-files-from-examples`, `generate-secret-key`, `ensure-relay-credentials`, `create-docker-volumes`, `geoip`, `setup-js-sdk-assets`, `setup-custom-ca-certificate`, `check-memcached-backend`, `ensure-correct-permissions-profiles-dir` | pure file/volume creation — this is the part that makes the Compose project runnable |
| **image work** (2) | `update-docker-images` (pull), `build-docker-images` (build the four local images) | |
| **runtime one-shots** (8) | `bootstrap-snuba`, `set-up-and-migrate-database` (`sentry upgrade`), `bootstrap-s3-nodestore`, `bootstrap-s3-profiles`, `migrate-seaweedfs-kek`, `migrate-pgbouncer`, `upgrade-postgres`, `upgrade-clickhouse` | these start containers and mutate state; the last four are no-ops on a fresh install |
| **lifecycle** (3) | `turn-things-off`, `cleanup-clickhouse`, `wrap-up` | |

So **roughly half is config generation** (9 of 31 steps, and the ones that matter most for a first
install), a quarter is runtime one-shots that must run once against live containers, and the rest
is host detection and image handling. The practical consequence for the runtime: the Compose
project cannot be brought up from a clean clone without first running the config-generation half,
and `bootstrap-snuba` + `sentry upgrade` are one-shot jobs that have to complete before the stack
is usable — exactly the "one-shot step" gap the generic onboarder does not model.

## 2. Cold attempt with the generic onboarder (23:48–23:52 UTC)

`vm/onboard-generic.sh` against a deliberately minimal spec, to find out where the runbook stops.

```
[+  0s] clone            already present, skipped
[+  0s] datasets         tank/se-{pg,ch,kafka,redis,seaweedfs} created and mounted with the right uids
[+  0s] up --wait        FAILED after 22.4 s
        #26 ERROR: pull access denied ... insufficient_scope
        failed to solve: sentry-self-hosted-local: failed to resolve source metadata
[+ 22s] native snapshot  ran anyway, and snapshotted five empty datasets
```

Three findings, in increasing order of how much they matter.

**(a) The dataset step already handles this world.** `app-datasets.sh` created ClickHouse, Kafka
and SeaweedFS datasets with their uids as readily as Postgres and Redis. Memcached correctly has
no dataset: it has no volume in the Compose file at all, so there is nothing to snapshot — noted
here because "we deliberately did not persist it" is a different statement from "we forgot".

**(b) The Compose project cannot be built from a clean clone, and not for the reason it looks.**
The build contexts *are* in the repo. What is missing is **order**: `sentry-cleanup` builds
`FROM ${BASE_IMAGE}` with `BASE_IMAGE=sentry-self-hosted-local`, which is the image the `web`
service's build produces. `docker compose build` builds services in parallel, so the base does not
exist yet and BuildKit falls back to treating it as a registry reference —
`pull access denied ... insufficient_scope` is Docker Hub refusing an image that was never meant
to come from a registry. `install/build-docker-images.sh` knows this and does two things the
Compose file cannot express: it pins `BUILDX_BUILDER=default` (a `docker-container` builder cannot
see local images at all) and it builds `web` **first**, then every other service one at a time.

This is the "system whose Compose is generated by an installer" gap in its sharpest form. The
Compose file is not generated — it ships in the repo — but it is **not self-sufficient**: an
ordering constraint and a builder constraint live only in the installer's shell.

**(c) A bug in the generic runbook, found by this world and fixed.** The step was

```sh
dc up -d --wait 2>&1 | grep -iE 'unhealthy|error' || true
```

Under `set -o pipefail` the pipeline's status is `grep`'s, and `|| true` discarded even that. A
project that never came up reported nothing, and the runbook walked on to take a native snapshot
of five empty datasets — which it did, and which I destroyed. `vm/onboard-generic.sh` now captures
the status (`up_rc=0; dc up … || up_rc=$?`, because `; up_rc=$?` never runs under `set -e`) and
aborts the run. Every world onboarded before this one came up on the first try, which is why a
silent failure path survived three onboardings.

## 3. Native ready (23:52–00:13 UTC)

### The install

`./install.sh --skip-commit-check --no-report-self-hosted-issues --skip-user-creation --no-user-prompt`
— **5 min 02 s**, clean. Nothing in the upstream tree was edited. Three things were put in place
first, all of which the installer respects because `ensure_file_from_example` only copies when the
target is absent:

| file | why |
|---|---|
| `docker-compose.override.yml` | redirects Postgres, ClickHouse, Kafka, Redis and SeaweedFS onto `/tank/se-*`. Compose auto-loads it, and `install.sh` runs `docker compose` with no `-f`, so the installer picks it up too |
| `sentry/sentry.conf.py` | seeded from the example with `SENTRY_BEACON = False` appended |
| `symbolicator/config.yml` | seeded from the example with `sources: []` |

**Sinks.** The beacon (installation id, version and aggregate counts to sentry.io every 24 h) is
off at the config level, not merely unrouted. `--skip-commit-check` stops the installer polling
GitHub for a newer commit; `--no-report-self-hosted-issues` stops the installer's own error
reporter. Symbolicator's default source list reaches Microsoft, Apple, Electron and NuGet symbol
servers — emptied. Mail needs no sink: self-hosted ships its own `smtp` container and never leaves
the box.

### Serving

| | |
|---|---|
| containers | **53** (feature-complete): 45 with healthchecks, all green; 8 without |
| cold boot, state present | **55.9 s** to 45/45 healthy and `/_health/` 200 |
| from nothing | 5 min 02 s of installer (pull, build, `sentry upgrade`, Snuba bootstrap) **+** the 55.9 s |
| idle RAM | **13.5 GiB** across the 53 containers |
| images | **18** distinct, **12.6 GiB** on disk |
| datasets after install | pg 20 MB, kafka 1.2 MB, ch 1.0 MB, seaweedfs 446 KB, redis 13 KB |

### The readiness proof

`/_health/` alone proves almost nothing on this world — the web tier answers it long before the
ingest chain works. The check that matters is an event arriving as a searchable issue, because it
crosses **Relay → Kafka → Snuba → ClickHouse → web**, which is five of the six state stores and
most of the worker tier.

```
POST /api/1/store/  (X-Sentry-Auth, sentry_key=<project key>)   -> HTTP 200
  {"id":"ba84a8f2299f4aed826966269d23ba5a"}
GET  /api/0/projects/sentry/internal/issues/                    -> INTERNAL-1
  "SideworldReadiness: first event through Relay", events 1
```

**Store → searchable issue: 2.9 s, 2.9 s, 4.0 s** over three runs.

Login, verified through Django's own auth rather than curl (Sentry sets its CSRF cookie `sc`
lazily and the login page is an SPA, so a shell-driven form post is not the shortest honest path):
`authenticate()` ok, `Client.login()` True, `/api/0/organizations/` 200, `/organizations/sentry/issues/` 200.
Token auth works independently — an `ApiToken` drives every API call in this ledger.

One config change was needed that the installer does not make: **`system.url-prefix` is unset by
default**, and with it unset `ProjectKey.dsn_public` renders empty and `CSRF_TRUSTED_ORIGINS` is
bare. Set to `http://127.0.0.1:9000` in `sentry/config.yml`.

## 4. Populate (00:13–00:28 UTC)

### The coherent core, through the app

Eight projects created through Sentry's own models (`checkout`, `payments`, `search`,
`mobile-ios`, `mobile-android`, `batch`, `email`, `admin`), then **400 events posted to Relay's
store endpoint** with a skewed project distribution, four platforms, four releases, two
environments and real tags. Accepted in **0.2 s** (16 threads); every one landed.

The point of this half is that it is produced *by the system*, so every store agrees by
construction. It does:

| project | ClickHouse groups | Postgres groups |
|---|--:|--:|
| checkout | 30 | 30 |
| payments | 28 | 28 |
| search | 26 | 26 |
| … | … | … |

### The data plane

`benchmarks/sentry/scale/gen-errors.sql` writes straight into ClickHouse's `errors_local`, mapped
onto 20,000 synthetic groups created in Postgres first, with the mapping deterministic on both
sides. Skew: events per group is `pow(rand, 3)` over the 20,000 (heavy head, long tail); groups
per project follow 40/22/14/8/6/4/4/2 %, so the hot groups sit in the hot projects; timestamps are
`pow(rand, 2)` over 85 days, recent-weighted and inside the 90-day TTL.

**50,000,404 rows in 274 s** — ten batches of 4.99M, 25–29 s each, ~182,000 rows/s. Not the hours
the brief budgeted, because the generator runs server-side: no rows cross a network.

| | events | groups |
|---|--:|--:|
| checkout | 36,844,183 | 8,000 |
| payments | 5,792,902 | 4,400 |
| search | 2,994,455 | 2,800 |
| mobile-ios | 1,546,169 | 1,600 |
| mobile-android | 1,098,529 | 1,200 |
| batch | 705,306 | 800 |
| email | 683,184 | 800 |
| admin | 335,272 | 400 |

`times_seen`, `first_seen` and `last_seen` were then reconciled into `sentry_groupedmessage` from
ClickHouse aggregates (**1.0 s** for 20,000 groups). The two stores agree exactly, per project, on
both group count and event count — the table above is the same numbers read from each.

### Sizes

| | |
|---|---|
| `errors_local` | 50.0 M rows, **23.36 GiB** uncompressed → **2.63 GiB** compressed (**8.88×**) |
| `tank/se-ch` | 7.11 G used, ZFS compressratio **1.16×** |
| `tank/se-pg` | 102 M, 2.82× · `se-kafka` 4.79 M, 5.58× · `se-seaweedfs` 1.22 M · `se-redis` 148 K |

ZFS adds almost nothing on top of ClickHouse (1.16×) because the data arrives already compressed —
worth knowing before sizing a pool for this world, and the opposite of the Postgres worlds where
`lz4` earns 2.8×.

**One honest limit of the generator.** Synthetic events exist in ClickHouse only; they have no
nodestore blob, because that is written by the ingest consumer, not by an `INSERT`. Issue lists,
search, counts and stats are therefore fully exercised at 50 M, but *opening one synthetic event*
has no body to render. The event-detail probe uses a Relay-ingested event for that reason. Closing
the gap would mean writing 50 M blobs into SeaweedFS, which buys nothing the issue-level probes do
not already show.

## 5. Probes at full volume (00:28–01:25 UTC)

> **This section was rewritten.** The first run of these probes produced numbers that were an
> artefact of a defect in my own generator, and the conclusion I drew from them was wrong. Both
> the wrong numbers and the correction are kept below, because the mistake is the interesting part.

### The defect

The generator wrote `sentry_groupedmessage` rows directly with `data = '{}'`. Sentry's
`Group.title` calls `get_event_metadata()`, which does `self.data['metadata']` — so **every
synthetic group raised `KeyError: 'metadata'` when serialized**. The issues endpoint caught it per
group and returned `null` in its place:

```
entries=100  null=70  hydrated=30
hydrated ids: min=11 max=121   synthetic (>=100000)=0
GET /api/0/issues/100001/  ->  HTTP 500
sentry_grouphash rows: synthetic=0, ingested=160
```

So not one of the 20,000 synthetic groups could be rendered. Worse, each `KeyError` produced a
full traceback *and* an attempt by Sentry's own SDK to report itself to itself, which 403'd on
CSRF and logged the entire HTML error page. The list endpoint was spending its time on exception
handling, not on data.

Fixed by giving each synthetic group the blob Sentry's ingest would have written — a `metadata`
dict with `type` and `value`, plus a `sentry_grouphash` row — through the ORM so the field is
encoded the way the model expects. 20,000 groups in **4.0 s**. Afterwards: `null=0`,
`hydrated=100`, 70 of them synthetic, `GET /api/0/issues/100001/` → 200, and the hot group renders
as `SyntheticError0: upstream timed out` with **1,842,270 events**.

### The numbers, after the fix

`benchmarks/sentry/probes.sh`, five runs each, through the public API with a token.

| probe | p50 | p95 | before the fix (p50) |
|---|--:|--:|--:|
| issues list, 14 d (checkout, 36.8 M events) | **77 ms** | 78 ms | *908 ms* |
| issues list, all time | 53 ms | 112 ms | *878 ms* |
| issues sorted by frequency | 97 ms | 286 ms | *1,457 ms* |
| search by tag (`customer_tier:enterprise`) | 115 ms | 442 ms | *1,325 ms* |
| search by release | 114 ms | 290 ms | *1,153 ms* |
| issues list, cold project (admin, 335 k events) | 72 ms | 301 ms | *1,132 ms* |
| project stats 24 h | 26 ms | 32 ms | 25 ms |
| org `stats_v2` 14 d | 26 ms | 33 ms | 32 ms |
| tag values, `customer_tier` | 40 ms | 579 ms | 43 ms |

The responses also got **bigger** — 41 KB → 121 KB for the 14-day list — because they now carry
100 real issues instead of 30 and 70 nulls. Faster and more data.

### What I wrongly concluded, and what is actually true

From the first run I wrote that "roughly 6 % of the request is ClickHouse and the rest is Sentry's
own request path", and that a fork of this world is mainly a way to profile Python. That was
**wrong**, and the tell was in the data the whole time: the *cold* project, with 110× fewer
events, was as slow as the hot one. I read that as evidence of a fixed per-request cost. It was
evidence of a fixed per-request *bug* — 70 exceptions per page regardless of project size.

Measured against the stores directly (these figures did not change):

| layer | time |
|---|--:|
| ClickHouse group rollup, hot project (36.8 M rows) | 57 ms |
| ClickHouse group rollup, cold project (335 k rows) | 5 ms |
| ClickHouse tag search, hot project | 252 ms |
| Postgres hydrate 100 groups by id (`EXPLAIN ANALYZE`) | 0.5 ms, index scan, all buffers hit |
| the API call around them, **now** | **77 ms** |

So the honest picture is the ordinary one: **ClickHouse is the dominant cost of an issues list at
50 M events**, Postgres is free, and Sentry's own layer adds tens of milliseconds. The tag search
at 115 ms sits close to its 252 ms ClickHouse floor measured cold, and the gap is the page cache.

`system.query_log` is disabled in self-hosted's ClickHouse config, so the per-query figures come
from running the equivalent queries directly rather than from the log.

## 6. A migration at full volume (00:34–00:38 UTC)

Two of them, because this world keeps its scale in a different place than every world before it.

### Django, against Sentry's own history

`sentry django migrate sentry 1172` then back to `1173_dashboardhiddenuser` — a real migration from
Sentry's tree, unapplied and re-applied against the populated database.

| | |
|---|--:|
| unapply `1173` (+ a dependent `seer` migration) | **38.3 s** |
| re-apply `1173` | **21.0 s** |
| `AccessExclusiveLock` samples on `sentry_*` during the window (250 ms polling) | **0** |

Nothing blocked, and most of that wall time is Django's own bootstrap — Sentry takes roughly
twenty seconds to import before it executes any SQL. The reason there is no lock to find is
structural: **Sentry's Postgres is small.** The largest table here is `sentry_groupedmessage` at
**39 MB / 20,160 rows**. Fifty million events do not live in Postgres; Postgres holds the issue
*metadata* and the event stream lives in ClickHouse. A specimen-style "naive migration holds an
exclusive lock for twelve minutes" simply has no table to happen on.

### ClickHouse, which is where the rows are

The migration that matters for this world is the shape Snuba's own migrations take — add a column
to `errors_local`, then materialise it across every part.

| step | 50.0 M rows, 88 parts |
|---|--:|
| `ALTER TABLE … ADD COLUMN` | **0.124 s** — metadata only |
| `ALTER TABLE … MATERIALIZE COLUMN` | **4.4 s** |
| `ALTER TABLE … DROP COLUMN` | 5.2 s |
| table readable and correct throughout | 50,000,404 rows / 20,160 groups, unchanged |

ClickHouse mutations are asynchronous and per-part: the table never stops serving, and the cost
scales with parts rather than with a single exclusive section. **The comparison worth drawing is
not that ClickHouse is faster than Postgres — it is that the dangerous migration on this world
would be a Postgres one, and Postgres here is 39 MB.** A fork buys you the freedom to try a Snuba
migration against fifty million real rows in five seconds; it does not rescue you from a lock,
because there is no lock to be rescued from.

## 7. Fork paths (00:38–02:56 UTC)

### Compose fork on ZFS

`benchmarks/sentry/fork.sh up <k>` clones the five datasets from `@se-base` and brings up a second
Compose project on its own port. It works, and a fork costs **4.5 MB**:

| dataset | used by the fork | refers |
|---|--:|--:|
| `se-f1-ch` | 1.07 MB | 2.43 GB |
| `se-f1-pg` | 1.08 MB | 110 MB |
| `se-f1-kafka` | 1.63 MB | 5.16 MB |
| `se-f1-seaweedfs` | 560 KB | 1.25 MB |
| `se-f1-redis` | 120 KB | 152 KB |

Isolation holds: an event posted to the fork became issue `IsolationProbe6052` there and never
appeared in the baseline.

Two things cost time and are worth writing down because neither is Sentry's fault:

- **Compose merges `ports:` by appending.** An override adding `"9100:80"` leaves the inherited
  `"9000:80"` in place, so the fork's nginx tried to publish a port the baseline already owned and
  sat in `Created` forever. The fix is to interpolate the variable the upstream file already uses
  (`SENTRY_BIND`) rather than override the list.
- **nginx resolves its upstreams at config load and hard-fails.** `host not found in upstream
  "relay:3000"` if relay is not up yet — and it then crash-loops rather than retrying. Bringing it
  up after the rest settles is enough.

### Firecracker

This is where the generic tooling had the most to learn. The rootfs built and **six separate
defects** had to be fixed before 53 containers would come up inside a microVM. Each is in the
runtime now, and each was found by this world and would have bitten the next one:

| # | what broke | fix |
|---|---|---|
| 1 | one `docker save` of 18 images wrote a shared blob store; `docker load` died at image 8 on a blob the archive did not contain, with the tar intact and `tar -t` clean | save each image into its own archive (`vm/build-rootfs-generic.sh`); the guest loader untars and loads them one at a time and names the one that fails |
| 2 | that only narrowed it: `ghcr.io/getsentry/vroom:26.9.0` genuinely cannot be exported — its **amd64 config blob is absent from the local store**, before and after a fresh `docker pull --platform linux/amd64` | `vm/check-image-archive.py` verifies each archive contains the host platform's manifest, config and layers, and the builder excludes what it cannot export. My first version of this check was far too strict and excluded 15 of 18 — referencing *sibling* platforms is normal |
| 3 | excluding an image made it worse: 44 of Sentry's services carry `pull_policy: never`, so compose failed the whole `up` with `No such image` | the builder emits `pull_policy: missing` into `docker-compose.vm.yml` for exactly the services whose image it could not bake. The guest pulls that one image at first boot; a fork restored later already has it |
| 4 | `external volume "sentry-data" not found` — Sentry's installer pre-creates six named volumes as *external*, and nothing in the guest did | `app-up` creates any volume the compose file declares `external: true` and that is absent. Idempotent, and it never touches a volume the project does not declare |
| 5 | `runc create failed: stat /etc/sentry/entrypoint.sh: no such file or directory` — the guest had none of the 11 host paths the compose file bind-mounts | the builder derives them from `docker compose config` and copies each with its relative path. `vm/build-rootfs.sh` had learned this for the specimen ("picking them out one by one would only create a way for the next added mount to be missed"); this is that lesson made generic |
| 6 | a failed `up` reported **`ready 64.62s after boot`** with zero containers running: the fallback counted *unhealthy* containers, and zero containers are trivially zero unhealthy | `app-up` requires that something is running before it believes the health count, and refuses to report ready otherwise |

Defect 6 is the one worth dwelling on. It is the same class as the CI bug from the previous
session — a check that cannot fail because it is asking the wrong question — and it hid defects 3
and 5 for two bake cycles by insisting everything was fine.

#### What it measures, once it works

| | |
|---|--:|
| rootfs | 40 GiB provisioned, **9,320 MiB used** after bake, 3.4 GB on disk; image store 7.6 GB in the guest |
| images baked | 17 of 18 (vroom pulled at first boot) |
| boot to `/_health/`, unbaked | 119.0 s |
| boot to `/_health/`, **baked** | **56.5 s** — the bake is worth 62 s |
| guest self-report (all 53 containers) | 124.3 s unbaked |
| snapshot frozen window | **5.82 s** — pause 0.006 s, create 5.32 s, zfs 0.033 s, **root-disk snapshot 0.014 s** |
| memory file | 16,384 MiB apparent, **5,667 MiB allocated**; pre-fault 46.2 s |

The 14-millisecond root-disk snapshot is the "clone, never copy" work from the previous session
arriving on a new world for free: a 40 GiB root disk enters a snapshot in the time it takes to
name it, where the old path would have copied it inside the frozen window.

#### Forks

| fork | disks | restore → first 200 | PSS |
|---|--:|--:|--:|
| 1 | 0.258 s | **3.035 s** | 3,097 MB |
| 2 | 0.267 s | 2.959 s | 1,941 MB |
| 3 | 0.268 s | 3.053 s | 1,377 MB |

**A 53-container Sentry carrying 50 million events, restored and serving in three seconds.** PSS
falls as forks are added, as on every other world — the second and third share most of the first's
pages. Disk cost per fork: **8 KB** until it is written to; fork 1 grew to 5.3 MB after being used.

Isolation on the microVM path: an event posted to fork 1 became a searchable issue *in fork 1*,
which also proves Relay → Kafka → Snuba → ClickHouse → web runs inside a restored fork, not just
the web tier.

**Headroom.** Three forks up left **40.5 GiB available** against the 10 GiB floor, with 18.8 GiB of
firecracker RSS in total. Measured PSS says a dozen would fit; the nominal 16 GiB guest says one at
a time. The admission rule in `ops/ci-entry.sh` uses the nominal figure and `slots.exclusive: true`
is set for this world, which is the conservative reading and the right one for a box that also
serves demos.

## 8. Alternative-baseline row

What a ZFS clone plus a conventional deploy can and cannot reach, measured on this box.

| | Firecracker fork | Compose fork on ZFS | cold conventional deploy |
|---|--:|--:|--:|
| to `/_health/` 200 | **3.0 s** | ~4 min (52 containers, nginx retry) | **55.9 s** with state present |
| from nothing | — | — | 5 min 02 s installer **+** 55.9 s |
| to a warm issues list at 50 M events | **3.0 s** (the snapshot carries it) | same as its boot | 55.9 s, then first query cold |
| host cost | 1.4–3.1 GB PSS | a second 13.5 GiB container set | 13.5 GiB |
| disk cost | **8 KB** until written | 4.5 MB | the whole dataset |
| isolation | own kernel, own netns, own ports | own project, own clones, own port | none — it *is* the installation |

**What the alternative cannot reach.** A database-branch-plus-redeploy story gets you Postgres and
ClickHouse at a point in time. It does not get you:

- **Kafka's log position.** The consumers resume where the snapshot left them. A cold deploy
  against cloned volumes restarts consumer groups and replays or skips.
- **ClickHouse's merge state.** The snapshot is taken with merges stopped and flushed, so a fork
  opens on settled parts. A clone taken mid-merge makes every fork redo that work.
- **Redis.** Sentry keeps rate-limit counters, the digest queue and buffer state there. A fork has
  them; a redeploy starts empty and behaves differently for the first minutes.
- **Memcached.** Nothing to carry — it holds only cache. Recorded because "we chose not to" is a
  different statement from "we forgot".
- **The cron/celery tier's in-flight state**, and the 7.6 GB image store already unpacked.

The honest counterpoint: the conventional deploy's 55.9 s is *not bad*, because Sentry's Postgres
is small and its ClickHouse is column-compressed. The fork's advantage here is less about data
volume than about **the number of moving parts that have to agree** — 53 containers and six state
stores, all resumed at one instant.

## 9. CI (02:56–03:12 UTC)

`ops/ci/sentry.yml`, `ops/ci/suites/sentry-smoke.sh`, `ops/ci/workflows/sentry.yml`.

**The PR shape, stated honestly.** `sideworld/self-hosted` is deployment configuration, not
application code. A pull request there changes how Sentry is deployed, and this pipeline verifies
that by rebuilding the images the installer builds locally and swapping them into a fork. **Testing
a change to Sentry itself would mean building `getsentry/sentry`'s image** — a multi-minute Python
and asset build from a different repository — **which is out of scope for this pass.**

**Baseline**: built in **145 s** (snapshot 123 s, then two suite runs of 10.5 s and 7.5 s).
**6 of 6 checks pass, stable across both runs, nothing flaky** — including the event round trip
through Relay → Kafka → Snuba → ClickHouse. That is a far better baseline than the specimen's
20-of-33 failures, because this world's suite asks about endpoints rather than about a fixture
suite's assumptions.

| PR | change | result |
|---|---|---|
| #1 `ci/pr-1-marker` | a build marker in `sentry/Dockerfile` | 🟢 **6/6, 33.3 s total** — restore 3.7 s, swap 18.6 s, suite 8.6 s |
| #2 `ci/pr-2-break-web` | appends `raise RuntimeError` to Sentry's base settings module | 🔴 the fork never came back healthy after the swap |

Two findings from getting the red one to be red:

- **The first attempt was neutralised by the Compose file.** Setting `SENTRY_CONF` to a
  non-existent path in the image had no effect, because `docker-compose.yml` sets `SENTRY_CONF` in
  `environment:` and Compose's environment beats image `ENV`. The image genuinely carried the
  change — `docker image inspect` confirmed it — and the run was correctly green. A deployment
  world can override its own images, and a CI that only swaps images will not see such a change.
- **The red reports as "the run did not complete", not as named failing checks**, because a web
  container that will not start means the suite never runs. That is honest but weaker than naming
  a check. The message now says the build succeeded and the failure is attributable to the change
  rather than to the box, which is the most the pipeline can say without guessing.

**A limitation to be explicit about:** the swap ships *images*. A pull request that changes a
bind-mounted file — `nginx.conf`, `redis.conf`, `relay/config.yml`, `sentry/sentry.conf.py` — is
**not** tested by this pipeline, because the fork keeps the copy baked into its rootfs. For a
repository that is mostly deployment configuration that is a real gap, and the fix is to ship
changed bind-mount sources into the fork alongside the images. It is not done.

## 10. Where the time went, and what is not done

Start 2026-09-22 23:46 UTC, end 2026-09-23 03:24 UTC — **3 h 38 min**, against a 16 h box and a
4 h checkpoint on "natively ready" that was met at **26 minutes**.

| | |
|---|--:|
| inventory | 19 min |
| install + native ready (incl. the event round trip) | 21 min |
| populate: 400 real events, 20,000 groups, 50 M rows, reconcile | 15 min |
| probes, the null-serialization defect, re-probe | 57 min |
| migrations (Django + ClickHouse) | 5 min |
| settle + `@se-base` | 8 min |
| Compose fork, the ports and nginx traps, isolation | 42 min |
| **Firecracker: six defects, seven rootfs builds, six bakes** | **80 min** |
| VM snapshot, three forks, PSS, isolation | 7 min |
| CI: config, suite, baseline, green and red PRs | 27 min |

The Firecracker path was **half the elapsed time and all of the difficulty**, and every minute of
it produced a fix that is now in the runtime rather than in this document.

### Unsupported or not done — named, not dropped

| | status |
|---|---|
| `ghcr.io/getsentry/vroom:26.9.0` | **cannot be baked.** Its amd64 config blob is absent from the local store before and after a fresh `docker pull --platform linux/amd64`, so `docker save` writes an archive `docker load` cannot use. The guest pulls it at first boot instead; a restored fork already has it. If the box were offline this world would come up 52/53 |
| event bodies for synthetic events | **not populated.** 50 M events exist in ClickHouse with no nodestore blob, because the blob is written by the ingest consumer, not by an `INSERT`. Issue lists, search, counts, tags and stats are fully exercised; opening one *synthetic* event has no body to render. The event-detail path was checked with a Relay-ingested event |
| PR swap for a bind-mounted config file | **not covered.** The swap ships images; a fork keeps the config baked into its rootfs. Named as a gap in §9 |
| testing a change to `getsentry/sentry` itself | **out of scope for this pass**, as the brief allowed. It needs that repository's image build |
| PSS series beyond three forks | **not run.** Three were measured (3,097 / 1,941 / 1,377 MB). The headroom rule and `slots.exclusive: true` make more than one concurrent CI fork of this world a deliberate choice rather than a default |
| a second red PR naming a failing check | **not produced.** The red that exists stops the app from starting, so the suite never runs. A check-level red would need a change that degrades one endpoint while leaving web healthy |

### What this world taught the runtime

Six fixes, all generic, all in `vm/`:

1. per-image `docker save`, because one archive for many images can be internally inconsistent
2. `vm/check-image-archive.py`, which verifies the host platform's manifest, config and layers
3. `pull_policy: missing` for images that cannot be baked, so one bad image does not fail the `up`
4. `app-up` creates the volumes a project declares `external: true`
5. the builder copies **every bind-mount source** the compose file names, derived not listed
6. `app-up` refuses to call zero running containers "ready"

and two that are Sentry-shaped but generic in form: ClickHouse quiesce (`SYSTEM STOP MERGES` +
`FLUSH LOGS`, and `START MERGES` on thaw), and the recognition that memcached has no state to
carry. The `quiesce`, `thaw` and `post-restore` scripts for the generic guests were also brought
into the repository, having existed only inside the built images.

**The single most useful number:** a 53-container Sentry carrying 50 million events restores and
serves in **3.0 seconds** for **8 KB** of disk and **1.4–3.1 GB** of RAM, against a 55.9 s
conventional restart that reaches a less complete system.
