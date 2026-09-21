# Mastodon onboarding (L3) — ledger and benchmark

Live ledger. Started 2026-09-21 (box: Hetzner Ryzen 7 7700, 64 GB, Ubuntu 24.04 / 6.8, Firecracker
v1.17.0). Time-box: 16 h of operator activity. Gate: if Mastodon is not ready natively within 4 h,
stop and record why.

Target: mastodon/mastodon at the latest stable tag, official `docker-compose.yml` — a Rails monolith +
Sidekiq + Node streaming + Postgres + Redis: a different architectural family from the specimen (Go/
Node/Python services, Kafka) and TrainTicket (Java microservices, Mongo). **Zero changes to Mastodon's
code.** Adapters allowed: Compose overrides, env vars, init scripts, mocks/sinks for outbound calls,
data generators.

## Time ledger

| # | when (UTC) | step | hours | category | notes |
|---|---|---|---|---|---|
| 17 | 18:14–18:45 | write-up: protocol table, BENCHMARK column, BUILDLOG, tallies, commit | 0.5 | writeup | |
| 16 | 18:04–18:14 | PR swap (three attempts: env file, refused-connection poll, then timed), alternative baseline ×2, Compose re-measure, teardown of 10 forks + source, specimen `vm/boot.sh 1` proof (27.2 s), KSM off | 0.17 | measurement | |
| 15 | 17:20–18:05 | VM path: zvol, bake, boot 1, snapshot + pre-fault, series 1 (aborted: my seq-scan isolation query), series 2 (10 forks), warm restore series; ledger | 0.75 | fork-vm | ~0.4 h of it waiting on the 120 s idle windows |
| 14 | 17:15–17:20 | Compose fork 1 (twice: token path), ledger; zvol build launched | 0.08 | fork-compose | |
| 13 | 17:11–17:20 | migration results into the ledger; native quiesce + `@md-base` | 0.15 | migration | |
| 12 | 16:55–17:15 | probes: two runs, regeneration semantics found and fixed (`regen-feed.sh`), slow-log capture fixed (ALTER SYSTEM transaction, extended-protocol binds), followers EXPLAIN; migration.sh reviewed (VALIDATE split out of the ADD transaction) and launched | 0.33 | probes | |
| 11 | 15:10–16:55 | run 2 supervised; rootfs built twice (shm fix); validation failure on `/dev/shm` → `shm_size: 4g`, db recreated, standalone validation, VACUUM ANALYZE, numbers, heavy token; probes.sh fixed to find the real heavy accounts | 0.5 | data | mostly waiting; the active work is ~0.5 h |
| 10 | 14:45–15:10 | RI-tail diagnosis (`perf`), abort, generic bulk-load profile (RI triggers off, FK validation after) wired into Mastodon's generator and recorded for the specimen's and TrainTicket's; 300k validation run; full run relaunched | 0.42 | data | the abort's arithmetic is in Step 4 |
| 9 | 14:27–14:45 | predictions pre-registered; guest-path review of the override against the generic builder → `VM_ENV_FILE`/`EXTRA_COPY` knobs, shared-dataset dedupe, inline sink config, interpolated binds, `vm-fork-measure.sh`; ledger | 0.3 | adapters | while the statuses INSERT ran |
| 8 | 14:35–14:40 | re-read the ledger, BENCHMARK row definitions and BUILDLOG from disk; alternative-baseline definition written before measuring | 0.08 | writeup | |
| 7 | 14:10–14:35 | while the generator ran: generic runbook layer (`onboard-generic.sh`, `app.sh`, `app-datasets.sh`, `app-snapshot-native.sh`, `app-zvol.sh`, prefault), Mastodon spec + hooks, migration/probes/alt-baseline/pr-swap scripts | 0.4 | adapters | file-only |
| 6 | 13:50–14:10 | generator debugging: unique ids by construction, integer overflow, `random()` in a WHERE re-evaluated per scanned row (favourites 0, long-tail 0, 60 s of seq scans); precompute-and-join everywhere; full 100M run launched | 0.33 | data | |
| 5 | 13:40–13:50 | generator validation: two failed runs (unique/ON CONFLICT with indexes dropped; a failed run left the schema index-less and 30k accounts behind); `gen.sh` now restores indexes on any exit; `reset-db.sh` | 0.17 | data | my errors |
| 4 | 13:25–13:40 | e-mail validator traced (null MX), network alias, admin, token, full readiness; PG tuning; generator written (163 + 31 lines) | 0.25 | data | native ready at 13:28, 12 min in |
| 3 | 13:20–13:25 | `.env.production`, `db:setup`, cold boot 61.9 s, idle RAM; admin creation blocked on email validation | 0.08 | native-boot | |
| 2 | 13:20–13:35 | adapters: compose override (ports, ZFS binds, sink, Mailpit, proxy env), sink nginx, `md.sh`, `init-env.sh`, `probe.sh`, `make-token.sh`; config facts (force_ssl, host allow-list, uids, secret tasks) | 0.25 | adapters | |
| 1 | 13:16–13:20 | ledger, clone v4.7.2 (10.7 s), image pulls (27 s), inventory from source, cold `onboard.sh` attempt, 3 datasets | 0.07 | understanding | |

Categories: setup, understanding, native-boot, debugging, adapters, data, probes, migration,
fork-compose, fork-vm, alternative, measurement, writeup.

**Hours by category** (operator activity, rows 1–17): understanding/setup 0.07 · native-boot 0.08 ·
adapters 0.95 · data 1.67 · probes 0.33 · migration 0.15 · fork-compose 0.08 · fork-vm 0.75 ·
measurement 0.17 · writeup 0.58 — **4.8 h of activity in 5.5 h of wall clock** (13:16–18:45 UTC);
the gap is the generator's runs, which I waited out. **Clone → first useful fork: 4 h 01 min**
wall clock (13:16 → 17:17 Compose fork 1 healthy and isolated), **4 h 14 min** to the first
Firecracker fork (17:30); of that, **3 h 11 min was step 4** (13:41–16:52: the aborted RI-tail run,
the rerun, the shm-blocked validation, the index rebuild). With the bulk-load profile that now exists,
the load alone is 1 h 47 min and the onboarding lands at ~2 h 40 min. Native readiness came at **12 min**.

## Adapters written

Mastodon-specific (`benchmarks/mastodon/`):

| file | lines | kind | why |
|---|---|---|---|
| `compose/docker-compose.md.yml` | 92 | Compose override | ZFS binds, ports 3300/4300 (3000/4000 taken on this host; `${MD_BIND}`/`${MD_*_PORT}` interpolated so the guest binds 0.0.0.0:3000/4000), outbound sink via `http_proxy` (nginx config inline as a Compose `configs: content:`, so no host path is mounted and the same file works in the guest), Mailpit, `mastodon.test` network alias for the e-mail validator, Postgres tuning |
| `compose/vm.env` | 3 | guest env | the three port-bind variables for the microVM |
| `regen-feed.sh` | 9 | init/probe helper | kick a user's home-feed rebuild the way a sign-in does |
| `fork.sh` + `unfork.sh` | 46 + 14 | fork runner (Compose) | clone the three datasets, override via `mkfork-generic`, up, probe, isolation status, cgroup RAM, storage delta; inverse |
| `vm-fork-measure.sh` | 70 | measurement | restore fork k, PSS/RSS at 10/60/120 s with no requests, isolation status, streaming health, Sidekiq processed (from Redis), heavy home timeline, storage delta |
| `init-env.sh` | 45 | init script | mints `.env.production` with Mastodon's own secret tasks |
| `init-app.sh` | 15 | init hook | `db:setup`, admin, token; idempotent |
| `make-token.sh` | 12 | init script | OAuth token for a local user via `rails runner` |
| `probe.sh` | 36 | readiness | instance 200 + streaming OK + a status posted and processed by Sidekiq |
| `reset-db.sh` | 13 | reset | back to post-init (needs `DISABLE_DATABASE_ENVIRONMENT_CHECK=1`) |
| `md.sh` | 9 | wrapper | the compose invocation |
| `app.spec` | 25 | app spec | what `vm/onboard-generic.sh` needs to know |
| `scale/gen.sql` + `scale/gen.sh` | 165 + 48 | data generator | data-plane load with Mastodon's id scheme, shape and references; indexes dropped/rebuilt, restored on any exit |
| `migration.sh` | 33 | experiment | naive vs. safe migrations on 100M rows |
| `probes.sh` | 34 | experiment | p50/p95 of the timelines/notifications/lookup + slow-query EXPLAIN |
| `alt-baseline.sh` | 43 | experiment | the no-runtime alternative: DB clone + cold deploy |
| `pr-swap.sh` | 30 | experiment | PR → serving inside a VM fork |

Generic, added to `vm/` this time (the runbook layer TrainTicket showed was missing):

| file | lines | what |
|---|---|---|
| `vm/onboard-generic.sh` | 40 | spec-driven runbook: clone → datasets → hooks → up → probe → generate → native snapshot → zvol → rootfs → bake → boot → VM snapshot |
| `vm/app.sh` | 27 | spec-driven `vm.sh`: sets every knob from the spec; `VM_ENV_FILE` (guest-only env file, defaults to `ENV_FILE`) and `EXTRA_COPY` pass-through |
| `vm/app-datasets.sh` | 27 | create/chown/snapshot datasets, emit `DATA_MAP` and `FORK_MAP` from the spec; a dataset two services share (web + sidekiq → `public/system`) is snapshotted once |
| `vm/app-snapshot-native.sh` | 30 | quiesce by image (Postgres CHECKPOINT/VACUUM, Redis BGSAVE, Mongo, MySQL), clean stop, snapshot, start |
| `vm/app-zvol.sh` | 20 | data zvol from dataset snapshots, per the map (shared dataset copied once) |
| `vm/prefault.py` + `PREFAULT=1` in `snapshot.sh` | 14 + 8 | fault the memory file's allocated extents through a mapping after `/snapshot/create` (the TrainTicket requirement) |
| `vm/guest-generic/…/quiesce` | +1 | Redis `BGSAVE` in the in-guest quiesce |

## Unsupported / mocked dependencies

| dependency | where used | status | notes |
|---|---|---|---|
| ActivityPub federation (deliveries, remote fetches, WebFinger) | Sidekiq `push`/`pull`/`ingress`, `Fetch*`/`Resolve*` services | **sinked** | `http_proxy=http://sink:8080`: every outbound request gets a 502 from nginx and is logged; jobs fail and retry within Sidekiq's own policy. No remote account or status ever exists, so nothing is lost that the benchmark exercises |
| link previews / oEmbed | `FetchLinkCardService` | **sinked** | same proxy; no generated status carries a URL |
| e-mail | Devise, notification mailers | **mocked** | SMTP → Mailpit (`SMTP_SERVER=mailpit`, auth none); confirmations and digests land in Mailpit's inbox |
| object storage (S3) | Paperclip | **replaced** | `S3_ENABLED=false` → local files under `/tank/md-system` (upstream's own default) |
| Elasticsearch | full-text search, `chewy` | **disabled** | upstream ships it commented out; `ES_ENABLED=false`. Search endpoints fall back to DB or return nothing |
| DNS for e-mail validation | `EmailMxValidator` on user creation | **satisfied locally** | `web` aliased as `mastodon.test` on the internal network, so the validator's A lookup resolves without leaving the network |
| Tor/privoxy, external OIDC/LDAP/SAML | optional | **not configured** | not part of the default compose |

## Fidelity trades

| trade | what is lost | why accepted |
|---|---|---|
| generated content written at the data plane, not through the API | statuses never went through `PostStatusService`: no Sidekiq fan-out ran for them, no streaming pushes, no `preview_cards`, no `mentions`/`tags`; local `uri` and `conversation` rows are set the way the app sets them, `status_stats`/`account_stats` recomputed | 100M statuses through the API would be days of Sidekiq work; the core (admin, the probe's own statuses) is made through the app |
| generated accounts have no key pair and empty ActivityPub URLs | signing outbound requests | the app's own admin account has none either; nothing outbound exists |
| Redis home feeds are not populated for all 3.5M users | feeds are regenerated on first access (`RegenerationWorker`, 206 until done) — Mastodon's own behaviour after a Redis loss | rebuilding 3.5M feeds is the app's `tootctl feeds build`, hours; the heavy-follow probe account's feed is built and recorded |
| Postgres tuned (`shared_buffers` 2 GB, `maintenance_work_mem` 1 GB, `max_wal_size` 16 GB, …, `shm_size: 4g`) | nothing functional | the image's 128 MB default is not a production setting; tuning is ops, not app. `shm_size` because Docker's 64 MB `/dev/shm` breaks parallel query on a 100M-row table |
| the "PR" is one Ruby line layered onto the prebuilt image, not a full image build | asset compilation is not exercised | a full Mastodon image build is ~15 min of `vite build`; a backend change does not need it |
| v4.7.2 prebuilt images, not a source build | none | the compose is written for the prebuilt images |

## Decisions made by hand (not by onboard.sh)

| # | decision | why the tooling could not make it |
|---|---|---|
| 1 | publish on 3300/4300 instead of 3000/4000 | the spec has no notion of host port conflicts; needs a port-offset rule like `mkfork-generic` |
| 2 | `LOCAL_DOMAIN=mastodon.test` + network alias for the e-mail validator | app-specific; belongs in the app's hooks, where it now is |
| 3 | Postgres tuning (`shared_buffers` etc.) for a 100M-row load in an 8 GiB guest | app/size-specific ops choice; in the override, recorded |
| 4 | 3.5M accounts so five accounts can hold 3M followers each | the brief's skew implies it; a generator parameter |
| 6 | home feeds: an API read of a missing home feed serves `200 []` in 4 ms and never triggers a rebuild — only a web sign-in does (`User#regenerate_feed!` → `RegenerationWorker`, 206 until done). The probes, the alternative baseline and the VM fork measure now call `regen-feed.sh` (a `rails runner` doing what the sign-in does) and time the 206→200 transition | app semantics no tool can infer; found because the first probe run waited 5 min on an empty 200 |
| 5 | guest port binds: the override's `127.0.0.1:3300` would be loopback-only inside the VM; interpolated `${MD_BIND:-127.0.0.1}:${MD_WEB_PORT:-3300}` with a guest-only env file (`VM_ENV_FILE`); the sink's nginx config moved inline (`configs: content:`) because a host path bind cannot exist in the guest; `.env.production` reaches `/opt/app` via `EXTRA_COPY`; rootfs 12 GiB, zvol 128 GiB | port publication and host-path mounts are the two things a Compose file says about *its host*; the builder can copy files (`EXTRA_COPY`) but cannot know which binds are host-specific. Found by reading the override against `build-rootfs-generic.sh` before the build, not by a failed boot |

## System inventory

Cloned `mastodon/mastodon` at **`v4.7.2`** (`3987b9f`, latest stable by `git ls-remote` sort -V) into
`/tank/work/mastodon`, 10.7 s shallow clone. Deployment: the repo's own `docker-compose.yml`, which is
marked "designed for production server deployment".

| | |
|---|---|
| processes | `web` (puma, `ghcr.io/mastodon/mastodon:v4.7.2`, 1.39 GB), `sidekiq` (same image, Sidekiq 8.1.6), `streaming` (`mastodon-streaming:v4.7.2`, Node, 516 MB) |
| databases | `db` postgres:14-alpine (415 MB; `POSTGRES_HOST_AUTH_METHOD=trust`), `redis` redis:7-alpine; Elasticsearch commented out upstream and `ES_ENABLED=false` here |
| compose hygiene | healthchecks on all five services (pg_isready, redis-cli ping, `/health`, `/api/v1/streaming/health`, `ps … sidekiq 8`); `depends_on` without conditions; volumes `./postgres14`, `./redis`, `./public/system`; two networks, `internal_network` already `internal: true` |
| required config | `.env.production` (compose `env_file`, **not shipped**): `LOCAL_DOMAIN`, `DB_*`, `REDIS_*`, `SECRET_KEY_BASE`, `OTP_SECRET`, `VAPID_*`, `ACTIVE_RECORD_ENCRYPTION_*`, `SMTP_*`, `S3_ENABLED`, `ES_ENABLED` |
| outbound calls | ActivityPub delivery + remote fetch (`Fetch*Service`, `Resolve*Service`, Sidekiq `push`/`pull` queues), link previews (`FetchLinkCardService`, oEmbed), email (SMTP), S3 when `S3_ENABLED`. All HTTP goes through `Request` → `HTTP::Client`, which honours `http_proxy` (`config/initializers/http_client_proxy.rb`) — the hook for the sink |
| scheduled jobs | Sidekiq-scheduler in `config/sidekiq.yml`: scheduled statuses every 5 m, trends/pubsub every 5–6 h, and 8 daily crons (media/preview-card cleanup, IP cleanup, user cleanup, backups, indexing, vacuum, follow recommendations) at randomised night-time hours; queues `default, push, ingress, mailers, pull, scheduler, fasp` |
| init steps | mint secrets (`rails secret` ×2, `mastodon:webpush:generate_vapid_key`, `db:encryption:init`), `rails db:setup` (schema + seeds), `tootctl accounts create <user> --email … --confirmed --role Owner --approve` |
| host conflicts | 3000 and 4000 are both bound on this host (the specimen's frontend and a `fork1` project) → published on 3300 / 4300 |

## Cold attempt: the TrainTicket `onboard.sh` pointed at Mastodon

`TT_DIR=/tank/work/mastodon-cold TT_TAG=v4.7.2 benchmarks/trainticket/onboard.sh` → **stops at step 1
in 1 s**: "clone FudanSELab/train-ticket @ v4.7.2 — Remote branch v4.7.2 not found". The upstream URL is
hardcoded. Read forward (not run, because the next step destroys `tank/tt-*`, which this session may
not touch), every later step is TrainTicket-shaped:

| step | what it assumes | gap class |
|---|---|---|
| `reset-state.sh` | stateful services are named `*-mongo`/`*-mysql`, datasets are `tank/tt-*` | generic: needs a service→dataset map from the app spec |
| `tt.sh up` | `tt.env` + `docker-compose.tt.yml` (TrainTicket's probes and binds) | generic: compose files + env from the spec |
| `scale/gen.sh` | TrainTicket's Mongo generator | app-specific by nature |
| `snapshot.sh` | `fsyncLock` on `*-mongo-1`, clean stop of `*-mysql-1` | generic: quiesce by image (postgres/mongo/mysql/redis), stateful set from the map |
| `vm-data.sh` | copies `tank/tt-*@tt-base` per `vm-data.map` | generic: map-driven |
| `vm.sh` | every knob hardcoded for TrainTicket | generic: spec-driven |
| readiness | `probe.sh` is login + ticket search | app-specific by nature |

So the "generic onboarding" is, today, the generic *runtime* (`vm/*`, `mkfork-generic`) plus a
TrainTicket runbook. The runbook itself is the gap: an app spec (repo, tag, compose files, env, a
service→path→dataset map, hooks for init/probe/generate) and an `onboard-generic.sh` that drives the
existing pieces from it. That is what this exercise builds; Mastodon-specific pieces go in
`benchmarks/mastodon/` and are counted.

## Protocol results

### Step 3 — native boot on the host (state on ZFS)

| | |
|---|---|
| deployment | upstream `docker-compose.yml` @ `v4.7.2` + `benchmarks/mastodon/compose/docker-compose.md.yml` (70 lines) |
| images | 6: `ghcr.io/mastodon/mastodon:v4.7.2` 1.39 GB, `mastodon-streaming` 516 MB, `postgres:14-alpine` 415 MB, `redis:7-alpine` 58 MB, `axllent/mailpit` 51 MB (SMTP sink), `nginx:alpine` 94 MB (HTTP sink); **2.5 GB**, 27 s to pull |
| admin | `tootctl accounts create admin --email admin@mastodon.test --confirmed --role Owner --approve` — after aliasing the `web` container as `mastodon.test` on the internal network: Mastodon's `EmailMxValidator` resolves the e-mail domain (MX, then A) and treats `example.com`'s null MX as unreachable; the alias makes account creation work with no external DNS, in forks too |
| init | `init-env.sh` mints `SECRET_KEY_BASE`/`OTP_SECRET`/VAPID/encryption keys with Mastodon's own tasks (4 throwaway containers) and writes `.env.production`; `rails db:setup` **7 s** (schema + seeds); admin via `tootctl accounts create` — see below |
| readiness definition (`probe.sh`) | `GET /api/v1/instance` = 200 with `X-Forwarded-Proto: https` + `Host: LOCAL_DOMAIN` (production has `force_ssl = true` and a host allow-list), streaming `/api/v1/streaming/health` = `OK`, and Sidekiq processing: a status posted through the API fans out, queues drain, `Sidekiq::Stats.processed` advances |
| **cold boot** (`up --wait`, 7 services, initialised DB) | **61.9 s**; web + streaming ready at **65.6 s** |
| **ready** (all three signals) | web+streaming at 65.6 s; Sidekiq verified: status posted → 4 jobs processed, queues drained in 20 s |
| **RAM at idle** | **932 MiB**: web 458, sidekiq 307, streaming 123, db 30, mailpit 8, redis 4, sink 2 |
| outbound | `http_proxy=http://sink:8080` on web/sidekiq/streaming (Mastodon's `HTTP::Client` honours it) → every federation delivery, remote fetch and link preview gets a 502 from nginx and never leaves; SMTP → Mailpit; `S3_ENABLED=false` → files under `/tank/md-system` |

### Step 4 — data generation (two runs; final numbers in the Result table below)

**Result (run 2)** — ready natively again at 16:52 UTC (probe: instance 200, streaming OK, post 200, Sidekiq processed 4 in 5.0 s).

| item | value |
|---|---|
| rows | statuses **107,947,907** (100,000,000 originals + 7,947,907 reblogs), notifications **49,942,192** (follow 19,982,123 / favourite 22,012,162 / reblog 7,947,907), follows **19,982,123**, favourites 22,012,162, conversations 100,000,000, status_stats 28,210,502, accounts 3,500,003, users 3,500,002, account_stats 3,500,003 — **≈ 338M rows** |
| skew | five accounts with **3,000,001 followers** each (`u1554671 u2418624 u3019588 u3040254 u172957` — "heavy" is whichever five `gen_accounts` numbers first, not `u1..u5`), 480k–1.05M statuses each, 3.14–3.31M notifications each; `heavyfollower` follows 5,000 accounts including all five; long tail next: 1,775 and 1,577 followers; statuses 2023-09-21 … 2026-09-21 (3 years, `power(g/n, 1.6)` skew to recent) |
| generator wall | run 2: **load 89 min** (15:04:43–16:33:38), index rebuild **12.5 min** (23 indexes, 16:33:58–16:46:25, parallel), FK validation **160 s** (17 pairs, 0 orphans, standalone after the shm fix), VACUUM ANALYZE **41 s**; **≈ 1 h 47 min** end to end. Run 1 (aborted, RI triggers on): 79 min for accounts + follows + conversations + the statuses heap, then killed in the RI tail. Step 4 wall clock incl. the abort and my debugging: 13:41–16:52, 3.2 h |
| rows/s | 338M rows / 5,335 s = **63k rows/s** over the load; statuses originals 100M in 40 min = 42k/s (95k/s for the first 78M, ~15k/s in the tail as the hash join with the 100M-row source spilled) |
| on disk | Postgres logical **89 GB** (statuses 25 GB heap + 28 GB indexes; notifications 6.5 + 9.3; conversations 5.0 + 2.1; status_stats 2.7 + 1.2; favourites 1.4 + 2.3; follows 1.6 + 1.6); ZFS `tank/md-pg` **45.8 GB used, 104 GB logical, compressratio 2.27×** (lz4); redis 112 KB; system 96 KB |
| Redis home feeds | **not populated by the generator.** Mastodon rebuilds a missing home feed on demand (`RegenerationWorker`, API answers 206 until done) — measured in the probes for `heavyfollower`; the bulk path is `tootctl feeds build`, which for 3.5M users would take days and is recorded, not run. The five heavy accounts' own feeds regenerate the same way |
| pre-registered prediction | rows and shape as predicted; logical size 89 GB in the 85–95 range; on-ZFS 45.8 GB above the predicted 35–40; compressratio 2.27× vs. 2.4×; load 89 min vs. 55 predicted (two things unpredicted: the RI tail, and reblog ids scattering across the primary key); index rebuild 12.5 min vs. 25–35 predicted; done 16:52 vs. 15:00–15:15 |

**perf profile of the backend (15:00 UTC, 3 s sample, `perf record -p`)**: `afterTriggerInvokeEvents`
on the Postgres side, the rest spread over `hash_search_with_hash_value`, musl `memcmp`, and — a
third of the samples — kernel page-fault/unmap paths (`do_anonymous_page`, `zap_pte_range`,
`__handle_mm_fault`, `kmem_cache_alloc`): each trigger invocation allocates and frees a memory
context, and the alpine image's musl malloc hands that back to the kernel every time. That is
the RI queue being drained, not the load.

**Abort decision (15:00:29 UTC, on instruction)**: the run was 79 min in. Continuing meant an
RI tail of unknown length on statuses (25 min so far, no progress counter: 400M queued events)
plus the same tail on reblogs (10M rows × 4 FKs), favourites (22M × 2) and notifications
(50M × 2) — ≥ 60 min more of single-threaded trigger work on top of ~25 min of heap writes,
i.e. the earliest plausible end was ~16:30 with a real chance of 17:00+. Restarting with RI
triggers disabled repeats the 16 min of accounts/follows/conversations and the 37 min statuses
heap write, and the remaining loads become pure heap writes (~20 min): load ≈ 75 min, done
≈ 16:15, before index rebuilds (~30 min) and the FK validation (~8 min of anti-joins). Restart
wins by 15–45 min and removes the variance; the kill (`kill -9` on `gen.sh`, so its
index-restoring trap did not spend 30 min rebuilding indexes on data about to be dropped, then
`pg_cancel_backend`) took 8 s and `reset-db.sh` returns the schema to post-init.

**Run 2 (RI triggers off), 15:04:43–16:33:38 load**: accounts 40 s, users 40 s, follows 20M in
75 s (vs. 13 min in run 1), conversations 100M in 3.7 min, statuses originals 100M in 40 min
(15:11–15:51, no tail), reblogs 10M in 22 min (ids scattered over the 3-year range → random
inserts into the 100M-entry primary key; the originals appended in order), favourites 22M in
100 s, notifications ~50M in 13.4 min (the favourite third joins 22M rows against statuses by
pkey), account_stats 60 s, status_stats ~110M in 3.3 min, totals 20 s. **Load 89 min.**

**Validation stopped after 3 of 17 FK pairs (all 0 orphans, ≤ 1.4 s each)**: the fourth anti-join
(favourites → statuses) went parallel and Postgres could not get its dynamic shared memory —
`could not resize shared memory segment … No space left on device`: Docker's default 64 MB
`/dev/shm`, which Mastodon's compose does not raise. The specimen hit the identical wall in
its first experiment (`docs/FORK-EXPERIMENT-1.md`, experiment 3, `shm_size: 1g`). The failure
tripped `gen.sh`'s exit trap, which is rebuilding the 23 indexes as the normal path would; the
data is committed. Fix: `shm_size: 1g` on `db` in the override (an ops setting the runtime should
add to any Postgres it runs; the probes' parallel plans would have hit it too), applied by
recreating `db` after the rebuild; the validation is then rerun standalone
(`pg-bulk-load-end.sql` alone) and its 17 counts recorded below.

**What changed**: the generic bulk-load profile `benchmarks/lib/BULK-LOAD.md` +
`pg-bulk-load-begin.sql` (synchronous_commit off, work_mem, `session_replication_role = replica`)
+ `pg-bulk-load-end.sql` (re-enable, then one anti-join per FK pair from `pg_constraint`;
orphans must be 0, counts printed, exception otherwise); `gen.sh` concatenates them around
`gen.sql` and passes the loaded-table list. The specimen's bulk-load profile
(`data/scale/README.md`) and TrainTicket's `gen.sh` carry the rule too.


Observed mid-run (14:45 UTC): the 100M-row originals INSERT wrote its heap (24.97 GB) in 37 min
(13:58–14:35, ~45k rows/s, `synchronous_commit=off`, indexes dropped) and then went CPU-bound with
no I/O for 10+ min at 7 GB RSS: statuses keeps four foreign keys (account, in-reply-to,
in-reply-to-account, reblog-of), and Postgres queues one after-trigger event per row per FK for
the whole statement and runs the 400M checks at statement end — 100M real index probes into
`accounts`, 300M null-key no-ops, single-threaded. The generator drops secondary indexes but
not FK triggers. Lesson for `gen.sql`: `SET session_replication_role = replica` (or
`DISABLE TRIGGER ALL` on the loaded tables) for a load whose ids are correct by construction;
the RI tail will repeat on reblogs, favourites and the 50M notifications. Not changed mid-run.

### Step 5a — scale probes at full volume (native, 17:04 UTC, 20 requests each after one warm-up pass)

Two runs. The first (16:55) was the cold one — first touch after the `db` recreate — and its
regeneration trigger did not work (`User#regenerate_feed!` is private; the API served `200 []`
for 313 s); the second (17:04) had the trigger fixed and a warmer cache. p95 over 20 requests is
effectively the slowest request, i.e. the first touch.

| probe | run 1 p50 / p95 (cold-ish) | run 2 p50 / p95 | > 250 ms? |
|---|---|---|---|
| home timeline, `heavyfollower` (5,000 followed, 5 mega) | 3 / 3 ms (empty feed: `200 []`) | **55 / 149 ms** | no |
| → feed rebuild, trigger → first 200 with 20 statuses | — (never triggered) | **2.5 s** | `RegenerationWorker`: 800 items; `populate_home` skips every followed account whose `last_status_at` is older than the feed's oldest item once the feed is full, so 5,000 accounts cost ~5,000 `account_stats` lookups, not 5,000 status scans |
| public timeline (`local=true`) | 32 / 308 | 37 / 96 | run 1 first touch only |
| notifications v1, `u3019588` (3.0M followers, 3.3M notifications) | 39 / 201 | 43 / 120 | no |
| grouped notifications v2, same | 41 / 335 | 43 / 181 | run 1 first touch only |
| account lookup | 3 / 36 | 4 / 10 | no |
| account statuses (1.05M statuses) | 28 / 226 | 32 / 42 | no |
| **followers of `u3019588`, page 1 (40)** | **385 / 3,381** | **354 / 1,729** | **yes, at p50** |

**The one real scale problem — followers page of a 3M-follower account** (`Api::V1::Accounts::FollowerAccountsController`):

```
SELECT DISTINCT follows.id, accounts.id FROM accounts
  LEFT JOIN follows ON follows.account_id = accounts.id
  LEFT JOIN account_stats … LEFT JOIN users …
 WHERE follows.target_account_id = $1 ORDER BY follows.id DESC LIMIT 40
```
`EXPLAIN (ANALYZE, BUFFERS)`: `Parallel Index Scan Backward using follows_pkey` with
`Rows Removed by Filter: 3,396,424` per worker (×5) — 17M of the 20M `follows` rows walked
backwards by id before 40 rows for this target turn up; **316,866 shared buffers (2.5 GB)**
per page-1 request, all hits when warm (354 ms), reads when cold (1.7–3.4 s). The `DISTINCT`
is not the cost (without it: same scan, 268k buffers); the missing index is
`(target_account_id, id DESC)` — `index_follows_on_target_account_id_and_account_id` cannot
serve an `ORDER BY follows.id`. Caveat that makes it worse here than in production: the
generator inserted the five mega accounts' 15M follows first, so their ids are the lowest and a
backward scan passes everything else first; with time-interleaved ids the scan would stop
sooner but still walk ~1/6 of the table per page on average.

Prediction scored: notifications (predicted the >250 ms candidate) came in at 120–181 ms warm —
the partial `group_key` index carries it; the followers page, which I predicted under 100 ms,
is the outlier. Home feed rebuild 2.5 s vs. the predicted 30–90 s (the `over_limit` skip).

### Step 5b — a migration strong_migrations would refuse, on the 107.9M-row `statuses` (native, 17:05–17:11 UTC)

App services stopped for the experiment (Sidekiq's schedulers write); each naive form ran inside
`BEGIN … ROLLBACK`, the lock read from a second session 3 s in. Nothing left behind.

| migration | lock held on `statuses` | duration | reads | writes |
|---|---|---|---|---|
| naive `CREATE INDEX … (language, id DESC)` | **ShareLock** | **86.9 s** | continue | **blocked 87 s** |
| naive `ALTER COLUMN language SET NOT NULL` | **AccessExclusiveLock** | **45.2 s** | **blocked 45 s** | **blocked 45 s** |
| safe `CREATE INDEX CONCURRENTLY` (+ `DROP INDEX CONCURRENTLY` 0.2 s) | ShareUpdateExclusiveLock | 150.0 s (1.7×) | continue | continue |
| safe `ADD CONSTRAINT … CHECK (language IS NOT NULL) NOT VALID` then `VALIDATE` (separate transactions) | ShareUpdateExclusiveLock during VALIDATE | 39.3 s | continue | continue |
| then `SET NOT NULL` (Postgres skips the scan when a valid CHECK exists) | AccessExclusiveLock | **0.1 s** | — | — |

Predictions: naive index 3–6 min → 87 s (parallel build, 6 workers, `maintenance_work_mem` 1 GB);
SET NOT NULL 1–2 min → 45 s; CONCURRENTLY 1.5–2× → 1.7×; the CHECK/VALIDATE path "same scan,
nothing blocked, then SET NOT NULL in ms" → 39 s + 0.1 s. Note `migration.sh` initially ran the ADD
and the VALIDATE in one `-c`, i.e. one transaction, which would have held the ADD's ACCESS EXCLUSIVE
lock through the scan — caught on review before the run, and the kind of thing a fork exists to
catch after.

### Step 5c — quiesce, clean stop, `@md-base` (native, 17:13 UTC)

`VACUUM=1 vm/app-snapshot-native.sh benchmarks/mastodon/app.spec md-base`: VACUUM ANALYZE +
CHECKPOINT + Redis BGSAVE **22.9 s**, `compose stop` **2.1 s** (Postgres shuts down in a
blink after the checkpoint), three `zfs snapshot`s **0.1 s**, `compose start` 31.1 s;
**total frozen 33.3 s** (predicted 20–30 s). App ready again 17:14:05 (instance 200, streaming
OK, post 200, Sidekiq processed 3). `tank/md-pg@md-base` refers 43.4 GB.

First attempt discarded: the generic native quiesce ran `VACUUM ANALYZE` against
`${POSTGRES_DB:-postgres}` — Mastodon's db container carries no `POSTGRES_DB` (the name lives
in the app's env), so it vacuumed the empty `postgres` database in 1.0 s and said so
convincingly. Fixed generically with `vacuumdb -a -z` (every database in the cluster); the
snapshots were destroyed and retaken. A tooling lesson: "which database" is app knowledge the
runtime must not guess from the container.

### Step 6a — Compose fork on ZFS (17:17 UTC)

`benchmarks/mastodon/fork.sh 1` (`vm/mkfork-generic.sh` with the fork map from the spec, port
offset +20000, project `md-f1`):

| item | value |
|---|---|
| clones + override | **0.22 s** (3 clones of the 43 GB `@md-base`) |
| `up --wait` → 7/7 healthy | **61.9 s** (native cold boot was 61.9 s too — a fork boots exactly like the original) |
| ready per the probe (instance 200, streaming OK, a status posted and its jobs processed) | 106.2 s (the Sidekiq part takes 38.6 s here and natively alike) |
| isolation | status `fork-1-probe` posted through the fork: **native=0, fork1=1** |
| RAM (cgroups, all 7 containers) | **2,094 MiB** (native idle was 932 MiB; the fork has just booted, served a probe and run jobs, and Postgres is holding its 2 GB `shared_buffers` warm) |
| storage delta | **< 1 MiB** across 3 clones after the probe's writes |

The first attempt failed its probe on a missing `.token` (`reset-db.sh` prints the token, `init-app.sh`
writes it; I had kept it in the scratchpad) — repeated with the file in place; the numbers above
are the repeat. Torn down after the measurement (`unfork.sh 1`), so the host is clean for the VM series.

Re-measured at 18:05 with the isolation query going through the admin's index (see series 1 of the VM
forks for why): clones 0.22 s, healthy **62.0 s**, ready 106.3 s, isolation native=0 / fork1=1,
**RAM 2,149 MiB** (cgroups), storage < 1 MiB — the 2.1 GB is the fork's real footprint (a Postgres
whose 2 GB `shared_buffers` fill while it serves the probe, plus ~1 GB of Rails/Node), not the scan.


### Step 6b — Firecracker path (from 17:20 UTC)

Rootfs: `vm/app.sh … build` (generic builder, 6 images, `SIZE_MB=12288`) — 3 min the first
time, 61 s the rebuild after the `shm_size` change (`docker save` on this Docker 29 writes
compressed layers: 587 MB for 2.5 GB of images). Zvol: first attempt failed in 0.3 s —
`vm/app-zvol.sh` and `app-datasets.sh create` used `/<dataset-minus-tank>` (`/md-pg`) as the
mountpoint convention while everything else (`mkfork-generic`, the hand-made datasets, the
compose binds) uses `/<dataset>` (`/tank/md-pg`); never exercised before because the datasets
pre-existed. Fixed generically to `/$ds`; the empty 128 GiB zvol destroyed and rebuilt.
Zvol built 17:20:48–17:25:47: **101 GB copied in 261 s** (~390 MB/s of logical data through
`cp -a` from the `.zfs/snapshot` directory), 4:58 with mkfs and the snapshot; on ZFS the zvol
refers **59.9 GB at 1.68×** (16 KiB volblocks compress worse than the dataset's 128 KiB records:
2.27×) — predicted 2–4 min and "the surprise cost"; it is the longest single step of the VM path.
`tank/md-vm-data@md-base` taken.

**Bake** (17:26, 1 m 29 s wall): scratch VM 9 loaded the 6 images and reached ready 80.5 s after
its boot; image store 1.7 GB; rootfs promoted with **2,654 MiB used of 12,288**.

**Boot 1** (17:27:52, `vm/app.sh … boot 1`, 4 vCPU, **8,192 MiB**, `/dev/vdb` = clone of the zvol):
web `/health` 200 at **40.4 s**, guest self-report "all containers healthy" at **64.3 s**
(native `up --wait` was 61.9 s: the VM costs nothing measurable here). Full readiness checked
from the host + over ssh: instance 200, streaming OK, a status posted and its 4 jobs processed
in 2 s. Guest memory at ready: **2,307 MiB used + 991 MiB shared (Postgres' 2 GB
`shared_buffers` as they fill) of 7,965; 5,658 available** — 8 GiB holds with room; it is the
right size, not a floor to raise. `/data` 101 GB of 125 GB.

**Snapshot 1 → `mdbase`** (17:29:48, `PREFAULT=1 vm/app.sh … snapshot 1 mdbase`, 18.3 s wall):
in-guest quiesce = Redis BGSAVE + Postgres CHECKPOINT + sync + `fsfreeze /data`; **pause 0.005 s,
`/snapshot/create` 1.70 s, zfs snapshot 0.035 s, rootfs copy 4.34 s, resume 0.007 s;
`/data` frozen → thawed 6.33 s**. Memory file 8,192 MiB apparent, **1,528 MiB allocated on
disk, 4.5 GiB of data extents** (lz4 under it); vmstate 50 KB. **Pre-fault: the 4.5 GiB of
allocated extents touched through a mapping in 11.2 s** after the create (posix_fadvise and
read() are no-ops on ZFS for this purpose — the TrainTicket lesson, now the default via
`PREFAULT=1`). Source VM still healthy afterwards. Prediction: 3–4 GB allocated → 4.5 GiB of
extents / 1.5 GiB on disk; window "~12 s unless the rootfs is shrunk" → 4.3 s copy at 12 GiB.

Fork series started 17:30 (`vm-fork-measure.sh mdbase k`, k = 1..10; `--probe` on 1 and 10;
no requests to a fork before its 120 s PSS sample). Source VM 1 left running (it holds 8 GiB
of guest RAM; counts against the headroom rule).

**Series 1 aborted after 2½ forks (17:37)** — my measurement bug, not the runtime's: the
isolation check asked each fork's Postgres `select … from statuses where text like
'vmfork-%-probe'`, a **sequential scan of the 25 GB statuses heap**, which streamed the table
through the guest's page cache and turned a fork that idled at 815–1,008 MiB PSS into a
**6.8 GB RSS** process on the host (`AnonPages` +5 GiB per fork; ARC at its 8 GiB cap) — the
10 GiB headroom rule would have tripped around fork 6 for a reason that has nothing to do with
forking. The two completed forks were otherwise clean: t_restore 2.415 / 2.422 s (t_load 26 /
30 ms), PSS@120 s 1,008 / 815 MiB, isolation correct, streaming OK, Sidekiq processed 4 / 7,
heavy home timeline in fork 1 served in 0.5 s (its feed was in the snapshot's Redis), storage
delta 1 MiB. Query changed to go through the admin's `(account_id, id)` index (same fix in the
Compose `fork.sh`, whose 2,094 MiB cgroup figure includes the same scan's page cache); forks
torn down; series 2 from fork 1 with the headroom rule enforced in the loop.

**Series 2 — 10 forks of `mdbase`, 17:38:46–18:01 UTC** (`vm/out/md-forks.csv`; each fork: restore, no requests for 120 s with PSS sampled at 10/60/120 s, then one status posted + Sidekiq checked + streaming health + storage delta):

| fork | t_load | t_restore_to_api_response | PSS @10 s | @60 s | **@120 s** (anon / file) | RSS @120 | isolation | streaming | Sidekiq | storage Δ | host avail. after |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 25 ms | 2.405 s | 987 | 1121 | **1206** (251 / 955) | 1208 | own status only | OK | +7 | 1 MiB | 39 GiB |
| 2 | 23 ms | 2.454 s | 641 | 746 | **774** (254 / 519) | 1223 | ✓ | OK | +7 | 1 MiB | 39 |
| 3 | 26 ms | 2.467 s | 495 | 585 | **595** (240 / 355) | 1181 | ✓ | OK | +7 | 1 MiB | 38 |
| 4 | 24 ms | 2.418 s | 411 | 494 | **524** (246 / 278) | 1204 | ✓ | OK | +8 | 1 MiB | 38 |
| 5 | 25 ms | 2.469 s | 381 | 462 | **481** (247 / 233) | 1221 | ✓ | OK | +7 | 1 MiB | 37 |
| 6 | 23 ms | 2.428 s | 342 | 423 | **443** (244 / 199) | 1203 | ✓ | OK | +7 | 1 MiB | 37 |
| 7 | 23 ms | 2.421 s | 323 | 402 | **410** (233 / 176) | 1136 | ✓ | OK | +7 | 1 MiB | 37 |
| 8 | 25 ms | 2.466 s | 322 | 396 | **406** (243 / 163) | 1180 | ✓ | OK | +7 | 1 MiB | 36 |
| 9 | 25 ms | 2.414 s | 302 | 390 | **396** (252 / 144) | 1208 | ✓ | OK | +9 | 1 MiB | 36 |
| 10 | 31 ms | 2.441 s | 301 | 379 | **395** (259 / 135) | 1237 | ✓ | OK | +7 | 1 MiB | 35 |

- **t_restore_to_api_response: p50 2.434 s, p95 2.467 s, min 2.405, max 2.469 (n = 10)**; `t_load` p50 25 ms. The first restore of the fresh snapshot (series 1, fork 1, 17:30) was **2.415 s** — with the pre-fault there is no cold case left to see: the memory file's 4.5 GiB of extents were already resident.
- **PSS @120 s idle: median 462 MiB** (8 GiB guest), sum **5.63 GB for 10 forks**; the private (anon) part is a flat **~245 MiB per fork** (sum 2.47 GB) and the file part is the shared memory-file pages split ever more ways — fork 10 carries 135 MiB of them. Marginal fork from the 6th on: ~400 MiB of PSS.
- **After work** (a post, its 7–9 jobs, streaming health, the isolation query; fork 1 and 10 also served the heavy home timeline): 564–999 MiB PSS each at 18:01 (source VM 1, which ran the probes and the snapshot: 4.67 GB).
- **Isolation**: every fork's Postgres holds exactly its own `vmfork-k-probe` status and none of the other nine's; storage delta **1 MiB per fork** on the zvol clone.
- **Heavy home timeline** inside forks 1 and 10: **0.7 s / 0.5 s** to a 200 with statuses — the feed was in the snapshot's Redis, so a fork opens with warm caches, which is the point.
- **Ceiling: none reached.** 10 forks + source: host 35 GiB available of 62 (rule: ≥ 10). Memory says ~35 more forks at the idle marginal cost; the count ended at the target.
- Predictions scored: t_restore 3–4 s warm → 2.43 s; PSS 600–900 MiB → 462 median (Sidekiq's polling did not double it); ≥ 10 forks → 10, measurement ended, not the rule.

**Warm restore series** (`vm/restore-series.sh`, new and generic: fork slot 11 / measure / unfork, ten
times in a row, 18:03–18:04, with the ten sibling forks and the source alive):
**t_restore_to_api_response p50 2.434 s, p95 2.479 s** (2.410–2.479), `t_load` p50 26 ms, p95 29 ms.
Steady state equals the ten forks' own restores (p50 2.434 / p95 2.467) and the fresh-snapshot
first restore (2.415 s): the memory file being pre-faulted, there is no variance left to
measure — the TrainTicket 13–18 s cold case does not occur. Two tooling fixes on the way:
`restore-series.sh` swallowed a failed unfork (now surfaced), and `vm/unfork.sh` hit
`cannot destroy … dataset is busy` — the zvol clone stays busy for a moment after firecracker
exits; it now retries the destroy for up to 5 s (generic, default behaviour unchanged).







### Step 6c — PR → changed system serving, inside a VM fork (18:04–18:12 UTC)

The "PR": one line in `lib/mastodon/version.rb` (`build_metadata` falls back to `'pr1'`, so
`/api/v1/instance` reports `4.7.2+pr1`), layered on the prebuilt image by a two-line Dockerfile
(a full Mastodon image build is a ~15-min asset compile a Ruby-only change does not need).
`pr-swap.sh <k>`: build → `docker save | ssh` into the fork → `docker load` + retag + `compose up
--no-deps --force-recreate web sidekiq` → poll the version.

| run | fork | build | ship | load + swap | recreated web serving `pr1` | **total** | siblings |
|---|---|---|---|---|---|---|---|
| 1 (18:04) | 1 | 3.8 s (cold) | — | — | — | not timed: the in-guest `compose up` ran without the guest env file, so the recreated `web` bound `127.0.0.1:3300` and vanished from the host; the fork did serve `pr1` once recreated with the env file | 2, 3 on 4.7.2 |
| 2 (18:08) | 2 | 1.7 s | — | — | — | not timed: the poll's `curl` got "connection refused" while `web` was being recreated and `set -e` + `pipefail` killed the script; fork 2 served `pr1` 60 s later | — |
| **3 (18:10)** | 3 | **1.7 s** | **2.6 s** | **3.8 s** | **58.8 s** | **66.9 s** | forks 1–3 on `4.7.2+pr1`, fork 4 (and 5–10) on `4.7.2` |

**PR → serving 66.9 s, of which 58.8 s is Rails booting** in the recreated container (Mastodon
eager-loads in production; the native `up --wait` of 62 s is the same boot). Build + ship + load +
swap is **8.1 s**. Prediction 15–25 s was wrong about the boot, right about the plumbing. Two
script defects on the way, both recorded in "what broke".

### Alternative baseline — measured (18:07 and 18:09 UTC, two runs)

`IMAGE=ghcr.io/mastodon/mastodon:v4.7.2-pr alt-baseline.sh up`: ZFS clone of `tank/md-pg@md-base`
as the "Neon branch", empty Redis, empty media, fresh containers of the changed web image, ports
+13000. Version served verified: `4.7.2+pr1`.

| measure | run 1 | run 2 |
|---|---|---|
| (a) `/api/v1/instance` 200 — changed code serving | **63.7 s** | **63.7 s** |
| (b) heavy account's home timeline served with warm caches (sign-in-style rebuild, 206 → 200 with 20 statuses) | **74.9 s** | **74.3 s** |
| Redis keys after | 43 | 43 |
| Sidekiq processed | 2 | 2 |
| (c) every user's feed, (d) Sidekiq's scheduled/retry state, (e) the page cache and `shared_buffers` the snapshot carried, (f) any in-flight request | **cannot reach** | **cannot reach** |

Against the fork: **2.4 s** to a serving fork whose Redis holds the feeds it had, whose Postgres
has its buffers warm, whose Sidekiq resumes mid-schedule — and the changed code inside it in a
further 66.9 s (8.1 s of plumbing + Rails boot). The alternative gets changed code + production-scale
data in 63.7 s and one warm feed in 74 s; the rest of "equivalent state" it cannot produce at all.
Where the alternative's number is *better* is honest to say: for a single-user check of a code
change it is 74 s vs 69 s — a wash. It is everything that is not one user's feed that the clone lacks.

### Alternative baseline — definition (written before measuring)

**What the team would do today** to try a change against realistic state, without the fork runtime: a
database *branch* (Neon-style; here a `zfs clone` of `tank/md-pg@md-base` stands in for it — same
100M-row data, copy-on-write, instant), plus a conventional cold deploy of the changed web app against
that branch: fresh containers from the changed image (`ghcr.io/mastodon/mastodon:v4.7.2-pr`), an
**empty Redis**, a **fresh Sidekiq**, empty media, on offset ports (`alt-baseline.sh`, project `md-alt`).

**Measured, in this order, from `compose up`:**

1. `t_alt_instance_200` — time until `GET /api/v1/instance` returns 200 through the new web
   container: the changed code is serving.
2. `t_alt_home_timeline_warm` — time until `GET /api/v1/timelines/home?limit=20` as `heavyfollower`
   (follows 5,000 accounts) returns **200 with ≥ 1 status**. With an empty Redis, Mastodon answers 206
   while `RegenerationWorker` rebuilds that one feed on demand; 200 means that account's feed is warm.
   This is the nearest thing to "caches warm" the alternative can reach, and only for accounts that
   have been asked for.

**What "equivalent state" means here**, so the row can say what the alternative reaches and what it
cannot: (a) the changed code serving — reachable; (b) production-scale data — reachable, via the
branch; (c) warm Redis home feeds for *all* users — **not reachable** (one feed per first request,
each ~seconds, 3.5M users; `tootctl feeds build` for everyone is hours); (d) Sidekiq's in-flight and
scheduled state (retries, the scheduler's `first_in` timers) — **not reachable**, the fresh Sidekiq
starts from an empty Redis; (e) warmed Rails/ActiveRecord caches and Postgres shared buffers — **not
reachable** by a cold deploy, warmed only by traffic; (f) streaming subscriptions — **not reachable**
(clients reconnect). The fork restores (a)–(f) as they were at the snapshot.

Reported as: `t_alt_instance_200`, `t_alt_home_timeline_warm`, Redis key count and Sidekiq processed
count at that point, and the list (c)–(f) marked "cannot reach it".

### Predictions, written before the measurements (to be scored in the write-up)

| step | predicted |
|---|---|
| generator | done ~15:00–15:15 UTC; ~100M statuses, ~48–50M notifications, 20M follows, ~20M favourites, ~90M conversations; 85–95 GB logical, 35–40 GB on ZFS at ~2.4×; load ~55 min, index rebuild 25–35 min, VACUUM ANALYZE ~5 min |
| probes p95 | account lookup < 20 ms; public timeline < 100 ms; grouped notifications (u1) 100–400 ms ← most likely > 250 ms; home timeline for heavyfollower 206 for 30–90 s then ~50 ms; followers page-1 < 100 ms |
| migration | naive CREATE INDEX 3–6 min under ShareLock; SET NOT NULL 1–2 min under AccessExclusiveLock; CONCURRENTLY 1.5–2× the time, ShareUpdateExclusiveLock only; CHECK NOT VALID + VALIDATE same scan, nothing blocked, then SET NOT NULL in ms |
| native snapshot | quiesce 5–10 s, clean stop 5–15 s, frozen window 20–30 s |
| Compose fork | boot to healthy 60–70 s, ~1 GB per fork, isolation clean |
| Firecracker | rootfs build ~70 s; zvol copy 2–4 min (the surprise cost); bake ~3 min; cold-ready 70–90 s in 8 GiB; memory file 3–4 GB allocated; snapshot window ~12 s unless the rootfs image is shrunk |
| restore forks | t_load ~25 ms; first restore 8–12 s cold, 3–4 s warm with pre-fault; PSS ~600–900 MB idle @120 s; ≥ 10 forks, count ends where measurement ends |
| PR swap | 15–25 s (1.4 GB image: ~10 s of docker load, ~10 s of puma boot) |
| alternative baseline | /instance 200 at 60–70 s; home timeline warm at 120–200 s; (c)–(f) unreachable |
| least sure | notifications p95, idle PSS (Sidekiq polling), the ZFS→zvol copy rate |

## Benchmark protocol — Mastodon beside TrainTicket

| | **TrainTicket 0.2.0** (`benchmarks/trainticket.md`) | **Mastodon v4.7.2** |
|---|---|---|
| system | 41 microservices + 24 Mongo + MySQL + Redis + nginx, 68 containers, JVM | **one Rails monolith** (puma web + Sidekiq 8.1.6 with 7 queues and cron schedulers) + Node streaming + Postgres 14 + Redis 7, **7 containers** with the two sinks — a different architectural family: a monolith with heavy background work, one big database, a cache that *is* application state |
| **time to onboard**, clone → first useful fork | wall-clock 1 h 11 min (Compose), 1 h 30 min (Firecracker); operator hours the same | **wall-clock 4 h 01 min** (Compose fork 1, 17:17), **4 h 14 min** (Firecracker fork 1, 17:30); **4.8 h** of operator activity in total; **native ready at 12 min**. 3 h 11 min of the wall clock was the 100M-row load (an aborted run + the rerun); the runtime path itself — snapshot → zvol → build → bake → boot → snapshot → forks — took 17:13 → 17:30 |
| **adapters written** | 16 files, ~1,050 lines | **20 files, 812 lines**, of which 252 onboard, 225 generate, 335 measure; plus a 58-line generic bulk-load profile every generator now inherits |
| **application changes required** | 0 | **0** |
| dependencies unsupported / mocked | `rest-service-external` absent upstream; nothing mocked | federation, remote fetches, link previews **sinked** (nginx 502 via `http_proxy`); e-mail → Mailpit; S3 off (local files); Elasticsearch disabled as upstream ships it; e-mail-domain DNS satisfied by a network alias. Nothing dropped: streaming and Sidekiq are in every readiness check |
| things shared rather than forked | rootfs reflink, 24 GiB memory file via page cache, image store | same: 12 GiB rootfs reflinked, 8 GiB memory file (4.5 GiB of extents) shared — fork 10 carries 135 MiB of it |
| data preparation | 1.1 h operator; 1M orders in 97.5 s; 607 MiB | **1.67 h operator**; **338M rows** (100M statuses + 7.9M reblogs, 50M notifications, 20M follows, 22M favourites, 100M conversations, 3.5M accounts/users) in **89 min** + 12.5 min of indexes; **89 GB logical, 45.8 GB on ZFS at 2.27×**; 17 FK pairs validated, 0 orphans |
| **cold boot to healthy** | native 81.9 s; microVM UI 17.2 s, all 68 ≤ 154 s | **native 61.9 s** (`up --wait`), 65.6 s to the full probe; **microVM: web 40.4 s, all 7 healthy 64.3 s**, full probe (streaming + a post processed) confirmed |
| scale probes | ticket search 104 s at 1M (collection scan) | followers page of a 3M-follower account **354 ms warm / 1.7–3.4 s cold** (backward pkey scan over 17M rows; needs `(target_account_id, id)`); everything else ≤ 181 ms p95; home feed rebuild 2.5 s |
| rolled-back migration | — | naive `CREATE INDEX` 87 s under ShareLock; `SET NOT NULL` 45 s under AccessExclusive; safe: 150 s concurrently / 39 s validate + 0.1 s |
| snapshot: frozen window / memory file | 19.9 s; 24 GiB apparent, 4.9 GB allocated | **native 33.3 s frozen** (Compose stop → start) · **VM 6.3 s** `/data` frozen, create 1.7 s, rootfs copy 4.3 s; **8 GiB apparent, 1.5 GiB on disk / 4.5 GiB of extents**; pre-fault 11.2 s |
| Compose+ZFS fork: clone / boot / RAM | 0.8 s / 88–89 s / 14.2–14.4 GB | **0.22 s / 61.9–62.0 s / 2.1 GB** (cgroup); storage < 1 MiB |
| **fork-to-serving** (microVM) | 9.9 s first, 5.5–6.4 s after | **2.405 s first (fresh snapshot, pre-faulted), p50 2.434 / p95 2.467 s over 10 forks, p50 2.434 / p95 2.479 s over 10 warm restores**; `t_load` 25 ms |
| **PSS per idle fork @120 s** | 3.0–3.6 GB (24 GiB guest) | **462 MiB median** (8 GiB guest), 395 MiB by the 10th; ~245 MiB private each; 564–999 MiB after a post + jobs + a timeline |
| storage delta per fork | 10–21 MiB | **1 MiB** |
| **max concurrent forks on this box** | 6 + source at the 10 GiB headroom stop (40.4 GB PSS) | **10 + source, measurement ended** — 35 GiB still available (5.6 GB summed PSS); memory allows ~35 more idle forks |
| stateful services recovered cleanly | 24 Mongo, MySQL | **Postgres 14 (100M rows, CHECKPOINT before the snapshot), Redis 7 (BGSAVE), Sidekiq resumed its schedulers and processed 7–9 jobs in every fork, streaming healthy in every fork** |
| PR → changed system serving | 10.8 s (4.8 s inside the fork) | **66.9 s: 8.1 s of build + ship + load + swap, 58.8 s of Rails booting** in the recreated container; siblings untouched |
| alternative → equivalent state | cannot reach it (shared env) | **cannot reach it**: DB clone + fresh deploy gives changed code at 63.7 s and one user's warm feed at 74 s; every other feed, Sidekiq's state, Postgres' buffers, the page cache — not reproducible |
| **fidelity lost** | v0.2.0, image pins, "context up" readiness, generator writes Mongo directly | generated content at the data plane (no fan-out ran for it, no preview cards/mentions/tags); no key pairs on generated accounts; feeds not pre-built for 3.5M users; Postgres tuned + `shm_size`; the PR is one Ruby line on the prebuilt image; prebuilt v4.7.2 images |

## Housekeeping left on disk (the deliverable and its inputs)

`tank/md-pg`, `tank/md-redis`, `tank/md-system` with `@md-base` (43.4 GB referenced); the zvol
`tank/md-vm-data@md-base` (60 GB); `vm/out/md-rootfs.ext4` (12 GiB, baked), `vm/out/snap-mdbase/`
(mem 8 GiB apparent, 1.5 GiB on disk — its ZFS side, `tank/md-vmfork1@mdbase`, went with the source
VM's clone at teardown, so a new fork series starts with `boot 1` + `snapshot 1`), `vm/out/md-*.log`,
`md-forks.csv`, `md-forks-series1-aborted.csv`; the native `md` Compose project is **up** on
3300/4300/8325; `/tank/work/mastodon` (checkout + `.env.production`, secrets, not committed) and the
`mastodon-pr` worktree; images incl. `ghcr.io/mastodon/mastodon:v4.7.2-pr`. No `fc-*` network
resources, no forks, no clones under `tank/md-f*`/`md-snapfork*`/`md-alt*` remain; KSM off; the
specimen project untouched and `vm/boot.sh 1` re-verified at 27.2 s.

## What broke

Everything in the protocol ran; nothing in Mastodon had to change, and no component was dropped.
What broke was tooling and measurement, and each item is now either generic tooling or a recorded
lesson:

1. **The generator's RI tail** (run 1, 79 min lost). Bulk `INSERT … SELECT` into a table with four
   foreign keys queues one after-trigger event per row per FK and drains them single-threaded at
   statement end: 37 min of heap writes, then >25 min in `afterTriggerInvokeEvents` with no
   progress counter. Killed on instruction; rerun with `session_replication_role = replica` and
   an anti-join per FK pair afterwards (17 pairs, 0 orphans, 160 s). Now the generic bulk-load
   profile (`benchmarks/lib/`), inherited by the specimen's and TrainTicket's generators.
2. **Docker's `/dev/shm` for Postgres**. The FK validation's parallel hash join died on `could not
   resize shared memory segment`; the specimen had hit the same wall a month earlier and the
   lesson had not travelled: `shm_size` belongs in the override the runtime writes for any Postgres.
3. **"VACUUM ANALYZE" of the wrong database.** The generic native quiesce vacuumed
   `${POSTGRES_DB:-postgres}` — Mastodon's container has no `POSTGRES_DB` — in 1.0 s and reported
   success. `vacuumdb -a`. The snapshot was retaken.
4. **Mountpoint convention** (`/md-pg` vs `/tank/md-pg`) in `app-datasets.sh`/`app-zvol.sh`, never
   exercised because the datasets pre-existed; the zvol build failed in 0.3 s. The same class as
   TrainTicket's `/tt-*` reset bug — the second time this convention bit, so it is now written
   into both scripts as a comment naming the rule.
5. **A Compose file describes its host.** `127.0.0.1:3300` binds and a host-path mount cannot work
   inside the guest; the builder cannot know which lines those are. Solved with interpolated binds +
   a guest-only env file (`VM_ENV_FILE`, generic) and an inline `configs:` for the sink. Found by
   reading, not by a failed boot — but only because TrainTicket had taught the shape.
6. **My isolation query was a 25 GB seq scan** (series 1 aborted at 2½ forks): it streamed the
   statuses heap through each fork's page cache and turned a 0.8–1.2 GB fork into 6.8 GB. The
   runtime's numbers were fine; the measurement was wrong. Fixed in both fork measures; series 2 is
   the record.
7. **Home-feed semantics.** An API read of a missing feed returns `200 []` and never rebuilds it;
   only a sign-in does. The first probe run waited 5 min on an empty 200; `regenerate_feed!` is also
   private. A one-line `rails runner` helper, and 2.5 s to a rebuilt feed once asked properly.
8. Small ones: `ALTER SYSTEM` inside a `-c` transaction (the slow-log capture silently did nothing);
   Rails' extended-protocol statements need their binds substituted before EXPLAIN; `migration.sh`
   would have run VALIDATE under the ADD's ACCESS EXCLUSIVE lock (caught on review); `unfork.sh`
   raced the zvol's release (`dataset is busy`, now retried); `restore-series.sh` swallowed that
   failure; a `pkill -f` pattern that matched its own shell; the admin token lived in the
   scratchpad instead of where the scripts look; `u1` is not one of the heavy accounts (whichever
   five `gen_accounts` numbers first are).

## What the runtime must learn from this

- **Bulk loads disable RI triggers and validate after.** Ids from a generator are correct by
  construction; prove it with an anti-join per FK pair, not with 400M trigger events.
- **Own the Postgres ops floor**: `shm_size`, `shared_buffers`, `maintenance_work_mem`, WAL
  sizing — the runtime writes the override, so the runtime should carry the settings a 100M-row
  table needs, not rediscover them per system.
- **"Which database" is app knowledge.** Never infer it from the container; take it from the spec
  (or act on every database, as `vacuumdb -a` does).
- **A Compose file's host-specific lines** (published binds, host-path mounts) need a declared
  guest variant; interpolation + `VM_ENV_FILE` is the mechanism, the spec should name the variables.
- **Measurement must not touch the thing measured**: an isolation check goes through an index; a
  PSS series takes no requests; the tooling should refuse a seq scan on a table over N rows in a
  probe (`EXPLAIN` first).
- **Readiness has app semantics** (here: a feed that exists vs. one that is regenerating vs. one
  that is empty forever); the spec's probe must encode them, and "warm caches" in a fork means
  the caches the snapshot carried — which is exactly what the alternative cannot reproduce.
- **The pre-fault is settled**: with it, first restore = steady state (2.415 vs 2.434 s). It is
  the default now; the cold case TrainTicket showed does not need to exist.
- **The frozen window follows the root disk** (12 GiB → 4.3 s copy vs 24 GiB → 12.6 s); size the
  rootfs to the images, and `SIZE_MB` belongs in the spec (it is now).

## Tooling absorbed vs. Mastodon-specific (lines)

| | lines | files |
|---|---|---|
| **Generic, absorbed into `vm/` this time** (from `git diff --numstat` and the new files) | **+190 / −1** — `app.sh` 27, `onboard-generic.sh` 34, `app-datasets.sh` 26, `app-snapshot-native.sh` 36, `app-zvol.sh` 24, `restore-series.sh` 19, `prefault.py` 13, `snapshot.sh` +9 (pre-fault), `unfork.sh` +2/−1 (busy retry) | 8 |
| **Generic, beside `vm/`** — the bulk-load profile every generator inherits | **58** — `benchmarks/lib/BULK-LOAD.md` 23, `pg-bulk-load-begin.sql` 6, `pg-bulk-load-end.sql` 29; plus 5 lines added to `data/scale/README.md` and 2 to TrainTicket's `gen.sh` | 3 + 2 |
| **Mastodon-specific adapters** (`benchmarks/mastodon/`) | **812** — compose override 103 + `vm.env` 3, `gen.sql` 175 + `gen.sh` 50, `probes.sh` 64, `alt-baseline.sh` 53, `vm-fork-measure.sh` 71, `fork.sh` 47 + `unfork.sh` 14 + `fork.map` 4, `init-env.sh` 45, `probe.sh` 36, `migration.sh` 34, `pr-swap.sh` 32, `app.spec` 25, `init-app.sh` 14, `reset-db.sh` 13, `make-token.sh` 12, `md.sh` 9, `regen-feed.sh` 8 | 20 |
| **Mastodon-specific lines inside the runtime** | **0** — Mastodon appears in four comments (`app-snapshot-native.sh`, `app-datasets.sh`, `onboard-generic.sh`) | — |
| **Mastodon application changes** | **0** | — |

Of the 812 adapter lines, 225 are the data generator and 335 are measurement scripts for this
protocol (probes, migration, fork measures, alternative baseline, PR swap); the onboarding itself —
what it takes to run Mastodon on the runtime — is **252 lines**: the override, env, spec, three init
scripts, the probe, the wrapper. TrainTicket's equivalent was ~330.
