# benchmarks — how to reproduce every number

The evidence for the fork runtime in `../micromonkis`, measured on the system in `../specimen` and on two
foreign systems (TrainTicket, Mastodon). Every figure in these documents is measured; the ledgers say
where, when, on what hardware, and with which commands. Nothing here is a product and nothing here runs
the forks — this repository holds the write-ups, the per-system adapters (Compose overrides, readiness
probes, data generators, snapshot and fork runners) and the shared bulk-load profile.

Written for someone who was not in the project: start with [`BENCHMARK.md`](BENCHMARK.md) (the evidence
ladder and the system fork ledger with a definition for every row), then the document for the level you
care about.

## Evidence ladder

| level | claim | status | evidence |
|---|---|---|---|
| **L1** | Forks the system it was built for | **done** | [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md), [`-2.md`](docs/FORK-EXPERIMENT-2.md), [`-3.md`](docs/FORK-EXPERIMENT-3.md) |
| **L2** | Forks a large foreign microservice architecture with zero application changes | **done** | [`benchmarks/trainticket.md`](benchmarks/trainticket.md) |
| **L3** | Forks a foreign system from a different architectural family | **done** — Mastodon v4.7.2 (Rails monolith + Sidekiq + Node streaming, one 100M-row Postgres, Redis as application state) | [`benchmarks/mastodon.md`](benchmarks/mastodon.md) |
| **L4** | Forks a company's proprietary system, with their data model and operational weirdness | **next** — requires a design partner | — |
| **L5** | The company keeps using forks without us present | pending | — |

## What is here

| path | what |
|---|---|
| [`BENCHMARK.md`](BENCHMARK.md) | the evidence ladder and the system fork ledger, with row definitions so future entries are comparable |
| [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md) | L1: Compose+ZFS forks of the specimen's 10M-row baseline; hot, clean and vacuumed snapshots; the create-path finding |
| [`docs/FORK-EXPERIMENT-2.md`](docs/FORK-EXPERIMENT-2.md) | L1: Firecracker snapshot/restore forks, 2.4 s to serving, isolation, what the engine must do |
| [`docs/FORK-EXPERIMENT-3.md`](docs/FORK-EXPERIMENT-3.md) | L1: where a fork's memory goes — 473 MB idle, churn is the cost, KSM |
| [`benchmarks/trainticket.md`](benchmarks/trainticket.md) | L2: TrainTicket 0.2.0 (41 services, 24 Mongo, MySQL) onboarded with zero application changes; first, repeat and third runs; restore variance |
| [`benchmarks/mastodon.md`](benchmarks/mastodon.md) | L3: Mastodon v4.7.2 (Rails + Sidekiq + streaming, one 100M-row Postgres) |
| [`benchmarks/trainticket/`](benchmarks/trainticket/) | TrainTicket adapters: `onboard.sh` (clone → snapshotted VM, no decisions), `vm.sh`, `fork.sh`, `probe.sh`, `pr-swap.sh`, the Compose override generator, the Mongo data generator |
| [`benchmarks/mastodon/`](benchmarks/mastodon/) | Mastodon adapters: `app.spec` for the generic onboarding runbook, probes, migration, SQL data generator |
| [`benchmarks/lib/`](benchmarks/lib/) | the bulk-load profile every generator follows (`BULK-LOAD.md`, `pg-bulk-load-{begin,end}.sql`) |

## Prerequisites

The numbers were produced on one machine: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu 24.04
(kernel 6.8), ZFS (lz4, `ashift=12`) with a pool named `tank`, KVM, Firecracker v1.17.0. To reproduce:

- **a ZFS host with KVM** and root access; Docker with Compose v2; Go 1.24+ (the specimen's generator and
  probe); `mongo:4.4` shell for the TrainTicket generator (pulled by its runner); `psql` for Mastodon's.
- **checkouts of the two sibling repositories next to this one**, at the pinned commits:

| repo | pinned at | why |
|---|---|---|
| `../specimen` | `498b30e` (split point, 2026-09-22) | the system L1 measures; `make scale N=10000000` produced the 10M baseline (`../specimen/data/scale/README.md`), `make probe` the numbers in `../specimen/docs/PROBE-10M.md` |
| `../micromonkis` | `2f67539` (split point, 2026-09-22) | the runtime every fork here ran on: `vm/` (Firecracker build, boot, snapshot, fork, measure), `vm/mkfork-generic.sh`, `vm/onboard-generic.sh`, `demo.sh` |

The adapters find the runtime through `MICROMONKIS_DIR` (default: `../micromonkis` relative to this
repo's root) and the specimen through `SPECIMEN_DIR` (default `../specimen`). Set them if your layout
differs.

## Reproduce

```sh
# L1 — the specimen at 10M rows, forked
(cd ../specimen && make up && make scale N=10000000 SEED=42 TENANTS=5 && make probe)   # data + docs/PROBE-10M.md
../micromonkis/vm/build-kernel.sh && ../micromonkis/vm/build-rootfs.sh && ../micromonkis/vm/bake-rootfs.sh
../micromonkis/vm/boot.sh 1 && ../micromonkis/vm/snapshot.sh 1 base && ../micromonkis/vm/measure.sh base 5   # FORK-EXPERIMENT-2
../micromonkis/vm/measure-mem.sh baseline6g 6144                                                              # FORK-EXPERIMENT-3

# L2 — TrainTicket, clone to a snapshotted VM with zero decisions (~10 min), then fork and swap a PR
benchmarks/trainticket/onboard.sh
benchmarks/trainticket/vm-fork-measure.sh ttbase 1 --probe
benchmarks/trainticket/pr-swap.sh 1

# L3 — Mastodon, through the generic runbook driven by its spec
../micromonkis/vm/onboard-generic.sh benchmarks/mastodon/app.spec
benchmarks/mastodon/vm-fork-measure.sh mdbase 1
```

Each ledger's "time ledger" and "protocol results" sections give the exact invocations and the
expected outputs for every step, including the ones that failed and why.

## License

Apache License 2.0 — see `LICENSE`.
