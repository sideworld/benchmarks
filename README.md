# benchmarks — every number, and how to get it again

Paraglobe forks a running multi-service system the way ZFS forks a filesystem: snapshot it once,
then start any number of independent copies in seconds, each with its own state, its own network
and its own ports. The point is to give a pull request a production-shaped environment instead of
a fixture-shaped one.

**This repository is the evidence for that claim.** It holds the write-ups, the per-system
adapters used to produce them, and nothing else — no product code, and nothing here runs a fork.
The runtime lives in a separate repository (see [Prerequisites](#prerequisites)).

Every figure in these documents was measured on one machine on a stated date, and each ledger
records the command that produced it, what the hardware was, and what went wrong on the way. A
number you cannot trace to an invocation is a bug in the write-up.

**Start with [`BENCHMARK.md`](BENCHMARK.md)** — the evidence ladder and a per-system ledger with a
definition for every row, so entries added later stay comparable.

## What is actually claimed

Forking a system is easy to demonstrate badly: onboard something small, measure the happy path,
publish the good number. The ladder below is an attempt to make the claim falsifiable by raising
the bar one rung at a time. Each level removes an excuse the level below leaves open.

| level | claim | status |
|---|---|---|
| **L1** | Forks the system it was built for | **done** — [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md), [`-2`](docs/FORK-EXPERIMENT-2.md), [`-3`](docs/FORK-EXPERIMENT-3.md) |
| **L2** | Forks a large foreign microservice architecture with zero application changes | **done** — [TrainTicket](benchmarks/trainticket.md) (41 services, 24 MongoDB, MySQL) |
| **L3** | Forks a foreign system from a different architectural family | **done** — [Mastodon](benchmarks/mastodon.md) (Rails + Sidekiq), [Sentry](benchmarks/sentry.md), [PostHog](benchmarks/posthog.md) (38 containers, ClickHouse), [Mattermost](benchmarks/mattermost.md) (Go) |
| **L4** | Forks a company's proprietary system, with their data model and operational weirdness | **next** — needs a design partner |
| **L5** | The company keeps using forks without us present | pending |

Each system was onboarded with **zero changes to its own source**. Everything system-specific
lives in an adapter in this repository: a Compose override, a readiness probe, a data generator, a
spec file.

## The results are not all flattering, on purpose

A benchmark that only reports wins is marketing. These ledgers keep the failures in, because the
failures are what make the rest checkable:

- **A Sentry number was wrong and is corrected in place.** A 908 ms query time turned out to be an
  artefact of a defect in the data generator, and the conclusion drawn from it was wrong. Both the
  wrong numbers and the correction are in [`benchmarks/sentry.md`](benchmarks/sentry.md).
- **A Mattermost generator wrote NULL messages on 11.6% of posts** and every count-based
  consistency check passed anyway. The defect, the 20M rows it spoiled, and the assertion added to
  catch it next time are in [`benchmarks/mattermost.md`](benchmarks/mattermost.md).
- **An isolation check said the opposite of the truth the first time it ran.**
- **Each system's write-up ends with an honest caveat** naming the conventional alternative and how
  close it gets. For Mattermost it gets within 3×, and the ledger says so.

## What is here

| path | what |
|---|---|
| [`BENCHMARK.md`](BENCHMARK.md) | the evidence ladder and the system-by-system ledger, with row definitions |
| [`docs/FORK-EXPERIMENT-1.md`](docs/FORK-EXPERIMENT-1.md) | Compose + ZFS forks of a 10M-row baseline; hot, clean and vacuumed snapshots |
| [`docs/FORK-EXPERIMENT-2.md`](docs/FORK-EXPERIMENT-2.md) | Firecracker snapshot/restore forks: 2.4 s to serving, isolation, what the engine must do |
| [`docs/FORK-EXPERIMENT-3.md`](docs/FORK-EXPERIMENT-3.md) | where a fork's memory actually goes: 473 MB idle, churn is the cost, KSM |
| [`benchmarks/<system>.md`](benchmarks/) | one ledger per onboarded system: time spent, what broke, protocol results, caveat |
| [`benchmarks/<system>/`](benchmarks/) | that system's adapters — `app.spec`, Compose override, probe, data generator, fork runner |
| [`benchmarks/lib/`](benchmarks/lib/) | the bulk-load profile every generator follows, and why RI triggers come off for a load |

## Prerequisites

The numbers came from one machine: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu 24.04
(kernel 6.8), ZFS with a pool named `tank`, KVM, Firecracker v1.17.0. Reproducing them needs:

- **a Linux host with ZFS and KVM**, and root. Docker with Compose v2. Go 1.24+ for the specimen's
  generator and probe; `psql` for the Postgres-based generators.
- **two sibling checkouts**, because this repository deliberately contains no runtime:

```sh
git clone https://github.com/sideworld/paraglobe.git   paraglobe    # the fork runtime
git clone https://github.com/sideworld/specimen.git    specimen     # the system L1 measures
git clone https://github.com/sideworld/benchmarks.git  benchmarks   # this repo
```

| repo | what it supplies | pinned at |
|---|---|---|
| `../paraglobe` | `vm/` (build, boot, snapshot, fork, measure), `vm/onboard-generic.sh`, `demo.sh` | `2f67539` (2026-09-22) |
| `../specimen` | the multi-tenant helpdesk L1 measures, its 10M-row generator and probes | `498b30e` (2026-09-22) |

> The project was renamed from *sideworld* to *paraglobe*; the GitHub organisation kept the old
> name, which is why the clone URLs say `sideworld/`.

Adapters find the runtime through `PARAGLOBE_DIR` (default `../paraglobe`) and the specimen through
`SPECIMEN_DIR` (default `../specimen`). Set them if your layout differs.

## Reproduce

```sh
# L1 — the specimen at 10M rows, forked and measured
(cd ../specimen && make up && make scale N=10000000 SEED=42 TENANTS=5 && make probe)
../paraglobe/vm/build-kernel.sh && ../paraglobe/vm/build-rootfs.sh && ../paraglobe/vm/bake-rootfs.sh
../paraglobe/vm/boot.sh 1 && ../paraglobe/vm/snapshot.sh 1 base
../paraglobe/vm/measure.sh base 5          # FORK-EXPERIMENT-2
../paraglobe/vm/measure-mem.sh baseline6g 6144   # FORK-EXPERIMENT-3

# L2 — TrainTicket: clone to a snapshotted VM with no decisions to make (~10 min)
benchmarks/trainticket/onboard.sh
benchmarks/trainticket/vm-fork-measure.sh ttbase 1 --probe
benchmarks/trainticket/pr-swap.sh 1

# L3 — any system with a spec, through the generic runbook
../paraglobe/vm/onboard-generic.sh benchmarks/mastodon/app.spec
benchmarks/mastodon/vm-fork-measure.sh mdbase 1
```

Each ledger's time-ledger and protocol-results sections give the exact invocations and the expected
output for every step, including the ones that failed and why they failed.

## A note on the credentials in this repository

The Compose files here carry the default credentials each upstream project ships for local
development — `posthog:posthog`, Mattermost's `mostest_password`, MinIO's published example KMS
key. They protect nothing: the services they belong to are bound to loopback on a throwaway box
and hold synthetic data. Secret scanners will flag them, which is why
[`.gitleaks.toml`](.gitleaks.toml) records each one and why it is allowed.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
