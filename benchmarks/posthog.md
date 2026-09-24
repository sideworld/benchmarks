# PostHog — onboarding ledger

Written as it happened. Start **2026-09-23T06:03:43Z**. Box: Ryzen 7 7700, 64 GB, ZFS `tank` (693 G free),
Firecracker 1.17. Time box: 16 h of activity; a 4 h checkpoint on "natively ready".

## 0. The previous attempt

**There is no record of one on this box.** Checked before anything else was written:
`/tank/work/posthog*` (absent), every `tank/*` dataset and snapshot (no `ph-`/`posthog`),
`vm/out/` (nothing), `benchmarks/` (nothing), every ledger and doc in both repos (no mention),
both repos' full git history including all branches (no commit, no path), Docker images,
containers and volumes (none), `/tank/work/cache` (nothing), shell histories, and this session
family's scratchpads. Whatever stopped an earlier PostHog attempt, if there was one, it left no
artefact here. This ledger starts from zero.

At the start: no Firecracker VMs live, no CI or demo run, 35 containers running (the Mastodon
baseline and the specimen's `fork1`; read-only), 44 GiB RAM available.

## 1. Clone and inventory

**Pin: `posthog-live-20260907-105219` = `e04da21b9b1233dbc7db5fbe659c417eb3423c7e`**, 2026-09-07.
PostHog has not cut a version-shaped release since `1.43.1` on 2023-05-17 (three years); the
product is continuously deployed from `master`, GitHub's "latest release" is a desktop-app tag, and
`bin/deploy-hobby` itself warns *"PostHog don't create tagged releases anymore"*. Their own current
release marker is the `posthog-live-*` tag family; the dated one is immutable, its floating twin
`posthog-live-latest` is not. Docker Hub publishes `posthog/posthog:<full-sha>` for every master
commit, so **the exact pinned commit has an exact image** (`61143c07cef9…`, 2,773 MB). Shallow
clone: **13.2 s**, 553 MB.

**The image pairing the hobby stack ships is not one commit.** `docker-compose.hobby.yml` runs the
Django/Celery services from `posthog/posthog:$POSTHOG_APP_TAG` but the Node plugin-server from
`posthog/posthog-node:latest`, and that tag was last pushed **2026-03-31** (revision `82ea6681`),
six months behind the web image it ingests for. The nine Rust sidecars come from
`ghcr.io/posthog/posthog/<name>:master`, floating tags rebuilt on every push, with no sha-shaped
tag for this commit. So "PostHog at e04da21b" is, honestly: Django at e04da21b, plugin-server at
82ea6681, Rust services at whatever `master` was on 2026-09-23 06:12 UTC (digests recorded in
the pull table below). This is what a hobby install gets; recorded, not corrected.

### The system, from `docker-compose.hobby.yml` + `docker-compose.base.yml`

**38 services** (37 theirs + the `maildev` sink this adapter adds), 27 distinct images, **8.0 GB**
pulled cold in **128.5 s**:

| tier | services | language / image |
|---|---|---|
| app | `web` (Django + frontend), `worker` (Celery + beat), `temporal-django-worker`, `asyncmigrationscheck` (0 replicas) | Python — `posthog/posthog:e04da21b…` 2,773 MB |
| ingestion | `plugins`, `ingestion-general`, `ingestion-sessionreplay`, `ingestion-error-tracking`, `ingestion-logs`, `ingestion-traces`, `recording-api` | Node — `posthog/posthog-node:latest` (2026-03-31) 525 MB |
| edge / rust | `capture`, `capture-logs`, `replay-capture`, `property-defs-rs`, `feature-flags`, `hypercache-server`, `personhog-replica`, `personhog-router`, `cymbal`, `cymbal-resolution`, `livestream` (Go) | `ghcr.io/posthog/posthog/*:master` |
| state | `db` Postgres 15.12, `clickhouse` 26.6.2, `zookeeper` 3.7, `kafka` = **Redpanda** v25.1.9, `redis7`, `valkey` (cache only), `objectstorage` MinIO, `seaweedfs` 4.29, `elasticsearch` 7.17 | |
| workflow | `temporal` (auto-setup 1.26.2), `temporal-admin-tools`, `temporal-ui` | store: **Postgres `db`** (`DB=postgres12`, `POSTGRES_SEEDS=db`); `ENABLE_ES=false`, so `elasticsearch` runs and holds nothing |
| other | `proxy` Caddy (80/443), `browserless` Chromium 1,033 MB, `kafka-init` (one-shot topic creation) | |

**State stores → datasets** (`tank/ph-*`): Postgres (`ph-pg` — also Temporal's store, `cyclotron`,
`persons`, `behavioral_cohorts` and five other databases created by `docker/postgres-init-scripts`),
ClickHouse (`ph-ch`), **ZooKeeper `/data` and `/datalog` (`ph-zk`, `ph-zklog`)** — ClickHouse's
`config.xml` names a `<zookeeper>` and five table definitions are `Replicated*MergeTree`, so the
coordination state is part of the database and a ClickHouse snapshot without it is not
restorable —, Redpanda (`ph-kafka`), Redis (`ph-redis`), MinIO (`ph-minio`), SeaweedFS
(`ph-seaweedfs`; session-recording blobs). Not datasets: Valkey (`allkeys-lru`, no volume),
Elasticsearch (empty by configuration), Caddy (TLS state; we serve plain http).

**A trap in the hobby file itself.** Its `kafka` service adds `kafka-data:/bitnami/kafka` — a
Bitnami-Kafka-era path — on top of the base file's `redpanda-data:/var/lib/redpanda/data`, which is
where Redpanda actually writes. Compose keeps both mounts. A dataset aimed at the hobby path would
snapshot an empty directory and every fork would start with an empty broker. Bound by target
(`/var/lib/redpanda/data`) in the override.

**One-shot jobs.** `web`'s command is `/compose/start` — a file the *installer* generates:
`compose/wait` (poll ClickHouse:9000 and db:5432), `bin/migrate` (Django `migrate` with retries,
and `migrate_clickhouse` + `sync_replicated_schema` in parallel), then `bin/docker-server`. There
are **1,243 + 61 + 1,314 Django migrations** (posthog, ee, products/*; the last is
`1342_drop_cimd_blocklist_table`), **319 ClickHouse migrations** (last `0313_logs_pattern_buckets`),
and **10 async migrations** (`0001_events_sample_by` … `0010_move_old_partitions`) that the
`asyncmigrationscheck` service verifies at 0 replicas. `kafka-init` pre-creates 17 topics; Postgres
init scripts create 9 databases; Temporal's `auto-setup` creates its two schemas in Postgres.

**Scheduled work.** Celery beat: **76 periodic tasks** in `posthog/tasks/scheduled.py`, among them
`send instance usage report`, `send delayed org usage reports`, `send llm analytics usage reports`
(all outbound), cache warming, flag metrics, matview digests. Temporal: schedules under
`posthog/temporal/*/schedule.py` (alerts, session-replay scoring sweeps, AI checkpoint compaction,
MCP intent clustering) on queues `main`, `batch-exports-task-queue`, `data-warehouse-task-queue`,
`data-modeling-task-queue`.

**Outbound, at runtime** (string mentions are ~1,400; these are the ones that fire):

| what | to | switch |
|---|---|---|
| the in-app `posthoganalytics` SDK (`posthog/apps.py`, key `sTMFPsFhdP1Ssg`) | `us.i.posthog.com` | `OPT_OUT_CAPTURE=true` → `posthoganalytics.disabled` |
| usage reports (three beat tasks, `PostHogClient("sTMFPsFhdP1Ssg")`) | `us.posthog.com` | same SDK switch |
| license activate / deactivate | `license.posthog.com` | only on an explicit admin action; never fires here |
| GeoIP database, at install | `mmdbcdn.posthog.net` (brotli, 63 MB) | fetched once, then a bind mount |
| installer telemetry (`magic_curl_install_start/complete`) | `us.i.posthog.com/batch/` | the installer is not run |
| email | `EMAIL_HOST` default `""` = silently dropped | pointed at the base file's `maildev` sink |
| AI providers | Anthropic / OpenAI | blank keys, forced blank in the override |
| TLS | Let's Encrypt via Caddy | `TLS_BLOCK` empty; plain http on `127.0.0.1:8100` |

## 2. `app.spec`: what a drafter could infer, and what needed a decision

| field | inferable? | how |
|---|---|---|
| `APP_REPO`, `APP_DIR`, `PROJECT`, `SPEC_DIR`, `SNAPSHOT_NAME` | **yes** | boilerplate |
| `APP_TAG` | **no** | there is no release. Choosing the dated `posthog-live-*` tag over `latest`/`master`, and knowing the image for it exists as `posthog/posthog:<sha>`, took reading the installer and Docker Hub |
| `COMPOSE_FILES` | **no** | their hobby file cannot be used as-is from the checkout (§3, stop 3). Deriving it with one `sed` and putting everything else in an override is a judgement about what "their system definition" means |
| `ENV_FILE` | **partly** | *that* a `.env` is required is obvious from the first failure; *what* goes in it is in `bin/deploy-hobby` and nowhere else |
| `EXTRA_COPY` | **no** | `docker-compose.base.yml` (the `extends` target), `.env.services` (an `env_file`), `compose/` and `share/` (generated by the installer, never committed) all have to reach the guest. None is a bind the rootfs builder would find on its own |
| `DATASETS` | **partly** | eight of nine stateful services are inferable from `volumes:`. That ZooKeeper is *part of ClickHouse's database* (replicated tables), that Temporal's store is *inside Postgres*, that Redpanda's real path is the base file's not the hobby file's, and that Elasticsearch is running-but-empty (`ENABLE_ES=false`) are four things a drafter would get wrong |
| `PROBE` | **no** | the round trip through capture → Kafka → plugin-server → ClickHouse → HogQL is a policy |
| `GEN`, `GEN_ARGS` | **no** | domain knowledge (§5) |
| `GUEST_HTTP=8000`, `HEALTH_PATH=/_health` | **yes** | Caddy's default upstream, and the installer's own wait loop |
| `ZVOL_SIZE`, `SIZE_MB` | **yes** | measured: 8.0 GB of images cold, 100 M events to size for |
| `MEM_MIB=16384`, `VCPUS=8` | **no** | the brief's starting point; corrected by measurement (§6) |

Again: **the addressing is inferable, the modelling is not** — and here the modelling includes
the installer, because PostHog's Compose file is only half of its deployment. The other half is a
shell script that writes `.env`, generates `compose/start`, downloads GeoIP, and assumes a
directory layout.

## 3. `onboard-generic.sh` cold — three stops

A deliberately minimal spec pointed straight at their `docker-compose.hobby.yml`, nothing else.

**Stop 1, 0.3 s:** `unable to get image '-node:latest': Error response from daemon: invalid
reference format`. Every `${REGISTRY_URL}`, `$POSTHOG_APP_TAG`, `$DOMAIN`, `$POSTHOG_SECRET`,
`$ENCRYPTION_SALT_KEYS` is empty without the `.env` the installer writes; the plugin-server's image
name collapses to `-node:latest`. **Not a generic gap**: a Compose file that requires an
installer-generated env is a property of this project. Fix: `compose/hobby.env`, byte-for-byte
what `bin/deploy-hobby` writes (with throwaway secrets).

**Stop 2, 1.5 s:** `pull access denied for minio/minio, repository does not exist`. Hobby pins
`minio/minio:RELEASE.2025-04-22T22-12-26Z`; **`docker.io/minio/minio` lists zero tags** — the
third world in a row (Mattermost yesterday, PostHog today) and the same fix, a registry redirect
to `quay.io`, same digest family. A clean `bin/deploy-hobby` on a fresh machine fails at this line
today. Not generic; recorded as the recurring class it is.

**Stop 3, 70.0 s** (36 containers created, 17 up): the ClickHouse container failed at
`runc create`:

```
error mounting "/tank/work/posthog/posthog/docker/clickhouse/config.xml" to rootfs at
"/etc/clickhouse-server/config.xml": not a directory: Are you trying to mount a directory onto a file
```

Their hobby file binds `./posthog/docker/clickhouse/config.xml` — the installer's layout, where the
checkout is a *subdirectory* of the project directory. Resolved against the checkout itself that
path lands inside the Django package (`posthog/posthog/`), Docker auto-created an empty
*directory* at the file's name, and the bind then failed. Docker had by then created eleven
phantom directories inside the source tree (`posthog/posthog/docker/…`, `posthog/posthog/idl`,
`posthog/posthog/user_scripts`), which had to be removed by hand. In the same stop, `livestream`
and `feature-flags` were crash-looping: **both refuse to start without the GeoIP database**
(`mmdb.path must be set`; `geoip init failed`) that the installer downloads from
`mmdbcdn.posthog.net`. The plugin-server, by contrast, logs a warning and disables lookups.

Is `PROJECT_DIR` (added for Mattermost) the fix? No — it would make the hobby file's paths resolve,
but then the *base* file's `./docker/…` paths (which the hobby file `extends`) would not: the two
files disagree about where the project directory is, and only the installer's copy-and-symlink
dance reconciles them. **Not a generic gap.** The world-specific answer is
`compose/docker-compose.hobby.paraglobe.yml` — their file with `./posthog/` folded to `./`,
regenerable with one `sed`, and `check-upstream.sh` proves it equals that `sed` of the pinned
original — plus `compose/`, `share/` and `.env.services` in the checkout (git-excluded locally,
exactly the artefacts the installer would have produced).

**What the generic runbook could not have known, in one line:** PostHog's deployment is an
installer *and* a Compose file, and the Compose file is not runnable without the installer's
side effects.

## 4. Native ready

`docker compose up -d --wait` returned after **18 s** with 36 of 38 services "Up" — and nothing
was ready. Most of these services carry no healthcheck (Compose's `--wait` waits for the ones that
do), and `web` had just entered `/compose/start`: `bin/migrate`, then the server. The installer's
own wait loop is honest about this — *"~5-10 minutes for things to settle down, migrations to
finish"* — and polls `/_health` for up to ten minutes. `/_health` answers **503** ("Migrations are
not up to date") until every Django migration is applied; Caddy answers **502** until Django binds
at all.

**A first-boot race in `bin/migrate`.** It runs `migrate_clickhouse` *in parallel* with Django's
`migrate` (a background subshell, joined at the end). ClickHouse migration
`0026_fix_materialized_window_and_session_ids` calls `materialize()`, which reads the Django table
`posthog_instancesetting` — and on a fresh database that table does not exist yet, because the
Django side is still somewhere around its 300th migration of 2,618:

```
File "/code/posthog/clickhouse/migrations/0026_fix_materialized_window_and_session_ids.py", line 51, in materialize_session_and_window_id
django.db.utils.ProgrammingError: relation "posthog_instancesetting" does not exist
```

The ClickHouse side dies at 0026 of 319; the Django side keeps going. When it finishes,
`bin/migrate` reads the ClickHouse status file, exits 1, and — because the base file gives `web`
`restart: on-failure` — the container restarts, Django finds nothing to do, ClickHouse resumes from
0026 with the table now present, and the server starts. It self-heals, on the second pass, at the
price of one extra migration run. On a hobby install this is invisible: the installer's ten-minute
loop just takes longer. It is not invisible here, because the point is to know what "ready" costs.

### The first boot, measured

| | |
|---|--:|
| `up -d --wait` returns (36 of 38 "Up", nothing ready) | 18 s |
| Django `migrate`, first pass: **2,618 migrations** (06:17:41 → 06:32:22) | **14 min 41 s** |
| `bin/migrate` exits 1 (the ClickHouse race), `web` restarts | 06:36:41 |
| ClickHouse migrations 0026 → 0313, second pass (06:36:39 → 06:38:34) | **1 min 55 s** |
| NGINX Unit up, `/_health` first **200** (06:40:16) | **1,411 s after `up`** — **23.5 min** |
| **the round trip**: log in → `POST /capture/` → Caddy → Rust `capture` → Redpanda → Node `ingestion-general` → ClickHouse → HogQL | **3.80 s** (3.11 s of it ingestion latency) |
| natively ready, wall clock from the ledger's first line | **43 min** (06:03 → 06:46) |

**Idle RAM, native, before any load: 18.8 GiB across 36 running containers.** The Celery worker
alone is **8.36 GiB** (`docker stats`): `--with-scheduler` starts `celery beat` (982 MB) plus a
prefork pool sized to the host's 16 threads, each fork ~0.9 GB RSS of the Django import graph;
`web` is 3.8 GiB; the Temporal Django worker 1.0 GiB; ClickHouse 1.0 GiB; Elasticsearch 690 MB for
holding nothing (`ENABLE_ES=false`). The brief's 16 GiB guest is below the native idle footprint;
§6 measures what the guest actually needs. Datasets after first boot: ClickHouse 167 MB (the
schema, 319 migrations' worth), Postgres 68 MB, the rest under 2 MB.

**Two things the round trip found that `/_health` cannot.**

- **Login is gated on email verification** the moment email works. The override points
  `EMAIL_HOST` at the base file's `maildev` sink so mail is not silently dropped — and with
  `EMAIL_ENABLED` true, the first login answers `401 verify_email_pending` until the 6-digit code
  PostHog mailed out is submitted to `POST /api/users/verify_email/`. `probe.sh` reads the code
  out of the sink's API (`/email`) and submits it, which is a real round trip through SMTP and the
  most honest readiness check in this document: an instance whose mail path is broken cannot be
  logged into.
- **PostHog caches query results, and a poll that reads the cache never sees the row it is
  waiting for.** The first HogQL poll ran before ingestion had landed the event, returned `0`, and
  was cached with a `cache_target_age` **six hours** away; every later poll returned the cached
  zero while the row sat in ClickHouse (`events rows: 1`, checked directly). The event had arrived
  in ~3 s. The fix is `"refresh": "force_blocking"` on any query used as a readiness signal, now in
  every poll this adapter makes. Rule from `docs/ENGINE.md`, again: **an artefact that exists is not
  an artefact that means what you think** — here a cached answer, correct when computed, stale when
  read.

Also caught: the session's CSRF cookie is `posthog_csrftoken`, not Django's default `csrftoken`; a
script reading the wrong name sends an empty `X-CSRFToken` and every write is refused.

### The coherent core — and the one-project ceiling

`scale/core.sh`: the organization and its first project came from signup; then **the API
refused a second project**:

```
HTTP 403 {"code":"permission_denied","detail":"You have reached the maximum limit of allowed
projects for your current plan. Upgrade your plan to be able to create and manage more projects."}
```

`ORGANIZATIONS_PROJECTS` (`posthog/api/project.py:2083`) is a paid feature. An unlicensed
self-hosted PostHog is a **one-project instance**, and "a few hot projects and a long tail" — the
shape every real PostHog deployment of any size has — is a shape a free install cannot reach through
its own front door. The other 40 projects were therefore created at the data plane with PostHog's
own `Team.objects.create_with_data(...)`, the same code path the API takes after its licence check,
so default dashboards, ingestion tokens and filters are exactly what the app would have written.
**4 min 47 s** for 40 projects (one `manage.py shell` per team, ~7 s each — the Django import
graph again) plus **320 events captured through `/capture/`**, eight per project, with the last
project's events queryable **4.5 s** after the last capture. Not dropped, not hidden: the world has
41 projects and the ledger says how.

## 5. Populate — 100M events

`scale/gen.sh`: persons in Postgres under the bulk-load profile from `benchmarks/lib/`, the same
persons **copied** into ClickHouse (never recomputed — ClickHouse has `cityHash64`, Postgres does
not, so the Postgres table is the single source and ClickHouse gets a `COPY … | INSERT FORMAT
CSV`), then events generated server-side in ClickHouse in 10M batches, then `OPTIMIZE FINAL`.

**Shape.** 41 projects, Zipf(1.0) by rank (rank 1 is the app's own default project); per event a
JSON `properties` string with a stable head (`$current_url`, `$browser`, `$os`, `$device_type`,
`plan`, `utm_source`, `$session_id` ~12 events per session, `$window_id`) and a long tail
(`x_<40,000 keys>`, one in four rows also `y_<20,000 keys>`); eight hot event names carrying ~88%
(`$pageview` 42%, `$autocapture` 20%, …) and a 200-name `custom_*` tail; timestamps skewed toward
now across 90 days; `person_mode = 'full'` with `person_properties` on the row, person id and
distinct id pure functions of (project, person number) so the two stores agree by construction.

**Persons, Postgres: 2,000,000 persons + 2,000,000 distinct ids in 41.2 s**, with the profile's
RI validation reporting **0 orphans** on all three FK pairs. Persons, ClickHouse (`person`,
`person_distinct_id2`): **4.7 s**. Two faults on the way, both mine, both trivial and both caught
by running small first: this build's `posthog_person` has no `is_deleted` column (the model I read
was ahead of the table), and ClickHouse's CSV reader rejects Postgres's `+00` timestamptz suffix.

**Trial at 1M events before the real run: 11.6 s** (86,000 rows/s), and every probe rendered
through the API — trends 31 daily points, a three-step funnel (13,216 → 295 → 7), persons page 1
(100 rows, `next` set), a property-filtered trend, an event list of 100 — plus the round trip at
2.59 s. Two generator faults found by the dry runs, recorded because they are ClickHouse facts
rather than mine: **`offset` is a reserved word and cannot be a query-parameter name**
(`{offset:UInt64}` fails to parse with `CANNOT_PARSE_QUOTED_STRING`, misleadingly), and a
`CROSS JOIN` against `numbers()` needs an alias (`ALIAS_REQUIRED`). Also `DateTime` parameters are
passed as quoted literals by the client; an epoch `UInt32` is safer.

## 6. Fork paths

### The guest rootfs — and a generic gap found on the first build

`vm/app.sh … build` (the generic builder): noble minbase, Docker 29.1.3, **26 images verified one
archive each, 7.4 GB of `docker save`**, a 40 GiB ext4 with 8.2 GiB used, **206 s**. It ran
while the 100M load was writing ClickHouse, which is why every number in this section that shares
the disk with the load is quoted with that caveat.

**The first build copied zero bind-mount sources.** The builder derives which host files the
guest needs from `docker compose config` — the Sentry lesson — but that step ran Compose without
`--project-directory`. With compose files that live *outside* the checkout (Mattermost yesterday,
PostHog today) Compose resolves `./docker/…` against the first compose file's own directory, every
bind lands outside `APP_DIR`, the filter skips them all, and the guest's ClickHouse would have died
at `runc create` on `config.xml` exactly as the cold run did natively in §3. Two more lines in
`vm/build-rootfs-generic.sh` now pass `--project-directory "${PROJECT_DIR:-$APP_DIR}"`; the rebuild
copied **13** sources (`docker/clickhouse/*`, `docker/temporal/dynamicconfig`,
`docker/livestream/configs-hobby.yml`, `docker/postgres-init-scripts`, `posthog/idl`,
`posthog/user_scripts`, `products`, `compose`, `share`). Generic, and the third `PROJECT_DIR`
fix in two days: the same assumption — "the project directory is the checkout" — lived in three
places, and each world found one.

### The full run

| | |
|---|--:|
| events generated (10 batches of 10M, server-side `INSERT … SELECT FROM numbers()`) | **101,000,323** in **1,066 s** — 94,800 rows/s |
| `OPTIMIZE TABLE sharded_events FINAL` | **167 s** → one part per month partition |
| `sharded_events` on disk (ClickHouse's own accounting, ZSTD) | **17.74 GiB** |
| persons (both stores) / distinct ids | 2,002,748 / 2,002,748 |
| the hottest project (`team_id 1`, the app's own default project) | **23,600,327 events** — 23.4% |
| second, third | 11,804,013 · 7,869,170 |
| partitions | 202606 10.5M · 202607 48.4M · 202608 32.3M · 202609 9.9M |

Two things to say plainly about the shape, because the numbers in §7 depend on them:

- **The recency skew came out backwards.** `t_end − days·86400·u^0.6` was meant to crowd events
  toward now; `u^0.6 ≥ u` crowds them toward the *older* end, so July holds 48M and the last 30
  days ~14M. Every 30-day probe below therefore reads the *thinner* end of the table. Left as
  generated: the row counts are recorded, a reload is 20 minutes that would not change any
  conclusion, and the sign error is now in the file's comments.
- **Persons are too busy.** 50,000 persons per project against 23.6M events on the hot project is
  ~470 events per person, and the Zipf over persons makes the hot ones far busier than that — so a
  three-step funnel converts almost everybody (50,000 → 48,791 → 40,030). Real funnels do not look
  like that. The queries are exercised at full volume, which is what §7 measures; the funnel's
  *shape* is not evidence of anything.

The rate of a load *while* the rootfs was being built next to it: batches 3–5 ran at 120 s where
1, 6–10 ran at ~100 s. That 20% is the `docker save` of 7.4 GB of images sharing the disk.

**The world is populated when the app can render it**, and it can: trends (31 daily points,
1,611,841 pageviews in 30 days on the hot project), a funnel, the persons page (100 rows, paged),
a property-filtered trend, the event explorer — all through the REST API, all with
`refresh=force_blocking` so none of them was a cached answer. §7 has the timings.

## 7. Probes at 101M events

Five runs each, p50, through the REST API with a session, every query bypassing PostHog's
result cache. Target: project 1, 23,600,327 events.

| probe | p50 | |
|---|--:|---|
| trends — `$pageview` per day, 30 days | **94 ms** | 31 points, 1,611,841 total |
| funnel — `$pageview` → `signup` → `purchase`, 14-day window | **311 ms** | 50,000 → 48,791 → 40,030 |
| persons list, page 1 | **105 ms** | 100 rows, `next` set |
| trends + event property filter (`plan = enterprise`) | **229 ms** | 401,910 |
| event explorer, newest 100 in 7 days | **99 ms** | 100 rows |
| the round trip, at this volume | **8.59 s** | ingestion latency, up from 3.1 s on an empty instance |

Nothing crossed the 1,000 ms threshold, so the `EXPLAIN` rule did not fire; a second pass at a
200 ms threshold caught the funnel, and its numbers are the interesting part:

```
read 2.49 million rows / 159.43 MiB, peak memory 558.82 MiB, 185 ms in ClickHouse
ReadFromMergeTree (posthog.sharded_events)
  Partition   Condition: toYYYYMM(timestamp) in [202608, 202609]          Parts: 3/3   Granules: 5256/5256
  PrimaryKey  Condition: event in 3-element set, toDate(timestamp) in […], team_id in [1, 1]
                                                                          Parts: 2/3   Granules: 310/5256
  Skip        minmax_sharded_events_timestamp                             Parts: 2/2   Granules: 310/310
```

**This is what a well-designed ClickHouse schema looks like at 100M rows.** `sharded_events` is
`ORDER BY (team_id, toDate(timestamp), event, timestamp, …)`, so a per-project, date-bounded,
event-filtered query — which is every product-analytics query — is a primary-key range scan:
month partitions prune 5 parts to 3, the primary key prunes 5,256 granules to **310**, and the
funnel touches 2.49M of 23.6M rows. PostHog's queries are fast at this scale because its table
was designed for exactly these queries; there is no pathology here to expose, and this ledger does
not invent one. Where PostHog's cost *does* show is not in query latency but in §4 (idle RAM),
§6 (what a guest needs) and the ingestion latency creeping from 3.1 s to 8.6 s under a table that
ClickHouse is still merging behind the scenes.

Also worth recording from §5: inserting straight into `sharded_events` triggered **PostHog's own
materialized views**, exactly as the ingestion path does — `sharded_events_recent` (101M rows,
9.9 GiB, the "recent events" copy) and `sharded_sessions` (14.6M sessions, 3.2 GiB, aggregated
from `$session_id`). The data plane wrote one table; the schema produced three. Active parts
across the database: **30.95 GiB**; `OPTIMIZE` left **237 inactive parts (25.9 GiB)** that
ClickHouse reaps after `old_parts_lifetime`, which is why the native snapshot in §6 waits for them.

## 8. Migrations from their own history, at full size

**Django — `1342_drop_cimd_blocklist_table`**, backwards then forwards, against 1,322 MB of
Postgres (2M persons, 2M distinct ids). `RunSQL("DROP TABLE IF EXISTS posthog_cimdblocklistentry")`
with a no-op reverse: **17.0 s back, 16.3 s forward**, and essentially all of it is
`manage.py migrate` importing Django and PostHog's 2,600-migration graph — the DDL touches an
empty table. Exclusive locks observed during the window: `RowExclusiveLock` on
`posthog_filesystem` and `posthog_hogfunctiontemplate`, which are the app's own background writers,
not the migration. The honest reading: **the most recent Django migrations in PostHog's history
do not touch the tables that get large**, because PostHog keeps volume in ClickHouse; the Django
side is metadata, and a 1.3 GB Postgres is not where a migration would hurt this product.

**Async migrations — their framework, as the hobby stack runs it** (`asyncmigrationscheck`,
`run_async_migrations --check`): all ten (`0001_events_sample_by` … `0010_move_old_partitions`)
are recorded with status 2 at first boot. `0009` has an empty `operations` list in this
checkout; `0010`'s `is_required()` returns `is_cloud()`, i.e. **False** on self-hosted. Nothing
in the async framework can run here, by their design; the last one that could was written for
1.43–1.49 (2023). Named, not dropped.

**ClickHouse — `0293_add_session_id_bloom_filter_index`**, the migration that does cost something
at 100M rows: `ALTER TABLE sharded_events ADD INDEX bloom_filter_$session_id …`, then the
`MATERIALIZE INDEX` mutation that builds index files for every existing part. Numbers below when it
finishes.

Result, against **101,000,324 rows** (5 active parts, 17.7 GiB):

| step | duration | what it held |
|---|--:|---|
| `ADD INDEX bloom_filter_$session_id … TYPE bloom_filter GRANULARITY 1` | **0.2 s** | metadata only; existing parts stay un-indexed |
| `MATERIALIZE INDEX` (`mutations_sync = 2`) — the real work | **2.5 s** | nothing: a `count()` issued concurrently returned 101,000,324 mid-mutation, and the probe suite run *during* it measured trends 108 ms, funnel 288 ms, persons 109 ms, events 115 ms — inside the noise of §7 |
| index produced | | **361 MiB** compressed over the 5 parts; the mutation rewrote them, leaving 10 more inactive parts for the reaper |

2.5 s for a skip-index build over 101M rows is possible because `$session_id` is a
*materialized column* (migration 0026 — the one the first-boot race tripped over) that ClickHouse
reads without touching the 17.7 GiB of `properties`, and because a mutation in ClickHouse is not
a lock but a background rewrite that swaps parts when done. Compare Mattermost's plain
`CREATE INDEX` on Postgres yesterday: 6.6 s of `ShareLock` during which nobody could write. Same
task, different database, opposite operational shape. **The migration risk in PostHog is not
ClickHouse DDL; it is the 23 minutes of Django migrations on a first boot** (§4), which a
warm fork never pays again.

### The native snapshot `@ph-base`, and two generic bugs in the zvol builder

`vm/app-snapshot-native.sh` with the new store cases: **quiesce 8.5 s** (ClickHouse
`STOP MERGES + FLUSH LOGS`, Postgres `VACUUM ANALYZE` + `CHECKPOINT`, Redis and Valkey `BGSAVE`;
Redpanda, ZooKeeper, MinIO, SeaweedFS and Temporal now *say* what they rely on instead of silently
matching nothing), **clean stop 37.9 s** for 38 containers, eight `zfs snapshot`s in 0.1 s, restart
27.1 s — **frozen window 65.1 s**. `tank/ph-ch@ph-base` references **30.4 GB** (ClickHouse had
reaped the 25.9 GiB of post-`OPTIMIZE` parts from disk by then, although `system.parts` still
listed 273 inactive entries), Postgres 824 MB, the other six under 3 MB each.

Then `vm/app-zvol.sh` built a 130 GB zvol, printed `no /tank/ph-zk` once in passing, and
**exited 0 with a zvol holding two of the eight stores** (`pg`, `ch`). Two bugs, both generic:

1. The dataset lookup was by *service name only*. ZooKeeper is the first store with two datasets
   (`/data` and `/datalog`), so the lookup returned two lines and the path check failed on a
   nonsense path.
2. The copy loop ran as `map | while …`, so the `exit 1` on that failure ended the *subshell* and
   the script carried on to snapshot the zvol and report success.

Either bug alone would have produced a guest that boots, mounts `/data`, and finds no Kafka, no
Redis, no object storage and — worst — a ClickHouse with no ZooKeeper state, i.e. every
replicated table read-only. Fixed: match on service *and* path, feed the loop from process
substitution so `exit` is fatal, and verify every mapped directory exists before the zvol is
snapshotted. The same rule as every other entry of this kind in these ledgers: **a build step that
can fail must not be able to report success.**

## 10. The alternative a team would use today — leading with it

ZFS clones of all eight datasets as "database branches" (0.3 s, copy-on-write), plus a
conventional cold `docker compose up` of the same 38-container stack against them, on the same
box, from the same `@ph-base`.

| | ZFS branches + conventional cold deploy | Firecracker fork (§6) |
|---|--:|--:|
| make the branch | **0.3 s** | — |
| to `/_health` 200 | **234 s** (3.9 min; no migrations to replay, just 38 containers starting) | see §6 |
| trends, cold / warm | **84 ms / 52 ms** | see §6 |
| memory | **18.2 GiB** across 36 containers | see §6 |
| isolation | an event captured in the branch: present there, absent from the baseline after 10 s — **correct** | see §6 |
| disk the branch accumulated after boot + one event | ClickHouse 85.5 MB, Postgres 2.2 MB, Redpanda 0.8 MB | see §6 |

**Say it plainly, as for Mattermost:** for PostHog the conventional alternative is *good*. Once
the 23-minute first boot has been paid once and snapshotted, a ZFS branch plus `compose up`
gives a working, isolated, production-shaped PostHog in under four minutes, and its queries are
as fast as the baseline's because they run on the host with the host's page cache. If a team's
pain is "we need a second PostHog for this PR by lunchtime", this row already solves it, and this
ledger would be dishonest to pretend otherwise.

What it cannot reach:

- **Anything that lives in process memory or on a queue.** The branch restarts every process
  cold: Celery's beat schedule and any in-flight task, Temporal's worker state (its *store* is
  branched with Postgres, its workers are not), the plugin-server's consumer offsets past the last
  commit, ClickHouse's mark and uncompressed caches (5 GB + 8 GB configured), the Kafka consumers'
  partition assignments. A fork resumes all of it mid-flight.
- **The 18 GiB per branch is host RAM with no ceiling.** Two branches and the baseline put this
  64 GB box at **8.7 GB available**, under the 10 GiB headroom rule, before a third could start.
  A guest has a fixed envelope and can be sized below the native idle (§6).
- **Host ports.** Every branch needs its own free block of six published ports; the first
  Mattermost attempt yesterday collided with another world's container, and this one needed a
  port plan per branch written into the generator.
- **A failed `up` is not obviously a failed `up`.** The first attempt here produced a compose file
  with a duplicated key, Compose refused it, zero containers started, and the harness's health
  loop waited the full twenty minutes for a stack that did not exist. That is a bug in *this*
  script, fixed with a fail-fast, and recorded because it is the operational shape of the
  alternative: a conventional deploy fails in a hundred quiet ways and each one costs the wait.

### The guest's first boot, twice, and the third bug from the same fact

`vm/app.sh bake` (boot a scratch guest once to `docker load` the images, then publish the root
disk as a zvol) waited its full 900 s for `/_health` and gave up; `boot 1` did the same; the
snapshot step then refused, correctly — *"VM 1 gateway is not healthy (got '000'); snapshot it
healthy or not at all"* — which is the runtime doing exactly what the ENGINE rules ask of it. The
guest's serial log had the cause on one line:

```
app-up: failed to parse /opt/app/docker-compose.vm.yml: line 11: mapping key "zookeeper" already defined at line 9
```

The rootfs builder writes the guest-side override that rebinds every dataset to `/data/<sub>`
from `DATA_MAP`, one `<service>:` block per line. ZooKeeper has two lines. A YAML mapping cannot
repeat a key, Compose refused the whole file, `app-up` fell back to "polling container health"
of containers that had never been created, and the guest sat at 16.3 GB of PSS doing nothing for
fifteen minutes, twice. **The same fact — one service, two datasets — broke the zvol builder's
lookup, the zvol builder's error handling, and the guest override generator**, three places that
had all quietly assumed one dataset per service because three worlds never had otherwise. Fixed
by grouping volumes per service (an `awk` that accumulates, then emits one block each), with the
rendered file checked as YAML before the rebuild. Rootfs build #3 follows; the numbers for the
guest are in the next subsection, from the run that worked.

### The guest, from the build that worked

| step | |
|---|--:|
| rootfs build #3 (26 images, 7.4 GB, 13 bind sources, 40 GiB ext4 with 8.2 GiB used) | 157 s |
| **bake**: scratch guest boots, `docker load`s 7.4 GB, starts 38 containers, API healthy | **518.7 s** (API healthy at 390.7 s) → `tank/rootfs-ph@baked`, 26.3 GB |
| **cold boot** of slot 1 (16 GiB, 8 vCPU) to `/_health` 200 | **254.1 s** |
| ↳ the guest's own `app-up` reported "ready" | 36.8 s — the container-health signal, four minutes before Django answers; not a readiness signal, which is why the runtime waits for the HTTP 200 |
| the round trip inside the guest, through the forwarded port | **3.30 s** |
| **PSS of the source VM, idle after the round trip** | **16,311 MB** — the whole 16 GiB envelope |
| snapshot `phbase` (quiesce, pause, dump 16 GiB, pre-fault) | **52.2 s** |
| data + root disk: `tank/ph-vmfork1` 199 MB, `tank/rootfs-ph-src1` 328 MB written since boot | |

**Guest RAM: 16 GiB is the minimum for the hobby stack as shipped, and it is tight.** Native idle
was 18.8 GiB with a 16-thread Celery pool; in the 8-vCPU guest the pool is 8 forks, and the guest
still touches every page it has. It works — the round trip passes and the API is healthy — but
there is no slack: a 12 GiB guest was not attempted, because the one measurement that matters
(PSS = the envelope) already says where the minimum is. Where the memory goes is not PostHog's
data (ClickHouse holds 30 GB on disk and its caches are cold) but PostHog's *processes*: two
Django import graphs (`web`, `temporal-django-worker`), a Celery fork pool of the same graph,
seven Node processes, ten Rust/Go sidecars, an Elasticsearch that holds nothing, and a headless
Chromium. The realistic way down is to run fewer of them; the brief's rule is to run all of them
and say so.

Under the **10 GiB headroom rule** on this 64 GB box, 16 GiB forks alongside the other worlds'
baselines allow **two** — which is what §6 measures below, not a ceiling but the rule.

**A trap I set for myself, for the second day running.** After `snapshot 1 phbase` I ran
`vm/app.sh … stop 1` to free the source VM's 16 GiB, and `stop.sh` — by design — destroyed
`tank/ph-vmfork1` and with it `tank/ph-vmfork1@phbase`, the data-side snapshot every fork clones
from. The first fork then failed with `cannot open 'tank/ph-vmfork1@phbase': dataset does not
exist`. Mattermost hit the identical thing yesterday. The runtime's model is that the source VM
*stays* while forks exist; the memory file lives in `vm/out/snap-phbase/` but the disk state lives
on the source's clone. With the source up, 16 + 2×16 GiB exceeds this box's headroom rule, so to
measure two forks I re-booted, re-snapshotted, and then stopped only the source's *process*
(`kill` on the firecracker pid, datasets kept, `stop.sh` at the very end). A workaround, named as
one; the proper fix is a `park` verb that does exactly this — and it belongs in `CLAUDE.md`'s
trap list, where it now is.

### Forks

Two, under the 10 GiB headroom rule, from `phbase` (the source VM's process parked, its datasets
kept — see the trap above):

| fork | restore → `/_health` 200 | PSS @10 s | @60 s | @120 s |
|---|--:|--:|--:|--:|
| 1 | **4.80 s** | 7,995 MB | 9,283 MB | 9,693 MB |
| 2 | **4.72 s** | 5,664 MB | 9,413 MB | 9,428 MB |
| | | | **summed** | **19,137 MB** |

**4.8 seconds to a 38-container PostHog carrying 101 million events, with the whole process
tree — Django, Celery, Temporal, seven Node consumers, ten Rust/Go services, ClickHouse with its
caches — resumed where the snapshot left it.** Two of them cost 19.1 GB of host memory, against
18.8 GiB for *one* native instance idle. The PSS climb from 6–8 GB at ten seconds to ~9.5 GB at two
minutes is the guest touching pages the pre-fault did not (5.6 GB of the 16 GiB memory file was
allocated at snapshot time; the rest is zero pages until something writes them).

**Isolation** — an event captured in fork 1 is queryable in fork 1 and absent from fork 2 — held,
**on the third attempt**, and the first two are the finding:

> `capture in fork 1 failed: HTTP 502`

PostHog's Rust `capture` service (and `replay-capture`) runs a lifecycle monitor. After the
restore, the Kafka sink's health check judged the frozen window a stall — *"health stall
threshold reached … shutdown initiated: health check stalled (stall count 1/1)"* — and the process
**exited 0, six seconds after the restore**. Compose's `restart: on-failure` does not restart an
exit-0 container. So every fork of PostHog came up with `/_health` green, Django serving, queries
answering, and **no ingestion front door**: a readiness check that stops at `/_health` would call
that fork healthy. Only the round trip noticed. `docker start` on the two containers and the
isolation check passed at once.

The generic fix is in the guest's `post-restore`: for a minute after every restore, any container
that exits **0** *after* the restore instant is started again (one-shot jobs that finished before
the snapshot are left alone, because their `FinishedAt` predates it). It is a generic rule for a
generic shape — a component that decides on its own that time jumped too far — and PostHog is the
first world to have one. The rootfs was rebuilt with it, re-baked and re-snapshotted, and the
check that a fork now keeps `capture` up 75 s after restore is in the next subsection.

### PR → changed system serving, in fork 1

One line in `posthog/views.py` (`/_health` answers `ok paraglobe-pr1`), layered onto the pinned
2.7 GB image with a two-line Dockerfile (a Python change does not need PostHog's multi-GB build;
the same trick as Mastodon's).

| | |
|---|--:|
| image build, cold layer / warm | **30.0 s / 7.8 s** |
| `docker save` → ssh → the fork (the whole 2.7 GB image travels) | 22.4 s |
| `docker load` + `compose up --force-recreate web worker temporal-django-worker` | 32.7 s |
| until `/_health` carries the marker — Django restarting: `migrate-check` and NGINX Unit | **251.8 s** |
| **total** | **314.7 s** |

Afterwards fork 1 answers `ok paraglobe-pr1` and fork 2 answers `ok`. The 252 s is PostHog's own
restart cost (the same four minutes the guest's cold boot pays after its containers are up), not
the swap's: ship and load together are under a minute. The image-transfer number is also honest
about the layering trick's limit — a 2.7 GB image ships for a one-line change; the CI path (§9)
retags rather than ships, and pays only the recreate.

## 11. Tooling absorbed by the runtime vs PostHog-specific adapter

**Generic (in `../paraglobe`, none of it PostHog-specific), from `git diff --stat`:**

| file | change |
|---|---|
| `vm/build-rootfs-generic.sh` | `--project-directory` on both `docker compose config` calls of the bind-copy step (0 → 13 sources copied); the guest override groups volumes per service (ZooKeeper's two datasets no longer produce a duplicate key) |
| `vm/app-zvol.sh` | dataset lookup by service **and** path; the copy loop fed by process substitution so `exit` is fatal; every mapped directory verified before the zvol is snapshotted |
| `vm/app-snapshot-native.sh`, `vm/guest-generic/usr/local/bin/quiesce` | Redpanda, ZooKeeper, MinIO, SeaweedFS and Temporal named, with what each relies on |
| `vm/guest-generic/usr/local/bin/post-restore` | the 60-second watcher that restarts services that exit 0 after a restore |
| `ops/ci/posthog.yml`, `ops/ci/suites/posthog-smoke.sh`, `ops/ci/workflows/posthog.yml` | the world's CI config (133 lines) and its workflow file (a copy of the template) |

Roughly **60 changed lines** in the runtime for four generic defects, three of them the same
fact ("one service, two datasets") in three files.

**PostHog-specific, in `benchmarks/posthog/` — 749 lines plus one derived file:**

| file | lines | what |
|---|--:|---|
| `app.spec` | 30 | the spec |
| `compose/docker-compose.hobby.paraglobe.yml` | 746 | **their** hobby file with `./posthog/` → `./` (`check-upstream.sh` proves it) |
| `compose/docker-compose.ph.yml` | 63 | datasets, ports, sinks, the quay redirect, `shm_size` |
| `compose/hobby.env`, `compose/vm.env` | 9 + 14 | what `bin/deploy-hobby` writes; the guest's front-door binding |
| `probe.sh` | 79 | the round trip, incl. the email-verification code from the sink |
| `scale/core.sh` | 74 | org + 41 projects (40 via `Team.objects.create_with_data`) + captured events |
| `scale/gen.sh`, `scale/gen-events.sql`, `scale/gen-persons.sql` | 71 + 65 + 35 | persons in Postgres (bulk-load profile), copied to ClickHouse; events server-side |
| `probes.sh` | 76 | trends, funnel, persons, property filter, event list; `EXPLAIN` via `system.query_log` |
| `migration.sh` | 43 | Django, ClickHouse and async replays |
| `forks.sh`, `alt-baseline.sh`, `pr-swap.sh` | 62 + 85 + 27 | Firecracker forks/PSS/isolation; ZFS branches + conventional deploy; the one-line PR |
| `check-upstream.sh` | 16 | drift guard for the derived hobby file and the MinIO pin |

Installer artefacts generated into the checkout and git-excluded: `compose/start`, `compose/wait`,
`compose/temporal-django-worker` (verbatim from `bin/deploy-hobby`), `share/GeoLite2-City.mmdb`.
**Zero lines of PostHog's application code changed.**

## 12. Unsupported or not done — named, not dropped

| | status |
|---|---|
| **more than one project through the front door** | **impossible unlicensed** — `ORGANIZATIONS_PROJECTS` is a paid feature, HTTP 403. 40 of 41 projects were created with PostHog's own `Team.objects.create_with_data` at the data plane (§4) |
| a plugin-server matching the pinned commit | **not done** — `posthog/posthog-node:latest` is from 2026-03-31 and is what the hobby stack ships; ingestion worked with it. Building `Dockerfile.node` at the pin would be the fix if it had not |
| Rust sidecars at the pinned commit | **not available** — `ghcr.io/posthog/posthog/*:master` only; digests recorded in §1 |
| session-recording bytes, file uploads in object storage | **not populated** — SeaweedFS and MinIO hold what the app wrote during boot and the core; the 100M events carry no recordings |
| the recency skew of the generated timestamps | **backwards** (§5) — recorded, not reloaded |
| persons' activity distribution | **too even** to give a realistic funnel shape (§5) |
| async migrations | **cannot run off cloud, by their design** (§8) |
| Elasticsearch | runs because hobby starts it, holds nothing (`ENABLE_ES=false`), 690 MB of RAM for it |
| a 12 GiB guest | **not attempted** — 16 GiB is fully used (§6); fewer processes is the only way down |
| more than 2 concurrent Firecracker forks | **not measured** — two is what the headroom rule allows for 16 GiB guests on this box, not a ceiling |
| a pull request on github.com | **not opened** — `sideworld/posthog` does not exist; both PRs ran through the runner simulator |
| PostHog's own test suites | **not wired** — pytest + Playwright, hours; the CI suite is seven API checks plus the round trip |

### The fix, verified — in two rounds

Rebuild #4 (with the watcher), re-bake **515.9 s**, cold boot **253.8 s**, snapshot **55.7 s**, a
fork restored in **4.43 s**. Then 75 s of waiting and a look inside:

```
post-restore: app-capture-1 exited 0 at +0s after restore; started again
app-replay-capture-1   Exited (0) About a minute ago
/capture/ on the fork 75 s after restore: HTTP 200
```

Half right. `capture` was caught and restarted and the ingestion front door answered 200.
`replay-capture` (session recordings, `/s/`) died the same way and was **not** caught: it exited
in the two seconds between the VM resuming and `post-restore` restarting chrony, so its
`FinishedAt` carries the *snapshot's* clock — which, to a watcher that took its start time after
the clock jump, looks like it finished before the restore, i.e. like a one-shot job. The rule was
"exited 0 after my start time"; that is the wrong invariant around a clock jump. The right one
does not use the restore time as a boundary at all: **a container that had been running for more
than two minutes and exited 0 within the last fifteen minutes of guest time is a service that
died, not a job that finished** (kafka-init runs ~60 s and finished long before). Rebuild #5
carries that rule; its verification is below.

Rebuild #5: rootfs 137.9 s, re-bake **517.8 s**, cold boot **253.3 s**, snapshot **57.3 s**, a
fork restored in **4.27 s**, then 80 s and a look inside:

```
post-restore: app-capture-1 ran 309s then exited 0 around the restore (FinishedAt 1s vs now); started again
post-restore: app-replay-capture-1 ran 309s then exited 0 around the restore (FinishedAt 1s vs now); started again
app-kafka-init-1   Exited (0) 6 minutes ago          <- a job; left alone
/capture/ on the fork 80 s after restore: HTTP 200
/s/       on the fork 80 s after restore: HTTP 400   <- answering (a non-recording payload); 502 was "down"
```

Both services caught, the one-shot job left alone, both ingestion front doors answering. This is
the `phbase` snapshot the CI baseline (§9) is built from. The bake-boot-snapshot cycle for a 16 GiB
PostHog guest is **~14 minutes** (518 + 253 + 57 s); it ran four times today, three of them for
defects, which is most of where the wall clock in §13 went.

## 9. CI — a pull request gets its own fork

`ops/ci/posthog.yml`, `ops/ci/suites/posthog-smoke.sh`, `ops/ci/workflows/posthog.yml`. Slots 9
(source) and 16 (fork), `exclusive: true` — a 16 GiB guest that uses all of it takes the box to
itself, like Sentry. The build layers `posthog/`, `ee/` and `products/` onto the pinned image (a
Python change; anything under `frontend/`, `nodejs/`, `rust/` or the dependency files is refused
with an explanation rather than tested against a stale image). `web`, `worker` and
`temporal-django-worker` share that image and are all recreated.

**Baseline, built in 334.6 s**: the CI's own source VM on slot 9 to `/_health` in 256.2 s (the
same four minutes as every PostHog boot), snapshot 61 s (5.5 GB on disk), a fork in 4.4 s, then
the suite twice against the unmodified fork:

> **8 of 8 pass, both runs, 0 known-failing, nothing flaky** — 5.4 s and 5.5 s.

The eight: `health`, `login`, `trends`, `events_at_scale` (the fork must report ≥100k pageviews
in 30 days, or it is not carrying the baseline's volume), `funnel`, `persons_list` (≥50 rows),
`event_list`, and `round_trip` — capture an event through the fork's front door and query it back,
the one check that would have caught §6's self-terminating `capture`.

PostHog's own suites — `pytest` over the backend and Playwright end-to-end — are available and
deliberately not wired: hours, not a per-pull-request verdict. Named, not dropped.

**Two generic CI fixes before a PostHog pull request could run at all.** The first attempt at
both PRs ended in about twenty seconds each with nothing in the log after *"reading the checkout
from stdin (cap 512 MiB)"* but "teardown". The JSON had the reason: *"checkout contains symlinks
pointing outside it: … `.claude/skills -> ../.agents/skills`"*. That link never leaves the tree;
`ops/ci-entry.sh`'s audit refused any target containing `..` instead of resolving it. Now it
resolves each link against its own directory (`realpath -m`) and refuses only what ends up outside
the checkout — PostHog's 47 symlinks all pass. And `finish` now logs `error: …` as well as
writing it to the JSON, because a failed run that reads as a silent teardown is the empty-artefact
rule again, in the CI's own output. The 162 MB tarball itself was well under the cap.

**A third generic CI fix, and this one would have failed every correct pull request.** With the
audit fixed, both PRs built (web 56.6 s / 43.0 s, the two other services 9.4 s each from the
same layer), restored a fork in **4.2 s**, swapped — and then: *"the pull request's image(s) were
swapped in and the fork did not come back healthy"*, after the full ~8-minute wait, for the green
PR and the red one alike. The post-swap loop required `/_health` 200 **and** every swapped
service to report `healthy`. PostHog's `web`, `worker` and `temporal-django-worker` define **no
healthcheck**; their `.Health` is empty, which is not `healthy`, so the loop could never exit
while Django was long since serving. Every earlier world's swapped services happened to carry a
healthcheck, so the condition had never been wrong before. It now asks what Compose's own
`--wait` asks: running, and either healthy or without a healthcheck. Three CI fixes in one world,
all of the same shape as the runtime ones — an assumption three worlds never contradicted.

### The pull requests, through the runner simulator

| | PR #1 `ci/pr-1-health-marker` | PR #2 `ci/pr-2-persons-page` |
|---|---|---|
| the change | one line: `/_health` answers `ok paraglobe-pr1` | `DEFAULT_PAGE_LIMIT = 1`, then (second commit) the server-side page size applied for every caller |
| expected | green | red, naming `persons_list` |
| **got, first commit** | **green — 8/8, 0 new, 421.1 s** | **green — 8/8**, correctly: see below |
| got, second commit | — | **RED — 1 new: `persons_list` (1 person returned), 7 of 8 still green incl. the round trip; 447.4 s** |

| phase (green, #1) | |
|---|--:|
| unpack the checkout (162 MB over stdin, 48,356 files) | 14.1 s |
| build — `web` layered onto the pinned image; `worker` and `temporal-django-worker` retag it | 28.1 s (9.4 s each) |
| restore a fork of the baseline | **4.2 s** (load 0.033 s, disks 0.273 s, netns 0.089 s, serving 3.5 s) |
| swap the image in and serve again | **363.4 s** — Django restarting, again |
| migrations forward | 1.7 s |
| suite (8 checks incl. the round trip at 3.4 s) | 5.7 s |
| **total** | **421.1 s** |

**The first red was correctly green.** `DEFAULT_PAGE_LIMIT` applies only when a client sends no
`limit`; PostHog's own frontend sends one, and so does this suite (`?limit=100`), so a change to
the default degrades nobody who actually calls the endpoint. The pipeline reported what was true
— 8 of 8 pass, 100 persons returned — and the pull request was the problem, which is the failure
mode worth having (TrainTicket's first red had the same shape). The second commit makes the
server-side page size authoritative for every caller: a realistic bug (an API that stops honouring
`limit`) that degrades exactly one endpoint.

**Where the 421 s goes** is worth one sentence, because it is the number an infrastructure lead
will read: **363 of them are PostHog restarting Django** after the swap — `bin/migrate` re-checking
2,618 migrations, then `migrate-check`, then NGINX Unit — the same ~4 minutes a cold boot pays
after its containers are up. The runtime's part (unpack, build, fork, suite, compare) is under a
minute. A world whose web process took ten seconds to start would get its verdict in about sixty.

## 13. Protocol table, and where the time went

| step | result | number |
|---|---|---|
| 1. clone + inventory | done | pin `e04da21b`, 38 services, 8 stores, 2,618 + 319 + 10 migrations, 76 beat tasks, outbound table (§1) |
| 2. `onboard-generic.sh` cold | 3 stops, none generic (§3) | `.env`; MinIO withdrawn; the installer's layout |
| 3. native ready | round trip 3.80 s | `/_health` 200 at 1,411 s; idle 18.8 GiB; ready at 43 min |
| 4. populate | 101,000,323 events, 2M persons | 1,066 s load, 30.4 GB ClickHouse on ZFS; renders through the API |
| 5. probes + migrations | no query pathology | trends 94 ms · funnel 311 ms · persons 105 ms · filter 229 ms; Django 17 s; ClickHouse `MATERIALIZE INDEX` 2.5 s, nothing blocked |
| 6. Compose fork on ZFS | works, isolated | clone 0.3 s, `/_health` 234 s, 18.2 GiB, delta 85 MB |
| 6. Firecracker | 2 forks | bake 518 s · boot 254 s · snapshot 57 s · **restore 4.8 s / 4.7 s** · PSS ~9.5 GB each · isolation correct after the `capture` fix |
| 6. PR swap | 314.7 s | build 7.8 s warm / 30 s cold; 252 s of it Django restarting |
| 7. alternative row | led with (§10) | 234 s to working, 84/52 ms trends, 18.2 GiB, no ceiling |
| 8. CI | baseline 8/8 stable in 335 s; green **421.1 s**; red **447.4 s naming `persons_list`** | runner-sim only; three generic CI fixes on the way |
| 9. write-up | this file, `OUTREACH.md`, BENCHMARK column, BUILDLOG ×2 | |

Start 2026-09-23 06:03 UTC. Natively ready 06:46. Two forks 09:04. CI verdicts ~12:40.
**About 6 h 40 min of wall clock, of which ~1 h 50 min was a background chain killed and
idle** (the session paused mid-bake; the scratch VM was cleaned up and the chain rerun).

| | activity |
|---|--:|
| inventory, the installer, the pin, image tags | 15 min |
| cold stops, the derived compose, GeoIP, env | 20 min |
| first boot (their 23.5 min) + the round trip's two traps (verification code, cache) | 45 min |
| the coherent core and the one-project ceiling | 10 min |
| generator: persons, dry runs, four ClickHouse facts, the 100M load (18 min of it waiting) | 40 min |
| probes, EXPLAIN, three migration replays | 15 min |
| native snapshot; the zvol's two bugs; rebuild | 20 min |
| Compose fork on ZFS (incl. my duplicate-key false start, 20 min of it waiting) | 30 min |
| guest: rootfs ×5, bake ×4, the duplicate `zookeeper:` key, the `capture` self-shutdown, two watcher rounds | **1 h 45 min** |
| forks, PSS, isolation, PR swap, the source-clone trap | 20 min |
| CI: baseline, symlink audit, silent error, the no-healthcheck condition, the correctly-green red | 45 min |
| write-up, as it happened | throughout |

**The guest path was half the effort and all of the runtime learning**, as it was for Sentry: four
generic defects, every one of them an assumption three earlier worlds had never contradicted.

