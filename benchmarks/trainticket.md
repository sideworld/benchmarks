# TrainTicket onboarding — ledger and benchmark

> **Paths.** This document was written in a monorepo that has since been split. Paths beginning with
> `../specimen/` or `../micromonkis/` point into the sibling repositories, expected to be checked out
> next to this one (`SPECIMEN_DIR` / `MICROMONKIS_DIR` in the scripts). Paths without that prefix are in this repo.

Live ledger, updated as work happens. Started 2026-09-21 (box: Hetzner Ryzen 7 7700, 64 GB, Ubuntu
24.04, host kernel 6.8.0-139, Firecracker v1.17.0). Time-box: 16 h of operator activity. Gate: if
TrainTicket is not healthy natively within 4 h, stop and record why.

Target: FudanSELab/train-ticket — 41 services, Java/Node/Python/Go, MySQL + MongoDB — onto the fork
runtime built for the specimen (`../micromonkis/vm/`, `docs/FORK-EXPERIMENT-{1,2,3}.md`), with **zero changes to
TrainTicket's application code**. Adapters allowed: Compose overrides, env vars, init scripts,
mocks/fakes for external calls, data generators.

## Time ledger

Wall-clock UTC from tool timestamps; "hours" is operator activity, which here equals wall-clock
because the work was continuous. (An earlier draft of this table carried estimated times that had
drifted ~2 h ahead of the clock; corrected against the recorded timestamps.)

| # | when (UTC) | step | hours | category | notes |
|---|---|---|---|---|---|
| 1 | 05:17–05:18 | ledger + shallow clone (1.4 s) | 0.02 | setup | |
| 2 | 05:18–05:24 | inventory: compose variants, image eras, drivers, init data, UI routing; pulled 45 images (44 s); 25 ZFS datasets | 0.10 | understanding | HEAD source ≠ compose era; chose 0.2.0 |
| 3 | 05:24–05:35 | override generator + env + wrapper; boot #1 (454.6 s = probe budget, all JVMs actually up at +71 s) | 0.18 | adapters | |
| 4 | 05:35–05:46 | readiness debugging: actuator 403 behind the JWT filter; `welcome` paths from source; 23 services guard those too; Go image has no bash; boot #2 | 0.18 | debugging | three probe revisions |
| 5 | 05:46–05:52 | boot #3 (82.6 s, 68/68); search probe (`/trips` is createTrip, `/trips/left` is search; station *names*); user probe; idle RAM | 0.10 | measurement | |
| 6 | 05:52–05:57 | data model from source + seeded docs; generator, checker, quiesce script; `HexData(3)` Java-legacy UUIDs | 0.08 | data | |
| 7 | 05:57–06:08 | validation run; seed-data incoherence traced; duplicate-key on additive rerun (seed mixing); reset bug (mountpoint at `/tt-*`) found and repaired; true cold boot 81.9 s; 1M generated twice (seatNumber format) | 0.18 | data | two of my errors, one of the app's |
| 8 | 06:08–06:12 | search at 1M (104 s / 40 s), snapshot `@tt-base` (6.4 s frozen) | 0.07 | measurement | |
| 9 | 06:12–06:28 | `../micromonkis/vm/mkfork-generic.{sh,py}`, TT fork map + runner; fork 1, fork 2, ceiling, unfork | 0.27 | fork-compose | |
| 10 | 06:28–06:31 | Firecracker generalisation: `build-rootfs-generic.sh` + `guest-generic/`, env knobs on 8 vm scripts, TT data zvol, `vm.sh`; rootfs build (61 s) | 0.05 | fork-vm | edits were mostly pre-written while forks ran |
| 14 | 07:02–07:12 | recovery evidence, teardown, host verification, specimen `../micromonkis/vm/boot.sh 1` proof, write-up | 0.17 | writeup | |
| 15 | 11:41–12:00 | **repeat onboarding** from a clean teardown: 19 m 10 s, six gaps recorded; gap-closing scripts after | 0.45 | measurement | |
| 16 | 12:09–12:50 | **third run**: attempt 1 found the SIGPIPE gap (fixed), attempt 2 from a full teardown with images purged: 14 m 42 s, zero decisions; restore variance: 10 warm restores + 2 cold/pre-fault pairs; Compose fork; write-up | 0.7 | measurement | |
| 13 | 06:42–07:02 | six restore forks with PSS series + isolation; image swap in fork 1 | 0.33 | fork-vm | |
| 12 | 06:34–06:42 | native down; VM boot (UI 17.2 s), in-guest probe, snapshot (19.9 s frozen); PR image built; fork measure script | 0.13 | fork-vm | |
| 11 | 06:31–06:34 | bake in a 24 GiB guest (UI 50.4 s, all healthy 131.2 s) | 0.05 | fork-vm | first try |

## Adapters written

| file | lines | kind | why |
|---|---|---|---|
| `benchmarks/trainticket/compose/gen-override.py` | 115 | generator for a Compose override | healthchecks (upstream has none), state bind-mounts onto ZFS (Mongo has no volumes upstream), DB image pins |
| `benchmarks/trainticket/compose/docker-compose.tt.yml` | ~690 (generated) | Compose override | output of the above; never hand-edited |
| `benchmarks/trainticket/compose/tt.env` | 6 | env file | `IMG_REPO/IMG_TAG` as upstream's `.env`, plus `NAMESPACE/TAG` which upstream leaves undefined |
| `benchmarks/trainticket/tt.sh` | 12 | wrapper | the `docker compose -p tt --project-directory … -f … -f …` invocation |
| `benchmarks/trainticket/probe.sh` | 28 | readiness probe | UI 200 + login JWT + ticket search with ≥ 1 result; the user-level definition of "healthy" since upstream has none |
| `benchmarks/trainticket/scale/gen.js` | 143 | data generator | users/contacts/trips/orders/payments straight into the 24 Mongos with real cross-service references and the exact document encodings Spring Data 1.10 wrote (Java-legacy UUID `BinData(3)`, `_class`) |
| `benchmarks/trainticket/scale/check.js` | 33 | coherence check | samples orders and payments and follows every reference |
| `benchmarks/trainticket/scale/gen.sh` | 20 | runner | timing, rows/s, ZFS on-disk + compressratio |
| `benchmarks/trainticket/reset-state.sh` | 22 | state reset | destroy + recreate the 25 datasets with explicit mountpoints |
| `../micromonkis/vm/mkfork-generic.sh` + `../micromonkis/vm/mkfork-generic.py` | 63 + 36 | generic fork tool | `../micromonkis/mkfork.sh` generalised to any Compose project; specimen behaviour is the default |
| `benchmarks/trainticket/fork.map` | 26 | fork map | 25 stateful services → datasets → clone names |
| `benchmarks/trainticket/fork.sh` + `unfork.sh` | 52 + 18 | fork runner | clone, up, time, probe, isolation write, cgroup RAM, storage delta; inverse |
| `../micromonkis/vm/build-rootfs-generic.sh` + `../micromonkis/vm/guest-generic/` (7 files) | 260 + 95 | generic rootfs builder | any Compose app: APP_DIR, COMPOSE_FILES, ENV_FILE, DATA_MAP; generic `app.service`, image loader, DB-aware quiesce/thaw/post-restore (Postgres CHECKPOINT / Mongo fsyncLock / MySQL flush) |
| `../micromonkis/vm/{boot,net,stop,bake-rootfs,snapshot,net-ns,fork,unfork}.sh` | +~60 lines of env knobs | parameters, specimen defaults | ROOTFS_IMG, SNAPSHOT, CLONE_PREFIX, SNAPFORK_PREFIX, FC_ID/FC_PREFIX, GUEST_HTTP, HEALTH_PATH, READY_FILE, GUEST_PORTS, APP_UNIT, APP_DIR_GUEST |
| `benchmarks/trainticket/vm-data.map`, `vm.sh` | 26 + 34 | TT wiring for the vm tooling | keeps every name under `../micromonkis/vm/out/tt-*`, `tank/tt-*`, `/run/fc-tt*` |
| `benchmarks/trainticket/vm-fork-measure.sh` | 48 | per-fork VM measurement | restore, PSS@10/60/120, isolation write, storage delta, host headroom → `../micromonkis/vm/out/tt-forks.csv` |
| `benchmarks/trainticket/onboard.sh`, `vm-data.sh`, `pr-swap.sh` | 24 + 27 + 24 | runbook + the two hand-done steps | added after the repeat run to close its gaps; not used by the repeat measurement |
| `benchmarks/trainticket/snapshot.sh` | 30 | quiesce + snapshot | `db.fsyncLock()` × 24, clean MySQL stop, `sync`, `zfs snapshot` × 25, thaw |

## Dependencies not reproducible / mocked

| dependency | where used | status | notes |
|---|---|---|---|
| `http://rest-service-external:16100/greet` | `ts-inside-payment-service` `AsyncTask` (async, fire-and-forget) | **absent, not mocked** | nothing in the compose provides it; the call fails on DNS and the result is discarded. Nothing exercised here depends on it, so no fake was written. Would be a 5-line fake if a payment flow needed it. |
| Docker Hub (`codewisdom/*:0.2.0`, `mongo:4.4`, `mysql:5.7`, `redis`) | image pulls | reproduced by pulling once | 45 images, 10.85 GB unique layers, 44 s; baked into the rootfs afterwards so guests never pull |
| the 1.0.0-era stack (Nacos, RabbitMQ, per-service MySQL) | HEAD source only | **not attempted** | no Compose deployment exists for it upstream; would mean writing a 46-service compose from scratch |

### Step 3 — populate state

| | |
|---|---|
| own init data | 13 services seed on first boot: 13 stations, 10 routes, 6 train types, 10 price configs, 5 + 5 trips, 2 users, 2 contacts, 3 + 1 orders, 1 payment, 27 food stores. Boot-time seeding is included in the 81.9 s cold boot. |
| generator | `benchmarks/trainticket/scale/gen.js` (143 lines, legacy `mongo` shell, runs in a throwaway `mongo:4.4` on the Compose network), `gen.sh` runner, `check.js` coherence check |
| **volume reached** | **1,000,004 orders** (500,003 in `ts-order-mongo` + 500,002 in `ts-order-other-mongo`), **809,242 payments × 2** (`ts-payment-mongo` + `ts-inside-payment-mongo`), **10,002 users** (auth + user + contacts + addMoney), **1,010 trips** (493 G/D + 517 Z/T/K) on the 10 seeded routes, keyed to the 10 seeded (trainType, routeId) price configs |
| coherence | 600 orders + 300 payments sampled: **0 dangling** references in `user`, `trip`, `route`, `trainType`, `price_config`, `from/to ∈ route`, `payment ↔ order`. Every generated user logs in with `111111`. |
| **generator throughput** | **10,487 orders/s** (1M in 95.4 s); users 23,392 docs/s; **97.5 s wall** for the whole set |
| generator hours | 1.1 h (model from source + seeded documents, UUID encoding, two format bugs — see time ledger) |
| **on disk** | 25 datasets: **607 MiB used, 683 MiB logical**; order stores 134 + 138 MiB (1.11×), payment stores 156 + 158 MiB (1.05×), auth 1 MiB (2.0×), trips 0.3 MiB (3.9×). Order/payment documents barely compress: UUIDs, random strings and dates. |
| **ZFS compressratio** | 1.05–1.11× on the big stores; 1.13× overall |
| **search at 1M orders** | Nan Jing → Shang Hai: `travel` **103.8 s** for 293 trips, `travel2` **40.0 s** for 109 trips (0.14 s on seed data). The order stores carry only the `_id` index, so `findByTravelDateAndTrainNumber` is a ~100 ms collection scan of 500 k orders **per matching trip**, and the seat service adds two more hops per trip. Linear in trips × orders. Not a runtime property; the app's own. |
| quiesce + snapshot | `snapshot.sh tt-base`: `db.fsyncLock()` × 24, clean MySQL stop, `sync`, `zfs snapshot` × 25, restart MySQL, `fsyncUnlock` × 24 — timings below |

### Step 4 — Compose fork on ZFS (engine-less)

Tooling: `../micromonkis/vm/mkfork-generic.sh` + `../micromonkis/vm/mkfork-generic.py` (the specimen's `../micromonkis/mkfork.sh` generalised:
project dir, snapshot, a `FORK_MAP` of `service container-path source-dataset clone-dataset`, a port
`OFFSET`, a project name; refuses offsets that land on live listeners; the specimen's five datasets and
`n*1000` remain the defaults). TrainTicket's map is `benchmarks/trainticket/fork.map` (25 lines);
`fork.sh <n>` / `unfork.sh <n>` drive it and measure. Port offset is **13000 × n** — TrainTicket
publishes 43 ports spanning 6379–19001, so the specimen's 1000 × n would put fork 2's avatar service on
native's payment port.

| | fork 1 (alone beside native) | fork 2 (beside native + fork 1) |
|---|---|---|
| `zfs clone` × 25 + override | 0.78 s | 0.84 s |
| **boot to 68/68 healthy** | **88.4 s** | **89.2 s** |
| probe (UI, login, search) | pass — 293 trips in 111.4 s | pass — 293 trips in 114.4 s |
| isolation: contact created via this fork's API | HTTP 201; visible in fork 1 only (native 0, fork 1 1) | HTTP 201; visible in fork 2 only (native 0, fork 1 1, fork 2 1) |
| **RAM** (sum of the project's 68 container cgroups) | **14,418 MiB** | 14,230 MiB |
| storage delta (25 clones, `zfs used`) | **5 MiB** | 5 MiB |

**Ceiling:** with native TrainTicket (13.6 GB), the specimen's own Compose project (~13 GB) and two forks
(14.4 + 14.2 GB) resident, the host sat at 53 GB used / 8 GB available of 62 GB. **Two concurrent Compose
forks beside native** is the limit on this box; a third would swap. Every fork costs the full ~14 GB —
41 fresh JVMs — regardless of how little data it touches. Boot time did not move with neighbours
(88.4 s → 89.2 s), and the search did not either (111 s → 114 s). The `@tt-base` snapshot set
references 568 MiB across 25 snapshots.


### Step 5 — Firecracker path

Tooling: `../micromonkis/vm/build-rootfs-generic.sh` + `../micromonkis/vm/guest-generic/` (new), the eight existing `../micromonkis/vm/` scripts
with env knobs (specimen defaults untouched), `benchmarks/trainticket/vm.sh` to set them for
TrainTicket, `vm-data.map` (25 lines), `vm-fork-measure.sh`.

| | |
|---|---|
| rootfs build | `../micromonkis/vm/out/tt-rootfs.ext4`, 24 GiB image, **61 s**: 45 images → 2.2 GB archive; 2.9 GB used before load |
| bake (first boot in a 24 GiB / 8 vCPU guest, image load, clean shutdown, adopt) | UI answers at 50.4 s; **all 68 healthy at 131.2 s** guest time (includes loading 4.7 GB of images); baked rootfs 6.0 GB used |
| data disk | `tank/tt-vm-data`: 24 GB zvol, ext4, the 25 `@tt-base` state dirs copied in (670 MB, uid 999 preserved), snapshotted `@tt-base`; per VM a `zfs clone` |
| guest size | started at 24,576 MiB as briefed. **Actually used: 12,965 MiB (anon 12,287, file 4,047)** with 68 containers healthy at 1M orders — a 16 GiB guest would do; 12 GiB would be tight |
| **boot-to-healthy inside the VM** (baked rootfs, 8 vCPU) | UI 200 at **17.2 s** on the host clock; **68/68 healthy verified at ≤ 154 s** after guest boot (the exact figure was lost: `compose up --wait` inside the guest exited 1 on a transient UI probe failure so `app-up` never wrote its ready file — hardened since, see what broke; the bake boot, which also loaded 4.7 GB of images first, reported 131.2 s) |
| in-guest probe at 1M | pass: login + search 293 trips in 118.1 s (same as native: 104–114 s) |
| firecracker RSS = PSS, single VM | 17,338 MiB |
| **snapshot** (`vm.sh snapshot 1 ttbase`) | `t_quiesce_pause` **19.9 s** (fsyncLock × 24 + MySQL flush + fsfreeze; pause 6 ms; `PUT /snapshot/create` **4.4 s**; zfs snapshot 38 ms; **rootfs copy 12.6 s** for the 24 GB image; resume 6 ms; thaw + 24 × fsyncUnlock) |
| **memory file** | 24,576 MiB apparent, **4,880 MiB allocated** on ZFS (lz4); vmstate 98 KB |
| source VM after snapshot | 68/68 healthy, every Mongo unlocked, 500,003 orders readable |

#### Restore forks

Each fork: `zfs clone` of `tank/tt-vmfork1@ttbase`, reflink of the 24 GB rootfs, its own netns
(`fc-ns<k>`, tap pinned to the source MAC), `PUT /snapshot/load` with `resume_vm:false`, both drives
repointed with `PATCH /drives`, resume, then `post-restore` over ssh (thaw `/data`, `fsyncUnlock` × 24,
gratuitous ARP, chrony). Host ports: `3<kk>80` UI, `3<kk>90` auth, `3<kk>70` travel, `3<kk>60`
contacts, `3<kk>22` ssh. Series in `../micromonkis/vm/out/tt-forks.csv`.

| fork | `t_load` | `t_restore_to_api_response` (UI 200) | PSS @10 s | @60 s | **@120 s** | anon/file @120 s | storage delta | isolation | host avail after |
|---|---|---|---|---|---|---|---|---|---|
| 1 (beside source) | 0.026 s | **9.9 s** | 2,124 MiB | 2,730 | **3,057** | 1,942 / 1,115 | 21 MiB | 201, own contact only; in-fork search 293 trips / 125 s | 25 GiB |
| 2 (beside source + fork 1) | 0.028 s | **5.5 s** | 2,973 MiB | 3,425 | **3,632** | 1,963 / 1,669 | 10 MiB | 201, own contact only | 23 GiB |
| 3 (beside source + 2 forks) | 0.028 s | **5.6 s** | 2,549 MiB | 3,026 | **3,238** | 2,012 / 1,226 | 10 MiB | 201, own contact only | 20 GiB |
| 4 | 0.027 s | 5.8 s | — | — | **3,117** | 1,992 / 1,125 | 10 MiB | 201, own contact only | 16 GiB |
| 5 | 0.033 s | 5.8 s | — | — | **3,006** | 1,995 / 1,011 | 10 MiB | 201, own contact only | 13 GiB |
| 6 | 0.033 s | 6.4 s | — | — | **2,934** | 2,029 / 905 | 11 MiB | 201, own contact only | 10 GiB |

#### Stateful services across snapshot/restore

| store | VM restore path | Compose clone path |
|---|---|---|
| 24 × MongoDB 4.4 | **clean**: the `mongod` processes survive the restore (start time predates the snapshot), no restart, `fsyncUnlock` releases the lock taken by `quiesce`, all 1,000,005 orders readable in every fork | **clean**: a cold start on a clone of the `fsyncLock`ed snapshot logs WiredTiger's "unclean shutdown — lock file is not empty / recovering from the last clean checkpoint", which is the routine lock-file check, not lost data: the checkpoint *is* the locked state; 500,003 orders present |
| MySQL 5.7 | **clean**: process survives the restore; `voucher` table readable | **clean**: "InnoDB: 5.7.44 started", no recovery lines, after the clean stop `snapshot.sh` used |
| Redis | stateless here (no volume upstream); survives restore | recreated fresh |

#### Image swap in a fork (PR → changed system serving)

One-line change to `ts-ui-dashboard/static/index.html` on a `v0.2.0` worktree (the page title), rebuilt
with the service's own Dockerfile, shipped into fork 1 and swapped:

| phase | time |
|---|---|
| `docker build` on the host (openresty base already present) | 4.6 s |
| `docker save` (186 MB) | 1.4 s |
| transfer into the fork over ssh | 1.0 s |
| `docker load` + retag to the tag the compose file names | 1.9 s |
| `compose up -d --no-deps --force-recreate ts-ui-dashboard` → new page served | 1.9 s |
| **PR to changed system serving** | **10.8 s** (4.8 s inside the fork) |

Forks 2–6 and the source VM kept serving the old page.

**Ceiling: 6 restored forks beside the source VM** — seven 24 GiB guests, 168 GiB nominal, on a
62 GB host with no swap, stopped by a ≥ 10 GiB headroom rule rather than by failure. Summed PSS at
that point: **40,443 MiB** (source 17,500; forks 5,325 / 3,889 / 3,776 / 3,640 / 3,328 / 2,985). The
briefing expected 2–3; nominal guest size is the wrong number to plan with. An idle restored fork
costs ~3 GB PSS at 120 s (anon ~2 GB: 41 JVMs and 24 Mongos churning) and grows to ~5 GB once it has
served a search; the 24 GiB memory file is shared through the host page cache (16 GB `Cached`). Every
fork answered on its own ports and each saw only its own contact. `t_restore_to_api_response` is
9.9 s for the first fork (cold page cache) and 5.5–6.4 s after, against 2.4 s for the specimen: the
guest has ~17 GB to fault back in and 24 Mongos to unlock before the UI's nginx answers.


## Findings about the application itself

- **Seed data is internally incoherent.** Of 6 seeded orders, 3 (`G1234`, `G1235`, `G1237`) name a
  `from`/`to` pair their trip's route does not contain, and the seeded `K1235` order references a trip
  that exists in neither `ts-travel-mongo` nor `ts-travel2-mongo`. The seeded payment
  `5ad7750b-…` references an order that does not exist. The coherence checker flagged all of them and
  none of the generated documents.
- **Seeding is not idempotent.** `ts-order-other-service` re-inserts its `K1235` seed order on every
  boot (three copies after three boots); `InitData` classes that check for existence first
  (`ts-auth-service`, `ts-station-service`) do not. A fork restored from a snapshot and then
  *rebooted* would grow this collection by one per boot.
- **The seeded orders' `seatNumber` ("FirstClass-30") is a format the code cannot parse.** `OrderServiceImpl.getSoldTickets` does `Integer.parseInt(seatNumber)` on every order matching the searched trip and date; the real preserve flow writes numeric seats. The seeds only survive because they are dated 2017. Copying their format into generated orders made every ticket search 500 until fixed (my error, but only because the seed data lies).
- **No idle is idle.** 68 healthy containers doing nothing sum to ~51% of one core, almost all of it
  the 37 JVMs; the same shape as the specimen's healthcheck churn, ×3.

## Fidelity trades

| trade | what is lost | why accepted |
|---|---|---|
| TrainTicket **0.2.0** (prebuilt `codewisdom/*:0.2.0`, built 2021-08-10), not HEAD source | the v1.0.0+ MySQL/Nacos/RabbitMQ architecture and 5 newer services (`ts-delivery`, `ts-food-delivery`, `ts-gateway`, `ts-station-food`, `ts-train-food`, `ts-wait-order`) | 0.2.0 is the only version upstream ships a Compose deployment for; HEAD is k8s-only and its compose is stale. Building HEAD from source would also mean writing a 46-service compose from scratch. |
| `mongo:4.4` and `mysql:5.7` instead of untagged `mongo`/`mysql` | nothing functional | untagged resolves to Mongo 8 / MySQL 9 today, which the 2019–2021 drivers cannot speak to. Upstream's own k8s manifests pin 5.6/5.7. |
| readiness = HTTP 200 **or 403** on each Java service's `welcome` path | a 403 does not prove the service's dependencies work, only that its Spring context is fully up | 23 of 37 services guard every path, actuator included, behind their own JWT filter; the alternative is a per-service login inside every healthcheck |
| TCP-only readiness for 4 non-Java services + the 6 Java services with no unauthenticated path | listening ≠ wired up | no unauthenticated HTTP route exists in those images |

## System inventory

Cloned upstream `FudanSELab/train-ticket` at `313886e` ("Hotfix (#243)") into `/tank/work/trainticket`,
1.4 s shallow clone. **Which deployment:** the root `docker-compose.yml` (561 lines, byte-identical to
the `v0.2.0` tag's) with the repo's own `.env` (`IMG_REPO=codewisdom`, `IMG_TAG=0.2.0`). This is the
only Compose deployment upstream ships for the whole system; the `microsensorproject/train-ticket` fork's
`docker-compose.yml` is byte-identical to it. **Mismatch recorded:** HEAD *source* is the v1.0.0+ era
(MySQL per service + Nacos discovery + RabbitMQ, 46 `ts-*` directories, deployed only via k8s
manifests), while the Compose file and the `0.2.0` images are the Mongo-per-service era. The two do not
combine; this exercise onboards **TrainTicket 0.2.0 as its Compose file defines it**, with prebuilt
`codewisdom/*:0.2.0` images (built 2021-08-10) rather than a source build. See fidelity trades.

| | |
|---|---|
| services in compose | 68: 41 application + 24 MongoDB + 1 MySQL + 1 Redis + 1 UI (nginx) |
| languages (app services) | 37 Java (Spring Boot 1.5.22, `java:8-jre`, `-Xmx200m` each), 1 Node (ts-ticket-office), 2 Python (ts-avatar: flask+dlib+opencv face detection; ts-voucher: tornado+pymysql), 1 nginx (ts-ui-dashboard) |
| databases | 24 × `mongo` (one per service, **no volumes** — state lives in the container layer), 1 × `mysql` (ts-voucher-mysql, anonymous volume), 1 × `redis` |
| message brokers | none in 0.2.0 (RabbitMQ appears only in the 1.0.0 k8s manifests) |
| service discovery | none in 0.2.0 (hard-coded Compose hostnames); Nacos in 1.0.0 |
| external calls | `ts-inside-payment-service` → `http://rest-service-external:16100/greet` (async, fire-and-forget; no such service in compose); `ts-avatar-service` → none at runtime (dlib models vendored) |
| cron / scheduled | none found (`@Scheduled` not used; init is `CommandLineRunner`/`@PostConstruct` seeding) |
| init / seed | 13 services seed on first boot from `InitData` classes (routes, stations, trains, prices, contacts, security rules, users incl. `fdse_microservice`/`admin`); `ts-voucher-service` ships `db.sql` |
| healthchecks | **none** in compose; Spring Boot actuator is present, so `GET /health` on each Java service's port exists |
| `depends_on` | one (ts-voucher-service → ts-voucher-mysql) |
| published ports | 43 host ports (8080 UI, 6379 redis, one per app service) |
| image size | 45 images; see step 2 |
| image tags | `.env` leaves `NAMESPACE`/`TAG` (used by ts-avatar-service) undefined → that one image resolves to `/ts-avatar-service:`; set both to `codewisdom`/`0.2.0` |
| untagged DB images | `mongo` and `mysql` resolve to Mongo 8 / MySQL 9 today; the 0.2.0 Mongo driver is 3.4.3 (wire protocol 5, `OP_QUERY`, removed in Mongo 5.1+) and the voucher client is 2019 pymysql. Pinned to `mongo:4.4` and `mysql:5.7` (upstream's own k8s manifests pin 5.6/5.7). |

## Protocol results

### Step 2 — native boot on the host (Docker, state on ZFS)

| | |
|---|---|
| deployment | upstream `docker-compose.yml` @ `313886e` (= tag `v0.2.0`) + `benchmarks/trainticket/compose/docker-compose.tt.yml` |
| images | 45 pulled (41 app `codewisdom/*:0.2.0` + `mongo:4.4` + `mysql:5.7` + `redis`), **10.85 GB unique layers**, 44 s to pull |
| built from source | none |
| healthchecks | **none upstream**; 68 added by the override (see fidelity trades) |
| user-level readiness probe | `benchmarks/trainticket/probe.sh`: UI `GET /` = 200, `POST /api/v1/users/login` as the seeded `fdse_microservice` returns a JWT, `POST /api/v1/travelservice/trips/left` Nan Jing → Shang Hai returns ≥ 1 trip (3 on seed data) |
| **cold boot to all 68 healthy** (`up --wait`, final probes) | **81.9 s** on empty datasets (seeding included); 82.6 s on already-seeded data |
| …of which the last JVM logs `Started` | +71 s after the first container start (median JVM start 63 s; 37 JVMs on 16 cores) |
| earlier boots | 454.6 s and 449.7 s — both the healthcheck *budget* (150 s + 30 × 10 s) running out on wrong probes, not the app |
| **RAM at idle** (`docker stats` sum, 60 s after healthy) | **13,616 MiB** across 68 containers: 37 Java × 317 MiB = 11,712; 24 Mongo × 64 = 1,541; MySQL 169; 5 non-Java 188; Redis 6 |
| CPU at idle | ~51% of one core summed across 68 containers |
| services that never became healthy | none (68/68) |
| services needing a restart to come up | `ts-voucher-service`: connects to MySQL at import time, MySQL takes ~18 s to init on first boot, crashes 3× and Docker restarts it; healthy by the time the JVMs are |

## Benchmark protocol — TrainTicket beside the specimen

| | **specimen** (`docs/FORK-EXPERIMENT-{1,2,3}.md`) | **TrainTicket 0.2.0** |
|---|---|---|
| system | 6 built services + 4 Postgres + Kafka + IdP + stripe-fake + OTel, 14 containers | 41 services (37 Java, 1 Go, 1 Node, 2 Python) + 24 Mongo + 1 MySQL + Redis + nginx, **68 containers** |
| **time to onboard**, clone → first useful fork | — (the runtime was built around it) | **wall-clock 1 h 11 min** (05:17 clone → 06:28 Compose fork 1 healthy); **1 h 30 min** to the first Firecracker fork (06:47); operator hours = the same, work was continuous |
| **adapters written** | `docker-compose.vm.yml` (generated) | 16 files, ~1,050 lines: compose override generator 115 + generated override 690, env 6, wrapper 12, probe 34, generator 143 + checker 33 + runner 20, snapshot 30, reset 22, fork map 26 + runner 52 + inverse 18, VM wiring 26 + 34 + 48; plus **generic runtime**: `build-rootfs-generic.sh` 260, `guest-generic/` 95, `mkfork-generic.{sh,py}` 99, ~60 lines of env knobs across 8 `../micromonkis/vm/` scripts |
| **application changes required** | 0 | **0** |
| dependencies unsupported / mocked | none | `rest-service-external` absent upstream, left absent (fire-and-forget); nothing mocked |
| things shared rather than forked | rootfs (reflink), memory file (page cache), image layers | same: 24 GB rootfs reflinked per fork, 24 GiB memory file shared via page cache (16 GB `Cached` at 6 forks), image store inside the rootfs. Nothing else is shared; each fork has its own 25 DBs. |
| data preparation | `make scale N=10M`: 765.9 s, 125,815 rows/s, 13.2 GB | **1.1 h** of operator time; **1,000,004 orders + 809,242 × 2 payments + 10,002 users + 1,010 trips in 97.5 s** (10,487 orders/s); **607 MiB on disk**, 1.13× lz4 |
| **cold boot to healthy** | native 31.9 s; microVM 27.2 s | **native 81.9 s** (68/68, seeding included); **microVM: UI 17.2 s, all 68 ≤ 154 s** (bake boot 131 s incl. image load) |
| snapshot: frozen window / memory file | 5.8 s; 6 GiB apparent, ~750 MB allocated | **19.9 s** (12.6 s of it the 24 GB rootfs copy, 4.4 s the dump); **24 GiB apparent, 4.9 GB allocated** |
| Compose+ZFS fork: clone / boot / RAM | 0.097 s / 43.5 s / 1.4–1.8 GB (cgroup) | **0.8 s / 88–89 s / 14.2–14.4 GB** (cgroup) |
| **fork-to-serving** (microVM) | 2.4 s | **9.9 s first fork, 5.5–6.4 s after** (first UI 200) |
| **PSS per idle fork @120 s** | 473 MB (6 GiB guest) | **3.0–3.6 GB** (24 GiB guest); ~5 GB after serving a search |
| storage delta per fork | 0.9–1.8 MB | **10–21 MiB** (zvol clone) |
| **max concurrent forks on this box** | 5 measured, not a ceiling (9.2 GB sum) | **6 restore forks + source** at a ≥ 10 GiB headroom stop (40.4 GB summed PSS); **2 Compose forks + native** (53 GB used) |
| stateful services recovered cleanly | Postgres yes, Kafka yes | **24 Mongo yes, MySQL yes** (both paths; see above) |
| PR → changed system serving | — | **10.8 s** (4.8 s inside the fork) |
| **fidelity lost** | none | v0.2.0 build, not HEAD (the only Compose-deployable version); `mongo:4.4`/`mysql:5.7` pins (untagged = unusable); readiness for 23 services is "context up" (403), not "dependencies fine"; generator writes to Mongo directly rather than through the API (which would 502 on `acme`-sized tenants and take hours) |

## What broke

**Nothing in TrainTicket's code had to change, and nothing about the runtime had to change in kind** —
every step of the specimen's protocol ran on a system three to five times its size. What broke was
mostly the assumption that a project's published deployment describes the code next to it, and my own
probes.

1. **The compose file and the source are two different systems.** HEAD is the v1.0.0+ MySQL / Nacos /
   RabbitMQ architecture, deployed only by k8s manifests; the `docker-compose.yml` beside it is
   byte-identical to the `v0.2.0` tag's Mongo-per-service design, and `.env` says so
   (`IMG_TAG=0.2.0`). The fork's compose is the same file. Onboarding "TrainTicket" therefore means
   picking a version, and the choice was made by what upstream actually ships as runnable.
2. **Untagged database images are a time bomb.** `mongo` and `mysql` resolve to 8.x / 9.x today; the
   0.2.0 driver is mongodb-java 3.4.3 (wire protocol 5, `OP_QUERY`, removed in 5.1) and the voucher
   client is 2019 pymysql. Pinned before the first boot on evidence from the jar, not by trial.
3. **No healthchecks, and the obvious probe is forbidden.** Upstream defines none. Spring Boot 1.5's
   actuator `/health` exists but the app's own JWT filter answers 403 on it, and 23 of 37 services
   guard even their `welcome` endpoint. Three probe revisions: `/health` (403 everywhere) →
   `welcome` from source (18 still 403) → accept 200 **or** 403 (a fully initialised Spring context
   answering) with TCP for the 10 services that have no HTTP surface. The first two boots reported
   454 s and 450 s — exactly the healthcheck budget — while every JVM had logged `Started` by +71 s.
4. **The Go image has no `bash`.** `/dev/tcp` is a bashism; `ts-news-service` needed `wget`.
5. **`ts-voucher-service` connects to MySQL at import time**, before MySQL's first-boot init finishes,
   crashes three times and is restarted by Docker. Healthy by the time the JVMs are; not fixed, recorded.
6. **The search is O(trips × orders).** `POST /trips/left` iterates every trip on matching routes and,
   per trip, runs `findByTravelDateAndTrainNumber` against an order store with only an `_id` index
   (~100 ms collection scan of 500 k) plus two seat-service hops. 0.14 s on seed data, **104 s at 1 M
   orders** for 293 trips. The app's, not the runtime's; the probe got a 300 s cap and reports the time.
7. **The seed data lies about the schema.** Seeded orders carry `seatNumber: "FirstClass-30"`; the
   sold-seat path does `Integer.parseInt(seatNumber)` and the preserve flow writes numeric seats. The
   seeds survive only because they are dated 2017. My generator copied the seed format and every
   search 500'd until it wrote numbers. Also: 3 of 6 seeded orders name stations their trip's route
   lacks, one seeded order's trip does not exist, the seeded payment's order does not exist, and
   `ts-order-other-service` re-seeds its order on every boot.
8. **Two of mine.** A reset loop created datasets with `mountpoint=/tt-*` instead of `/tank/tt-*`, so
   Docker bound plain directories on the parent dataset and a million orders were invisible to
   `zfs snapshot` (moved, no regeneration; `reset-state.sh` now asserts the mount). And a second
   generator run with the same seed replayed the same UUIDs into a duplicate-key error — the seed is
   now mixed with the existing counts.
9. **`docker compose up --wait` inside the guest gave up on a transient UI probe** and `app.service`
   exited 1 without writing its ready file, although all 68 containers were healthy ~2 min later. The
   generic `app-up` now falls back to polling Docker's health. Cost: the exact boot-to-all-healthy
   figure for the baked microVM is an upper bound (≤ 154 s) rather than a measurement.
10. **Docker's health log keeps five entries**, so "first healthy" cannot be reconstructed after the
    fact. Another reason the ready file has to be written by the runtime, not inferred.
11. **The specimen's port convention does not scale.** TrainTicket publishes 43 ports across
    6379–19001; `n × 1000` puts fork 2's avatar on native's payment port. `mkfork-generic.sh` takes an
    offset and refuses one that lands on a live listener; TrainTicket uses `13000 × n`.
12. **Nothing else.** ptp_kvm, chrony, the pinned tap MAC, `PATCH /drives` before resume, per-fork
    namespaces, `fsfreeze` — all of phase 2's mechanisms worked unchanged on a guest four times larger
    with 25 databases. The generic quiesce grew a Mongo `fsyncLock`/`fsyncUnlock` and a MySQL flush.

## What the runtime must learn from this

1. **A "deployment" is a version, and the version must be recorded.** Onboarding starts by
   discovering which compose file, which images and which source actually go together; the answer
   here was none of the three at HEAD.
2. **Pin every untagged image on evidence, before the first boot.** Read the driver out of the jar;
   do not learn it from a 454 s timeout.
3. **Readiness is a per-system definition and the runtime must own it.** Expect no healthchecks,
   expect the standard endpoints to be guarded, and expect to need three signals: process listening,
   framework context up (a 403 counts), and a user-level probe (login + one real query) with a
   timeout sized to the data. Write the ready marker from inside the guest and never infer it from
   Docker's five-entry health log.
4. **Generate state directly into the stores, with the exact encodings the ORM wrote**, and validate
   every reference. Java-legacy UUIDs, `_class`, string-vs-binary ids: one wrong byte order and the
   application cannot see its own data. Do not trust the seed data's shapes — trust the code paths.
5. **Guest RAM is not the fork's cost.** Six 24 GiB guests summed to 40 GB of PSS; the nominal number
   would have predicted two. Plan density on measured PSS growth (here ~3 GB idle, ~5 GB exercised per
   fork) and page-cache sharing of the memory file, with a headroom rule, because the host has no swap.
6. **Fork-to-serving scales with what the guest must fault back in and unlock**: 2.4 s for the
   specimen, 9.9 s cold / 5.5 s warm here. Restore is still 15× faster than a Compose fork of the same
   snapshot (88 s) and 30× faster than a cold boot — but the first fork pays for the page cache.
7. **The frozen window scales with the root disk, not the data.** 12.6 s of the 19.9 s was copying a
   24 GB rootfs image that is 6 GB used. Reflink did not help on this pool; a thin base image or a
   snapshot of the rootfs volume itself would take this to seconds.
8. **Quiesce has to know each store's lock**: Postgres `CHECKPOINT`, Mongo `fsyncLock`, MySQL
   `FLUSH TABLES` or a clean stop — and thaw must run *first* on every restored fork, before ARP and
   clock, or the first write blocks forever.
9. **Port offsets must be derived from the port span**, and collisions with live listeners must be
   refused, not discovered.
10. **Budget onboarding at hours, not days, when the app needs no changes** — but expect most of those
    hours to go to probes and data, not to the runtime.

## Housekeeping left on disk (not removed: outside this session's delete list, or the deliverable)

- `tank/tt-*` (25 state datasets, 607 MiB) with `@tt-base`, `tank/tt-vm-data` zvol (616 MiB) with
  `@tt-base` — the populated TrainTicket state; `benchmarks/trainticket/reset-state.sh` empties them.
- `../micromonkis/vm/out/tt-rootfs.ext4` (24 GiB sparse, 6 GB used), `../micromonkis/vm/out/tt-images.tar` (2.2 GB),
  `../micromonkis/vm/out/snap-ttbase/` (memory file 4.9 GB allocated + a reflinked rootfs copy), `../micromonkis/vm/out/tt-forks.csv`,
  serial and fork logs.
- `/tank/work/trainticket` (upstream clone) and `/tank/work/trainticket-v020` (worktree with the
  one-line "PR"), `codewisdom/ts-ui-dashboard:0.2.0-pr` in the host image store.
- KSM was never enabled in this exercise; `run=0` verified at the end. No `fc-*` resource remains.

## Repeat onboarding — from zero, committed tooling only

Everything from the first run was destroyed first: the 25 `tank/tt-*` datasets and the zvol with
their snapshots, `../micromonkis/vm/out/tt-*`, `../micromonkis/vm/out/snap-ttbase/`, both `/tank/work/trainticket*` checkouts, the
PR image tag; verified with `zfs list`, `ls` and `docker ps` before the clock started. Not destroyed,
because not on the list: the 45 pulled images in the host store — so the repeat never re-pulled them
(44 s in the first run; `tt.sh up` would have pulled them itself, so this is a cache effect, not a
gap). Rules: fresh clone of upstream at `v0.2.0`, only the committed scripts, configuration and
generator, no reading the app.

### Wall clock, first run vs. repeat

| milestone | first run | repeat | repeat step time | what ran |
|---|---|---|---|---|
| clone + datasets | 05:17 → 05:24 (7 m, inventory) | **2 s** | 2 s | `git clone --branch v0.2.0`, `reset-state.sh` |
| native boot to 68/68 + probe | 05:24 → 05:52 (28 m, 3 probe revisions) | **+1 m 26 s** | 83.1 s boot, 1 s probe | `tt.sh up -d --wait`, `probe.sh` |
| 1M orders generated + checked | 05:52 → 06:08 (16 m, 2 regenerations) | **+3 m 27 s** | 103 s | `scale/gen.sh` (defaults) — 1,000,004 orders, 0 dangling |
| `@tt-base` snapshot | 06:08 → 06:12 | **+3 m 35 s** | 8 s (7.2 s frozen) | `snapshot.sh tt-base` |
| **Compose fork serving** | **06:28 (71 min)** | **06 m 51 s** | 85.4 s to healthy + 110 s search probe | `fork.sh 1` |
| data zvol | (ad hoc) | +7 m 35 s | 2 s | **by hand** — see gap 2 |
| rootfs build | 06:29 → 06:31 | +8 m 39 s | 61 s | `vm.sh build` |
| bake | 06:31 → 06:34 | +11 m 39 s | 147 s (guest ready at 126.7 s) | `READY_WAIT=1500 vm.sh bake` — see gap 4 |
| VM boot | 06:35 → 06:38 | +13 m 30 s | UI 16.2 s, **all 68 healthy at 96.4 s** | `vm.sh boot 1` |
| VM snapshot | 06:40 → 06:41 | +13 m 53 s | 23 s (19.9 s frozen) | `vm.sh snapshot 1 ttbase` |
| **VM fork serving** | **06:47 (90 min)** | **14 m 30 s** | `t_load` 27 ms, first 200 at 13.9 s | `vm-fork-measure.sh ttbase 1 --probe` |
| PR → changed system serving | 07:01 | **19 m 10 s** | **9.0 s** | **by hand** — see gap 5 |

The numbers themselves reproduced: native 83.1 s (81.9 / 82.6 before), generator 10,457 orders/s
(10,487), snapshot 7.2 s frozen (6.4), Compose fork 85.4 s to healthy / 14.3 GB (88.4 / 14.4), VM
snapshot 19.9 s (19.9), memory file 4.5 GB allocated (4.9), restore PSS 3.7 GB at 120 s (3.1), PR swap
9.0 s (10.8). One number is new rather than reproduced: **all 68 healthy inside the microVM at 96.4 s**
— the first run only had "≤ 154 s" because `app-up` never wrote its ready file; the hardened `app-up`
was in this build. One number moved: the first restore fork took 13.9 s to its first 200 instead of
9.9 s; same cold page cache, more variance than I would like, and it is the one figure here I would
re-measure before quoting.

Active time equals wall-clock: the run was continuous. Of the 19 m 10 s, ~15 m 45 s is scripts
executing (boots, the generator, the two 110–134 s search probes, the bake), ~1 m 40 s is turn latency
between steps, and the rest is the two hand-done steps.

### Tooling gaps — every point where the repeat needed something not in the repo

1. **Where to clone and which ref.** `tt.sh` hardcodes `/tank/work/trainticket`; the tag `v0.2.0`
   lives only in the ledger. Nothing in the repo runs the clone.
2. **The data zvol is built by hand.** `vm.sh` expects `tank/tt-vm-data@tt-base` and `vm-data.map`
   names the subdirectories, but the zvol's size, block size, filesystem, the copy from each dataset's
   `.zfs/snapshot/tt-base/`, and the final `zfs snapshot` were all recalled, not read. 2 s to run, the
   only step that could not have been done cold.
3. **Free the native stack before booting a 24 GiB guest.** A memory-headroom decision, written
   nowhere.
4. **`READY_WAIT=1500` for the bake.** TrainTicket's UI answers 200 at ~45 s while its JVMs need
   ~130 s; `vm.sh bake` did not set the wait, so a cold operator would have baked a half-started
   stack.
5. **The PR swap is eight manual steps** — detached worktree, the edit, `docker build`, `save`, ship
   over ssh, `load`, retag to the tag the compose file names, `compose up -d --no-deps
   --force-recreate`, poll — held only in the first run's ledger.
6. **Step order is prose.** build → bake → (native down) → boot → snapshot → fork is in the ledger's
   step 5, not in a script.

Not gaps, worth saying: the generator's volume (its defaults are the first run's), the snapshot name
(`fork.sh` and `vm.sh` both default to `tt-base`), the guest size and vCPUs (`vm.sh`), every port, the
`.env` variables upstream leaves undefined (`tt.env`), and readiness (`probe.sh`) were all encoded and
needed no memory.

Closed after the run, and therefore *not* used by the measurement above: `vm-data.sh` (gap 2),
`pr-swap.sh` (gap 5), `onboard.sh` (gaps 1, 3, 6 — the whole order, clone target and tag included),
and `vm.sh bake` now defaults `READY_WAIT=1500` (gap 4). A third run would have nothing to remember.

### Verdict

**The platform now absorbs ~64 of the first run's 71 minutes (~90%).** The repeat reached a working
Compose fork in 6 m 51 s and a VM fork serving a changed build in 19 m 10 s, and essentially all of
that is execution time — two 83–85 s boots, a 96-second guest boot, a 103 s generator, a 147 s bake
and two ~2-minute search probes — with two hand-done steps totalling under a minute. What the first
run spent its hour on — finding out which version was deployable, what to pin, what "healthy" means,
what the documents look like — is now files.

## Third run — the prediction, measured

The repeat section ended with "a third run would have nothing to remember". Tested: full teardown again
(datasets, zvol, `../micromonkis/vm/out/tt-*`, snapshot dir, checkouts — **and the 45 images this time**), then
`onboard.sh` alone, then `vm-fork-measure.sh ttbase 1 --probe`, then `pr-swap.sh 1`. No reading, no
recall. Time-box 30 min.

**The first attempt found a seventh gap, in the tooling itself.** `onboard.sh` stopped silently right
after the `@tt-base` snapshot. `snapshot.sh`'s last line piped its listing through `| head -3` under
`set -o pipefail`; when `head` exits first, `awk` dies of SIGPIPE, the script returns 141 *after a
successful snapshot*, and the caller's `set -e` stops — with nothing printed, because my grep filter had
swallowed the step markers. Timing-dependent, which is why the first three runs got away with it. Fixed
in `snapshot.sh` (no `head`), and `onboard.sh` now logs everything to `../micromonkis/vm/out/tt-onboard.log` and
prints `FAILED (exit n) during: <step>` on error. A better place to find it than in front of a design
partner, as intended.

**Second attempt, from a clean teardown, images purged: 14 m 42 s, zero decisions.**

| milestone | first run | repeat (2nd) | **third run** |
|---|---|---|---|
| native boot to 68/68 (incl. pulling 45 images this time) | 28 m | 1 m 26 s | **2 m 05 s** (pull ≈ 40 s of it) |
| 1M orders generated + checked | 16 m | +3 m 27 s | +3 m 50 s |
| `@tt-base` snapshot | — | +3 m 35 s | +3 m 56 s |
| data zvol, rootfs (61 s), native down, bake (guest ready 125 s) | ad hoc | +11 m 39 s | +7 m 35 s |
| VM boot: UI 22.2 s, **all 68 healthy at 96.5 s** | | +13 m 30 s | +8 m 43 s |
| VM snapshot (20.3 s frozen, 4.5 GB allocated) | | +13 m 53 s | **+9 m 46 s** ← `onboard.sh` exits here |
| **VM fork serving** (`t_restore_to_api_response` 18.2 s, cold — see below) | 90 min | 14 m 30 s | **+10 m 04 s** |
| + 120 s PSS series (3.6 GB) + in-fork search (293 trips, 132 s) | | | +14 m 34 s |
| **PR → changed system serving** | | 19 m 10 s (9.0 s) | **14 m 42 s (7.5 s)** |
| Compose fork, run separately afterwards (not in `onboard.sh`) | 71 min | 6 m 51 s | 91.3 s to healthy, 15.3 GB, isolated; 206 s incl. its search probe |

Decisions made during the run: **none**. Things recalled: **none**. The one remaining choice a cold
operator faces is which of the two follow-up commands to run after `onboard.sh` finishes, and it prints
them.

The absolute time went *down* despite re-pulling the images because the bake and boot no longer wait on
a 120 s ready poll that times out (`app-up` writes its ready file now), and because the second run's
hand-done zvol and PR steps are scripts. Of the 14 m 42 s, everything is execution: a 2-minute native
boot, a 97 s generator, a 60 s rootfs build, a 147 s bake, a 96 s guest boot, a 20 s snapshot, an 18 s
restore, and then 4½ minutes of deliberately slow measurement (the PSS series and a 132 s search at 1 M
orders). The onboarding itself — clone to a snapshotted VM — is **9 m 46 s**.

### Restore variance, measured

The first restore after each fresh snapshot was 9.9 s, 13.9 s, 18.2 s across the three runs, and every
later restore 5.5–6.4 s. Ten consecutive restores of the same snapshot on this box:

| | p50 | p95 | min | max |
|---|---|---|---|---|
| 5 restores after `posix_fadvise(DONTNEED)` on the memory file | 5.3 s | 5.4 s | 5.1 s | 5.4 s |
| 5 restores after `cat mem > /dev/null` (39 s each) | 5.4 s | 5.5 s | 5.0 s | 5.5 s |

Identical — because on ZFS `posix_fadvise` is a no-op and `read()` warms the ARC, not the page cache
that a `MAP_PRIVATE` mapping faults from. Neither changed anything; all ten were warm. So the cold case
was reproduced directly, twice:

| | immediate restore of a *fresh* snapshot | same, after pre-faulting the memory file through `mmap` |
|---|---|---|
| round A | **16.5 s** | **5.5 s** |
| round B | **13.4 s** | **5.5 s** |

**Quote 5.4 s p50 / 5.5 s p95 as the restore time, and 13–18 s for the first restore of a snapshot
nobody has faulted yet.** The spread was never variance in the restore; it was one cold page cache per
snapshot. Engine requirement: after `PUT /snapshot/create`, pre-fault the memory file **through a
mapping**, not with `read()`, and only over its allocated extents (`SEEK_DATA`/`SEEK_HOLE`) — the naive
walk of all 24 GiB took 64 s, of which ~20 GB were holes; the 4.7 GB that matter would take seconds.
Alternatively keep memory files on a filesystem whose read path and mmap share one page cache. Either
way the first fork then costs the same as the tenth.

### Verdict, revised

**The prediction held with one asterisk: the third run needed nothing from memory, and it found one
bug in the tooling (a SIGPIPE that turned a successful snapshot into a silent stop).** Clone to a
snapshotted VM in 9 m 46 s, to a fork serving a changed build in 14 m 42 s, images re-pulled, zero
decisions. The platform absorbs all of the first run's 71 minutes that were thinking; what remains is
boots and a generator — and the boots are what the engine exists to remove.
