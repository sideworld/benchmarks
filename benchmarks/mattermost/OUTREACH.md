# Mattermost — the five numbers

Sideworld onboarded `mattermost/mattermost` v11.11.0 onto a fork-per-pull-request runtime on one
machine (Ryzen 7 7700, 64 GB, 2×1 TB NVMe). Every number below was measured on that box on
2026-09-23 and is traceable to a command in [`benchmarks/mattermost.md`](../mattermost.md).

- **Onboarding took 1 h 44 min**, from `git clone` to a pull request getting its own fork with a
  verdict — with **zero changes to Mattermost's code**. Everything lives in an adapter: a Compose
  file, a data generator, a probe.
- **A fork of a 20-million-post Mattermost restores in 4.3 seconds** and costs **~305 MB** of
  host memory. Five ran at once in 1.5 GB, each serving its own copy of a 2.3-million-post
  channel, with 43 GiB still free.
- **A one-line server change reaches a fork serving it in 20.3 s** — 4.7 s of that is
  `make build-cmd-linux`. End to end, a pull request gets a **verdict in 43.6 s**: unpack, build,
  fork, swap, migrate, run seven API checks, compare against the baseline.
- **Scale exposed things fixtures cannot.** Channel history at page 19,416 walks **1,165,020
  index entries to return 60** — `OFFSET` pagination, linear in depth, and *absent* rather than
  merely faster at 200 rows. A plain `CREATE INDEX` from your own migration history
  (`000102_posts_originalid_index`) holds **`ShareLock` on Posts for 6.6 s** — no message can be
  sent for that window. And `VACUUM (ANALYZE)` dies on Docker's default 64 MB `/dev/shm`, which
  no fixture-sized database can reach.
- **A regression gets named, not just detected.** A one-line change that degrades only search
  comes back `6 passed, 1 failed` — **`search`** — while health, channel history, deep paging,
  unread counts across 3,000 channels, and a post-and-read-back round trip all stay green.

**The honest caveat.** For Mattermost specifically, the conventional alternative is closer than
for the other systems we have onboarded. A ZFS clone of the database plus an ordinary
`docker compose up` of the changed server reaches a working API in **11.8 s** against the fork's
4.3 s — under 3×, not the order of magnitude a Rails or Python stack shows — and it is *faster
per request* on small reads (17 ms vs 29 ms warm), because it runs on the host with a warm page
cache while the fork reaches its data through virtio. Go starts fast, and that closes most of the
gap. What the fork still buys is a hard 4 GiB / 4 vCPU blast radius, no host-port scramble
between branches (our first attempt at this comparison failed because another project's container
already held the port), and destroy-and-restore in 4.3 s including memory state. If your pain is
"deploys are slow", this is not your tool. If it is "we cannot give twelve pull requests a
production-shaped Mattermost each, today, without twelve environments", it is.
