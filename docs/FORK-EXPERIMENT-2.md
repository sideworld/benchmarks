# FORK-EXPERIMENT-2 — Firecracker snapshot/restore forks

> **Paths.** This document was written in a monorepo that has since been split. Paths beginning with
> `../specimen/` or `../snowglobe/` point into the sibling repositories, expected to be checked out
> next to this one (`SPECIMEN_DIR` / `SNOWGLOBE_DIR` in the scripts). Paths without that prefix are in this repo.

Second fork experiment, 2026-09-21, same box: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe,
Ubuntu 24.04 (host kernel 6.8.0-139), Firecracker v1.17.0, guest kernel 6.1.188. Baseline data:
`tank/vm-data@clean2`, a 40 GB zvol holding the 10M-row load (13.3 GB referenced, 4,000,202
conversations in `conv_acme`). Branch: **main**. Tooling: `../snowglobe/vm/`, see `../snowglobe/vm/README.md`.

Experiment 1 forked the *data* and booted a fresh Compose project on top of it. This one forks the
*running machine*: a booted, healthy microVM is snapshotted once, and every fork after that is a
memory-file mmap plus a `zfs clone`.

## Method

| step | how |
|------|-----|
| 1. golden rootfs | `build-rootfs.sh` (debootstrap noble + Docker + the compose project + `docker save` of all 11 images), then `bake-rootfs.sh` boots it once, loads the images, shuts down cleanly and adopts that disk |
| 2. boot | `../snowglobe/vm/boot.sh 1` — 4 vCPU, 6,144 MiB, `/dev/vdb` = `zfs clone` of `tank/vm-data@clean2` |
| 3. snapshot | `../snowglobe/vm/snapshot.sh 1 base` — `CHECKPOINT` every Postgres, `sync`, `fsfreeze -f /data`, pause, `PUT /snapshot/create`, `zfs snapshot`, copy the root disk, resume, thaw |
| 4. fork | `../snowglobe/vm/fork.sh base <k>` — `zfs clone` the data snapshot, reflink the root disk, build a netns, `PUT /snapshot/load` with `resume_vm:false`, repoint both drives, resume, `post-restore` |
| 5. measure | `../snowglobe/vm/measure.sh base 5` → `../snowglobe/vm/out/measure-base.csv` |

## Results

| measurement | value |
|-------------|------:|
| cold `docker compose up --wait` on metal, empty databases (experiment 1) | 31.9 s |
| Compose + ZFS fork of the 10M baseline on metal (experiment 1) | 43.5 s |
| microVM cold boot to healthy (`../snowglobe/vm/boot.sh`, baked rootfs; Phase 1 measurement, `../snowglobe/vm/README.md`) | 27.2 s |
| **`t_load`** — `/snapshot/load` + 2 × `PATCH /drives` + resume | **0.025 s** |
| **`t_restore_to_api_response`** — firecracker exec to first HTTP 200 | **2.4 s** |
| `t_quiesce_pause` — `/data` frozen to thawed | 5.8 s |
| …of which the 8 GiB `cp --reflink=auto` of the root disk | 4.1 s |
| …`PUT /snapshot/create` itself | 1.4 s |
| …`zfs snapshot` | 0.03 s |
| memory file, 6,144 MiB guest | 6,442,450,944 B apparent, ~750 MiB allocated |
| vmstate | 50,394 B |

Per fork, from `../snowglobe/vm/out/measure-base.csv`:

| fork | port | t_load | t_restore_to_api_response | t_clock_ok | pss_mb | rss_mb |
|---|---|---|---|---|---|---|
| 1 | 30180 | 0.023 s | 2.895 s | 0.238 s | 514 | 515 |
| 2 | 30280 | 0.025 s | 2.375 s | 1.626 s | 483 | 632 |
| 3 | 30380 | 0.025 s | 2.365 s | 1.147 s | 432 | 631 |
| 4 | 30480 | 0.031 s | 2.375 s | 2.192 s | 441 | 707 |
| 5 | 30580 | 0.029 s | 2.362 s | 0.744 s | 378 | 629 |

**A fork is 18× faster than a Compose+ZFS fork of the same data** (2.4 s against 43.5 s) and 11× faster
than a cold boot of the same microVM (27.2 s). `t_load` is 25 ms; everything else is the guest faulting its
working set back in and the gateway answering. The per-fork PSS falls from 514 MB to 378 MB as later
forks find more of the memory file already resident in the host page cache.

`t_clock_ok` is measured separately and deliberately excluded from `t_restore_to_api_response`: a fork
serves requests before chrony has stepped its clock.

## Memory

Measured with all five idle and up, a few minutes after restore:

| | value |
|---|------:|
| nominal (5 × 6,144 MiB guest RAM) | 30 GiB |
| **sum of PSS across the five firecracker processes** | **9.2 GB** |
| PSS per idle fork | ~1,140 MB |
| RSS per idle fork | ~1,480 MB |
| implied sharing (RSS − PSS) per fork | ~340 MB |
| fork 1 after running the API suite against it | 4,634 MB PSS / 4,911 MB RSS |

Two things to read off this. Sharing is real but modest: the ~340 MB gap per fork is memory-file pages
the host page cache is handing to all five. And a fork that does real work stops sharing — the API
suite pushed fork 1 from 1,136 MB to 4,634 MB PSS, i.e. it privatised most of its 6 GiB.

## Isolation

With all five forks up, each took one `POST /v1/conversations` through its own gateway, authenticated
by a token minted from its own IdP:

| fork | POST | `conv_globex` before → after | `conv_acme` | clone `used` |
|---|---|---|---|---|
| 1 | 201 | 5 → 6 | 4,000,202 | 1.84 M |
| 2 | 201 | 5 → 6 | 4,000,202 | 1.77 M |
| 3 | 201 | 5 → 6 | 4,000,202 | 1.18 M |
| 4 | 201 | 5 → 6 | 4,000,202 | 1.12 M |
| 5 | 201 | 5 → 6 | 4,000,202 | 884 K |

Five writes, five clones, and every fork went 5 → 6 — never 5 → 10. The 4,000,202-row `conv_acme` is
untouched in all five, and the clones diverge by 0.9–1.8 MB each.

The write targets `conv_globex` (5 rows) rather than `conv_acme` (4,000,202) on purpose: `POST
/v1/conversations` against `acme` 502s after the gateway's 10 s upstream timeout on this data, which is
the specimen's own missing `messages(conversation_id, created_at)` index from experiment 1. A create
that cannot land proves nothing about isolation.

## Postgres and Kafka through the freeze

All 14 containers came back healthy in every fork, with **no crash recovery** in any Postgres log and
no Kafka log-segment complaints. `quiesce` runs `CHECKPOINT` in all four Postgres containers and
`sync`, then freezes `/data`; the memory snapshot, the `zfs snapshot` of the data clone and the copy of
the root disk are all taken inside the same pause, so memory and both disks are one instant. This is
the payoff from experiment 2 of the previous round, where snapshotting an unquiesced Postgres cost
every fork ~12 s and ~800 MB of copy-on-write delta at boot.

A snapshot taken with `/data` frozen restores *frozen*: every fork's first write would block forever.
Thawing is therefore `post-restore`'s first act, before the ARP and before the clock.

## The API suite is identical to bare metal

`make test-api` against fork 1: **14 pass / 18 fail / 1 skip**. Every one of the 18 failures is
`502 UPSTREAM_ERROR ... unreachable (timeout)` on the create and assign paths — the same
`messages(conversation_id, created_at)` sequential scan that failed 18 of 32 on bare metal in
experiment 1. The fork reproduces the specimen exactly, bugs included, which is the result that
matters: a restored machine is not an approximation of the original.

## What broke and what the engine must do

**Drive repoint before resume.** `SnapshotLoadParams` in Firecracker 1.17 has `network_overrides` and
`vsock_override` and nothing for drives, while the vmstate still names the *source* VM's
`rootfs-1.ext4` and `/dev/zvol/tank/vm-fork1`. `PATCH /drives/{id}` is documented "post-boot only" and a
loaded-but-paused microVM turns out to satisfy that, so `fork.sh` loads with `resume_vm: false`,
repoints both drives and only then resumes — no mount namespaces, no bind mounts over `/dev/zvol`.
Resuming first and patching after would have been a data-loss bug, not a style choice: for the few
milliseconds before the PATCH, the fork would be writing to disks the source VM still owns.

**Clock.** `ptp_kvm` works exactly as hoped — `/dev/ptp0` is a hypercall, so it keeps reading true host
time across a restore, and the guest tracks the host to 12 ns. What does *not* work is Firecracker's
`clock_realtime: true` on `/snapshot/load`: with it set, a fork restored from a five-minute-old
snapshot still woke with its clock at snapshot time and `/proc/uptime` unchanged, so chrony had the
full gap to close. The size of that gap then depends entirely on the refclock poll interval, because
chrony needs three samples before PHC0 becomes selectable: at `poll 2 dpoll -2` that is one sample
every 4 s and a measured **13.9 s** on a stale clock; **`poll -2 dpoll -3 filter 3` measures 2.0 s**,
and eight hypercalls a second cost nothing.

**The makestep quirk.** On one fork of five, `chronyc makestep` issued by `post-restore` while chrony
was still in "Can't synchronise: no selectable sources" was followed by PHC0 selection **130 s** later,
where its four siblings selected 1.3 s after noticing. Skewing a live guest with `date -s` reproduces
neither the pathology nor any difference between makestep and no makestep (2.0 s either way), so
`post-restore` now only calls `makestep` when `chronyc tracking` already shows PHC0 — a mitigation for
a suspected interaction, **not a proven fix**. `makestep 1 -1` is what actually does the work.

**ARP, designed out rather than fixed.** A restored guest still has the *source* tap's MAC cached for
its default gateway, and the fork's tap is a new device with a new random MAC, so its first outbound
packet goes to a MAC nobody answers for. Relying on `post-restore` to fix that cannot work — the ssh
carrying `post-restore` is itself outbound traffic. `snapshot.sh` records the source tap's MAC in
`meta.json` and `net-ns.sh` pins the fork's tap to it. `post-restore` still sends a gratuitous ARP,
deliberately with `arping -U` and not `ip link set eth0 down/up`: bouncing the link would kill the ssh
session delivering the command.

**The IdP issuer.** The first `measure.sh` run got a 401 from every fork. `mock-oauth2-server` mints
`iss` from the Host header it was asked on, so a token fetched through the host-side `127.0.0.1:3<kk>90`
forward carries `iss=http://127.0.0.1:30190/helpdesk` while the gateway only trusts
`http://localhost:9090/helpdesk`. The fix is not a port but a namespace: `fc-ns<k>` also DNATs its
*own* `127.0.0.1:9090` and `:18080` at the guest, so `ip netns exec fc-ns<k> make test-api` sees the
fork at exactly the addresses the gateway expects, without colliding with the host's own specimen on
9090.

**Port scheme.** Fork `k` is reachable on `3<kk>80` (gateway), `3<kk>22` (ssh) and `3<kk>90` (IdP), `k`
zero-padded to two digits — fork 1 is 30180 / 30122 / 30190.

**Two of ours.** `ip netns list` prints `fc-ns1 (id: 28)` once a device is attached, so `grep -qx
fc-ns1` silently stopped matching and `net-ns.sh down` left namespaces behind; it tests
`/run/netns/<ns>` now. And `read -r a b < <(awk '{printf "%d %d", ...}')` without a trailing newline
returns non-zero, which under `set -e` killed `fork.sh` one line before it printed any of its
measurements.

## What the engine must do

1. **Snapshot a quiesced machine, not a running one.** `CHECKPOINT` + `sync` + `fsfreeze`, and take the
   memory image, the data snapshot and the root-disk copy inside one pause. Thaw on restore, first.
2. **Repoint every backing file while the restored VM is still paused.** There is no API for it on
   load; the window between resume and repoint is a corruption window on somebody else's disk.
3. **Give each fork its own network namespace.** The guest's address is frozen into the snapshot.
   Pin the fork's tap to the source tap's MAC so the guest's cached ARP entry stays correct.
4. **Give the guest a hypercall clock.** No RTC, no NTP reachable from an isolated fork; `ptp_kvm` plus
   an aggressive refclock poll is the only thing that survives a restore.
5. **Expect every host-visible identity to leak into tokens.** Anything that derives state from the
   URL it was reached on (here, an OIDC issuer) breaks the moment a fork is reached on a different
   port. Namespaces, not port maps.

## Open question: memory

Answered in `docs/FORK-EXPERIMENT-3.md`, including a correction to the 9.2 GB below: five
*genuinely idle* forks sum to 2.3 GB, and 9.2 GB is what they cost after each has served
requests. The three hypotheses were tested; only the third reduced anything, and not reliably.

2.4 s and 9.2 GB is the wrong shape: the time is nearly free and the memory is not. An idle fork
privatises ~1.1 GB of a 6,144 MiB guest that is doing nothing, which caps density at roughly 40 forks
on this box on memory alone, long before CPU. Three hypotheses, tested in experiment 3:

1. **Guest size.** The guest has 6,144 MiB and Linux will use it — page cache, slab, per-CPU
   structures and `vm.min_free_kbytes` all scale with RAM. A 2,048 MiB guest may privatise
   proportionally less for the same workload.
2. **JVM heaps.** Kafka and the mock IdP are both JVMs with heaps they touch continuously; the IdP was
   observed at ~58% CPU while idle. GC that walks the heap dirties pages that would otherwise stay
   clean and shared with the memory file.
3. **No deduplication.** Five forks of one snapshot hold five copies of near-identical dirty pages and
   nothing merges them. KSM with `PR_SET_MEMORY_MERGE` should collapse them, at some ksmd CPU cost.
