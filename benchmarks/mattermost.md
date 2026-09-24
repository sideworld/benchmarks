# Mattermost — onboarding ledger

Written as it happened. Start **2026-09-23T03:56:36Z**. Box: Ryzen 7 7700, 64 GB, ZFS `tank`,
Firecracker 1.17, Go 1.26.7, Node 22.23.2.

At the start: no Firecracker VMs live; 35 containers running (the Mastodon baseline and the
specimen's `fork1`), 45 GiB RAM available, 728 G free on `tank`.

## 1. Clone and inventory

**Pin: `v11.11.0`**, published 2026-09-07 and the tag GitHub's `releases/latest` points at.
`v12.0.0-rc1` is newer (2026-09-18) and is a prerelease, so it is not "latest stable". The fork
`sideworld/mattermost` already existed; shallow clone of the tag took **12.8 s**, 293 MB.

It is a monorepo: `server/` (47 MB, 2,206 Go files), `webapp/` (90 MB), `e2e-tests/` (44 MB),
`api/`, `tools/`. 422 Postgres migration files under `server/channels/db/migrations/postgres/`.

Three things about this repository decide most of what follows, and none of them is visible
from the README:

1. **`server/build/docker-compose.yml` contains no Mattermost server.** It starts fourteen
   *dependencies* — Postgres, MinIO, Azurite, Inbucket, OpenLDAP, Elasticsearch, OpenSearch,
   Redis, dejavu, Keycloak, Prometheus, Grafana, Loki, an OTel collector — because the developer
   workflow runs the server itself on the host with `make run-server`. There is nothing to
   `up` that is Mattermost.
2. **Its Postgres is `tmpfs`.** `tmpfs: /var/lib/postgresql/data`, deliberately volatile, plus a
   `postgres.conf` with `fsync = off` and `full_page_writes = off`. A correct choice for a test
   harness and an impossible one for a world whose entire premise is that its bytes survive a
   snapshot.
3. **`server/build/Dockerfile` does not build from source.** It `curl`s a prebuilt release
   tarball (`ARG MM_PACKAGE`, default "latest stable enterprise") into a distroless base. There
   is no `make build-image` target either. So the image the brief asked for had to be assembled:
   see §3.

**Elasticsearch and Keycloak are out**, and the default configuration is why — not preference.
Mattermost's default `SqlSettings` search is Postgres full-text (there is a GIN index on
`to_tsvector('english', posts.message)` created by their own migrations), and Elasticsearch is an
Enterprise feature that is off unless licensed. Keycloak backs SAML, also Enterprise. Also left
out: Azurite (an *alternative* to MinIO), OpenLDAP and OpenSearch (same reasoning), Redis
(Mattermost's default cache is an in-process LRU), and Prometheus/Grafana/Loki/OTel/dejavu
(observability of the harness, not the product). The world is **Postgres + MinIO + Inbucket +
the server**, which is what the brief named.

## 2. `app.spec`: what a drafter could infer, and what needed a decision

The brief asked for this split explicitly. It is the interesting part of onboarding a fourth
world, because it is the measure of how much of this is still a human judgement call.

| field | inferable? | how |
|---|---|---|
| `APP`, `APP_REPO`, `APP_TAG`, `APP_DIR`, `PROJECT` | **yes** | the repository URL and the release tag; `APP` is a short prefix |
| `SPEC_DIR`, `SNAPSHOT_NAME` | **yes** | boilerplate, identical in all four worlds |
| `GUEST_HTTP=8065`, `GUEST_PORTS` | **yes** | `EXPOSE 8065 8067 8074` in their Dockerfile; 8065 is the only one the API uses |
| `HEALTH_PATH=/api/v4/system/ping` | **yes** | the only unauthenticated 200 in the API reference |
| `SIZE_MB` | **yes** | measured from the images once, mechanically |
| `PROJECT_DIR` | **no** | requires knowing that `extends:` resolves against the project directory **and** that their compose file is not at the repository root. A drafter that copied the Mastodon spec would fail with a filename that does not appear anywhere in the repository |
| `COMPOSE_FILES` | **no** | the honest answer is "not their compose file" — see §1. Deciding to pull three services out of `docker-compose.common.yml` by `extends` and write the server service yourself is a judgement about what the *product* is versus what the *test harness* is |
| `DATASETS` | **partly** | the services with volumes are inferable; that Inbucket has nothing worth keeping, that the server's `/mattermost/data` is empty because files go to S3, and that the *configuration* is in Postgres because we chose `MM_CONFIG=postgres://…`, are all consequences of decisions made elsewhere in this file |
| `HOOK_PRE_UP` | **no** | it exists only because their Dockerfile does not build from source. Nothing in the repository says so except the Dockerfile's `curl` |
| `HOOK_POST_UP` | **partly** | "there must be an admin user" is inferable; that `mmctl --local` is the right way to make one, rather than the first-run web wizard, needs reading their CLI |
| `PROBE` | **no** | the round trip is a policy, not a fact about Mattermost |
| `GEN`, `GEN_ARGS` | **no** | the entire shape of the data — Zipf over channels, what a thread is, which counters must agree — is domain knowledge |
| `MEM_MIB=4096`, `VCPUS=4` | **no** | a starting guess, corrected by measurement (§7) |

Roughly: **the addressing is inferable, the modelling is not.** A drafter could have produced a
spec that clones the right thing at the right tag and points at the right port, and it would have
stopped at the first `docker compose up`.

## 3. `onboard-generic.sh` cold — where it stopped, twice

Run against a deliberately minimal spec (no hooks, pointed straight at their compose file), to
find out what the generic runbook does with a project it has never seen.

**Stop 1, at `up --wait`, 0.0 s in:**

```
open /tank/work/mattermost/docker-compose.common.yml: no such file or directory
```

Compose resolves `extends: file:` — and every relative build context and bind-mount source —
against the **project directory**, not against the directory the compose file sits in. The
runbook hardcoded `--project-directory "$APP_DIR"`. That is fine for three worlds whose compose
file is at the repository root and wrong for any repository that keeps it elsewhere.

**Fixed generically.** `PROJECT_DIR` was added to `vm/onboard-generic.sh`,
`vm/app-snapshot-native.sh` and `vm/build-rootfs-generic.sh`, defaulting to `$APP_DIR`, so the
three existing specs are untouched.

**Stop 2, at `up --wait`, 0.7 s in:**

```
minio Error pull access denied for minio/minio, repository does not exist or may require 'docker login'
```

Not rate limiting and not a missing tag: **`docker.io/minio/minio` now lists zero tags.** The
registry API returns an empty list for the whole repository — MinIO withdrew their Docker Hub
images. The consequence is worth stating plainly: **a clean clone of Mattermost v11.11.0 cannot
start its own test harness today**, through no fault of Mattermost's.

The identical pin is still published on quay.io, verified by digest, so the fix is a registry
redirect and not a version bump:
`quay.io/minio/minio:RELEASE.2024-06-22T05-26-45Z`. Not fixed generically, because there is
nothing generic to fix — this is the second instance of a class already recorded
(TrainTicket's `java:8-jre no longer exists`): **a pinned upstream image can be withdrawn, and
the error Docker reports for it names neither the tag nor the reason.**

## 4. The server image, built from source

`make build-cmd-linux`, their own recipe, then their published release image with the two Go
binaries replaced:

```dockerfile
FROM mattermost/mattermost-team-edition:11.11.0
COPY --chown=2000:2000 bin/mattermost /mattermost/bin/mattermost
COPY --chown=2000:2000 bin/mmctl      /mattermost/bin/mmctl
```

This keeps the client bundle, the prepackaged plugins, the config templates, the document
utilities and the non-root `mattermost` user from the release, and runs *this checkout's* server
code. `mattermost version` inside the image reports `Version: 11.11.0`,
`Build Hash: 50cec2b3…`, which is the tag's commit.

| | |
|---|--:|
| Go build, **cold** (empty build cache, all modules downloaded) | **47 s** |
| Go build, warm, no source change | **6.8 s** |
| `docker build` of the image | **8.0 s** |
| resulting build cache | 3.0 GB |

That 6.8 s is the number the PR-swap path depends on, and it is the reason a Go world behaves
differently from a Rails one in CI.

## 5. Native ready — the gate is a round trip

`docker compose up -d --wait` from empty datasets, then the bootstrap, then the gate.

| | |
|---|--:|
| cold boot, empty datasets (Postgres initdb + **all 422 Mattermost migrations**) | **21.8 s**, repeated **16.8 s** |
| bootstrap (MinIO bucket, admin user, personal access token) via `mmctl --local` | 3 s |
| the coherent core through the REST API — 20 users, 20 channels, 466 memberships, 567 posts | 14.5 s |
| **round trip**: create a team, create a user, log in as them, post, read it back from channel history | **0.38 s** |
| idle RAM, four containers | **270 MiB** (server 119.4, postgres 74.0, minio 70.6, inbucket 5.8) |

The gate is `probe.sh` and it is deliberately not `/api/v4/system/ping`. Ping is served by the Go
HTTP layer and answers while the store is still opening; the round trip crosses the API, Postgres
(Teams, Users, Channels, ChannelMembers, Posts), the session store and the post-list read path.

**Two things that were reported as working and were not**, both caught by disbelieving a number:

- `core.sh` created "20 users, 20 channels and 100 posts" in **2.9 seconds**, which is impossible
  for 120 HTTP round trips. Mattermost's *error* bodies also carry an `id` field —
  `{"id":"app.team.get_by_name.missing.app_error","status_code":404}` — so reading `d['id']`
  blindly turned a 404 into a team id, after which every create silently no-opped. The extractor
  now accepts only a 26-character `[a-z0-9]` id and every create asserts.
- After a `down -v` and a fresh `initdb`, `init-app.sh` reported the personal access token was
  in place because **the file was still there**. The file outlives the database. It now asks the
  server (`GET /api/v4/users/me`) and re-mints on 401.

Both are the same rule from `docs/ENGINE.md` — *an empty artefact is an error, never a pass* —
arriving in a new disguise: an artefact that exists but does not mean what its existence implies.

## 6. Populate — 20 million posts

`scale/core.sh` builds a coherent core through the REST API; `scale/gen.sh` does the volume at
the data plane. Twenty million posts through the API at ~20 requests/second would be eleven days.

**Shape.** One team, 3,022 channels, 2,022 users, **19,999,042 posts** distributed Zipf(1.0)
across the channels, with threads, reactions and file metadata hanging off them:

| | |
|---|--:|
| busiest channel `gen-1` | **2,329,984** posts |
| second, third | 1,164,992 · 776,661 |
| quietest generated channel | **776** |
| replies (posts with a `rootid`) | 3,998,192 |
| threads | 3,998,192 roots with replies |
| reactions | 1,996,103 |
| file metadata rows (pointing at MinIO paths) | 379,690 |
| channel memberships | 28,389 |
| logical size | **14 GB** (posts heap 4,641 MB, posts indexes 6,700 MB) |
| on ZFS | **8.96 GB**, compressratio **2.00×** |

| phase | |
|---|--:|
| load — users, channels, the Zipf plan, memberships, 19,998,480 posts (indexes dropped) | **382.5 s** (52,300 rows/s) |
| rebuild 12 secondary indexes, two of them GIN over 20M messages | **220.1 s** |
| derive — threads, thread memberships, reactions, file metadata | **620.4 s** |
| counters — `Channels.TotalMsgCount` / `LastPostAt`, `ChannelMembers.MsgCount` / `LastViewedAt` | **41.2 s** |
| `VACUUM (ANALYZE)` all tables + `CHECKPOINT` | **200.8 s** |

The counters are not optional decoration. Mattermost sorts channel lists by `LastPostAt` and
computes every unread badge as `ChannelMembers.MsgCount` against `Channels.TotalMsgCount`. A
generator that fills Posts and skips these produces a database that is large and a product that
is wrong.

`derive` at 620 s is the slow phase and most of it is one statement: the `UPDATE posts SET fileids`
that back-links 379,690 posts to their file rows, which runs *after* the indexes are back and so
pays thirteen index updates per row. Setting `fileids` inline during the load would remove it
entirely — `fileid` is `md5('mmf:'||postid)`, a pure function of the post, so it is knowable at
insert time. Left as it ran, because these are the numbers the rest of this document was measured
against.

### The defect in my own generator, and why every check missed it

The first full attempt produced **NULL messages on 11.6% of posts**. Cause:

```sql
COALESCE(SUM(n_posts) OVER (…), 0) AS lo      -- SUM() over bigint returns NUMERIC
```

`lo` numeric made `generate_series(lo+1, lo+n)` yield numeric, which turned every `n / 16` from
integer division into exact division. `127/16 = 7.9375`, and `1 + (7.9375 % 8)` rounds to
subscript **9** on an 8-element array — and an out-of-range array subscript in Postgres is
**NULL, not an error**. The concatenation then nulled the whole message.

What is worth recording is not the bug but which checks did not catch it. Every count matched.
Every referential check passed: 0 orphaned replies, 0 cross-channel replies, 0 thread
`replycount` disagreements, 0 channels with a wrong `TotalMsgCount`. The database was internally
consistent and wrong. It surfaced only when **Mattermost itself** was asked for a page of
history:

```
app.post.get_root_posts.app_error
  → failed to find Posts: sql: Scan error on column index 10, name "message":
    converting NULL to string is unsupported
```

and even then only at `per_page >= 60`; a five-post page happened to miss every NULL row.
`gen.sh` now asserts `0 posts where message is null or message = ''` before it will call the
world populated, and the loader runs in one transaction so a failed attempt leaves nothing
behind. Two other faults fixed in the same pass: `g * 3600000` overflowed int4 at g = 597
(`integer out of range`), and the index-drop loop ran `docker exec -i` inside
`while read … < <(…)`, so the first `DROP` swallowed the rest of the index list and exactly one
index was dropped.

### A Docker default that only 20 million rows can find

`VACUUM (ANALYZE) posts` failed with

```
could not resize shared memory segment "/PostgreSQL.681843462" to 536907840 bytes:
No space left on device
```

Docker gives a container **64 MB of `/dev/shm`**, and Postgres puts parallel workers' shared
tuplestores there. Nothing plans a parallel scan over 500 fixture rows, so this cannot happen at
fixture scale. `shm_size: 1gb` fixes it. Mattermost's own compose does not set it either.

## 7. Probes at 20 million posts

Every probe goes through the public REST API with a token, five runs, median reported. Target:
`gen-1`, 2,329,984 posts; a user in 3,000 channels.

| probe | p50 | |
|---|--:|---|
| channel history, page 1 | **10 ms** | 61 posts |
| channel history, **page 19,416** (halfway back) | **202 ms** | 61 posts |
| search `deployment` (Postgres full-text, their GIN index) | **18 ms** | 100 matches |
| unread counts across 3,000 channels | **21 ms** | 3,000 memberships, all with unread |
| the round trip, still | **0.32 s** | |

Only the deep page crossed the threshold, and its plan is the finding:

```
Limit  (actual time=248.766..248.778 rows=60 loops=1)
  Buffers: shared hit=96105
  ->  Index Scan Backward using idx_posts_channel_id_delete_at_create_at on posts
        (actual time=0.054..156.432 rows=1165020 loops=1)
        Index Cond: channelid = '…' AND deleteat = 0
JIT: … Total 69.044 ms
Execution Time: 260.377 ms
```

**It walks 1,165,020 index entries to return 60.** This is `OFFSET` pagination: the cost is
linear in how far back you are, the index is the right index and is being used correctly, and no
amount of tuning changes it. At 200 fixture posts the same request touches a handful of pages and
returns in under a millisecond, so the behaviour is not merely faster at fixture scale — it is
*absent*. Note also that 69 ms of the 260 ms is JIT compilation, which only kicks in because the
estimated cost crosses `jit_above_cost`; that too cannot happen on a small table.

The other three are genuinely fast, and it is worth saying why rather than implying the runtime
did it: Mattermost's own migrations create exactly the indexes these paths need —
`idx_posts_channel_id_delete_at_create_at` for history, a GIN index on
`to_tsvector('english', message)` for search — and unread counts are a 3,000-row join on
`channelmembers`. This world is well-indexed. The pathology is the pagination strategy, not the
schema.

## 8. A migration from their own history, at full size

Two, replayed verbatim from `server/channels/db/migrations/postgres/`. All 422 already ran at
first boot against an empty database; these drop what they create and replay the file byte for
byte against 19,999,054 posts.

| migration | duration | lock held |
|---|--:|---|
| `000130_system_console_stats` — three materialized views, two of which join every post to its channel | **13.1 s** | `AccessShareLock` on posts, channels |
| `000102_posts_originalid_index` — a plain, non-`CONCURRENT` `CREATE INDEX` on Posts | **6.6 s** | **`ShareLock` on posts** |

`000102` is the one to look at. `ShareLock` does not block reads, and it blocks **every write**:
for 6.6 seconds nobody on that server can send a message. The migration is one line, it is theirs,
and at fixture scale it completes in about a millisecond. The resulting index is 132 MB.

`file_stats` reports 379,690 files totalling **171 GB** of metadata-declared size — the rows
address MinIO objects that were never uploaded, which is stated plainly in §6 and in the
generator's own comment. Issue lists, search, counts, unread badges and file *metadata* are fully
exercised; downloading a synthetic attachment is not.

## 9. The microVM path

| step | |
|---|--:|
| rootfs build (noble minbase + 4 images, 774 MB of `docker save`) | **66.2 s** |
| bake (boot a scratch VM once to `docker load`, then publish `tank/rootfs-mm@baked`) | **44.8 s** |
| native quiesce + clean stop + `zfs snapshot` + start — **frozen window** | **6.7 s** |
| data zvol from the snapshots (`tank/mm-vm-data`, 64 G sparse) | **73.3 s** |
| microVM **cold boot to ready** (4 vCPU, 4 GiB) | **15.0 s** |
| VM snapshot (`vm/out/snap-mmbase` + `tank/mm-vmfork1@mmbase`) | **5.8 s** |

Cold boot at 15.0 s against 21.8 s natively, with the same four containers — the guest starts
from a rootfs that already has the images loaded, so there is no pull and no layer extraction.

### Five forks

Restored from `mmbase`, each an independent microVM with its own data clone, root-disk clone and
network namespace:

| fork | restore | busiest channel | PSS @ t+120 s |
|---|--:|--:|--:|
| 1 | 4.32 s | 2,329,984 posts | 305 MB |
| 2 | 4.29 s | 2,329,984 | 307 MB |
| 3 | 4.52 s | 2,329,984 | 306 MB |
| 4 | 4.30 s | 2,329,984 | 311 MB |
| 5 | 4.30 s | 2,329,984 | 299 MB |
| | | **summed** | **1,528 MB** |

Five full Mattermosts, each carrying twenty million posts, in **1.5 GB** of host memory and
**4.3 seconds** each. Host afterwards: 43 GiB still available.

**Isolation.** A post written through fork 1's API is present in fork 1 and absent from forks
2–5, checked by id through `/api/v4/posts/{id}`.

That check was wrong the first time and said the opposite — *"forks are not isolated"* for all
four. The runtime was fine: five firecracker processes, five namespaces, five distinct guest IPs.
The test was reading `d['id']` from the response and treating non-empty as "present", and
Mattermost's 404 body is `{"id":"app.post.get.app_error", …}` — whose `id` is the **error code**.
This is the second time this API's error shape produced a confident wrong answer in this world;
the first was `scale/core.sh` in §5. The fix both times is the same: compare to the value you
expect, never test for non-empty.

### PR → changed system serving

One line in `server/channels/api4/system.go` so `/api/v4/system/ping` returns
`"ParaglobePR": "pr1"` — unauthenticated, so "is this fork running the pull request's code?" has
a yes/no answer rather than an inference.

| | |
|---|--:|
| `make build-cmd-linux` (their recipe, warm cache) | **4.7 s** |
| `docker build` the image | 6.3 s |
| `docker save` → ssh → the fork | 4.1 s |
| `docker load` + `compose up --force-recreate mattermost` | 4.6 s |
| until `/api/v4/system/ping` reports the marker | 0.5 s |
| **total, source edit → fork serving the change** | **20.3 s** |

Afterwards fork 1 reports `ParaglobePR=pr1`; forks 2 and 3 report it absent, and fork 1 still
serves `gen-1` with 2.3 M posts. Go is the reason this is 20 s and Mastodon's equivalent is 67 s:
there is no trick here, the server really is recompiled from source.

## 10. The alternative a team would use today

A ZFS clone of the database as a "database branch", plus a conventional cold
`docker compose up` of **the same changed image** on the host. Same box, same data, same work.

| | ZFS branch + conventional deploy | Firecracker fork |
|---|--:|--:|
| make the branch | **0.1 s** (copy-on-write) | — |
| to the API answering | **11.8 s** | **4.3 s** |
| channel history, first request | 37 ms (61 posts) | 82 ms (61 posts) |
| channel history, warm | **17 ms** | 29 ms |
| memory | **400 MiB** (4 containers) | 589 MiB (one process, fixed 4 GiB / 4 vCPU envelope) |
| disk for the branch | 868 K | 1.3 MB |
| carries the changed server | yes (`ParaglobePR=pr1`) | yes |

**This is the world where the alternative is most competitive, and it should be said plainly.**
A Go server starts in seconds, so a conventional cold deploy against a cloned database reaches a
working system in 11.8 s — under three times the fork's 4.3 s, not the order of magnitude the
Rails and Python worlds showed. It is also *faster per request* on these two reads, because it
runs on the host with the host's page cache already warm, while the fork reaches its data through
virtio over a freshly cloned zvol.

What the alternative cannot reach:

- **It shares one kernel, one Docker daemon and one page cache with everything else on the box.**
  A runaway query in one branch is felt by every other branch and by the baseline. The fork has a
  hard 4 GiB / 4 vCPU envelope.
- **Every branch needs its own free host port block, and the box does not have infinite ones.**
  This is not hypothetical: the first attempt at this measurement failed because port 5441 was
  already held by `specimen-gateway-db-1` — a container belonging to a *different world* running
  on the same box — and Docker reports that only as `port is already allocated`.
- **There is no machine-level rollback.** A branch that has been written to must be destroyed and
  re-cloned and the containers restarted; a fork is destroyed and re-restored in 4.3 s, memory
  state and all.
- **Nothing is restored warm.** The 11.8 s buys a *cold* process: empty Go heap, empty connection
  pools, empty `shared_buffers`. The fork resumes a process that was already running. On these
  two small reads that does not pay for itself; on anything that depends on warm process state it
  does.

## 11. CI — a pull request gets its own fork

`ops/ci/mattermost.yml`, `ops/ci/suites/mattermost-smoke.sh`, `ops/ci/workflows/mattermost.yml`.
Slots 8 (source) and 15 (fork), `exclusive: false` — four containers in a 4 GiB guest do not need
the box to themselves.

**Baseline**, built in **37 s**: snapshot in 22 s (source VM ready at 14.2 s, 568 MB on disk),
then the suite twice against an unmodified fork.

> **7 of 7 pass, both runs, nothing flaky, 0 known-failing.**

That is worth contrasting with the specimen, whose fixture-era API suite fails 20 of 33 at ten
million rows. The difference is not that Mattermost is better written; it is that these checks
were written against this world *at this size*, and Mattermost's own migrations create the
indexes the checks depend on.

**The suite is seven checks**, and `round_trip` is the one that matters: it posts a message and
reads it back out of channel history, so a server that answers `/api/v4/system/ping` while its
store is broken fails here and nowhere else.

Their own `e2e-tests/` (Playwright and Cypress, browser-driven) is **available and deliberately
not wired in**: it needs a browser matrix and tens of minutes, which is a different kind of job
from a per-pull-request verdict. Named, not dropped.

| | PR #1 `ci/pr-1-ping-marker` | PR #2 `ci/pr-2-break-search` |
|---|---|---|
| the change | one line: `/api/v4/system/ping` returns `ParaglobePR: pr1` | one line: a scoping token is appended to the search terms |
| expected | green | red |
| **got** | **green — 7/7, 0 new** | **RED — 1 new: `search`** |
| total | **43.6 s** | 45.3 s |

| phase | #1 green | #2 red |
|---|--:|--:|
| unpack the checkout (276 MB, 15,544 files, over stdin) | 9.6 s | 9.5 s |
| plan (changed paths → services) | 0.0 s | 0.0 s |
| build `mattermost` from source | **11.3 s** | 13.6 s |
| restore a fork of the baseline | **4.1 s** | 4.9 s |
| ↳ snapshot load | 0.027 s | 0.035 s |
| ↳ data + root disk, cloned | 0.268 s | 0.278 s |
| ↳ network namespace | 0.096 s | 0.094 s |
| swap the image in and serve again | 13.4 s | 12.3 s |
| migrations forward | 0.3 s | 0.3 s |
| suite | 4.0 s | 3.6 s |
| teardown | 0.6 s | 0.6 s |

**The red is the useful one.** It reports `6 passed, 1 failed` and names `search` — while
`health`, `channel_history`, `history_at_scale` (2,329,984 posts), `deep_page`, `unread_counts`
(3,000 memberships) and `round_trip` all stay green. The server is healthy, messages still post
and still come back; exactly one endpoint returns nothing. That is the shape a real regression
has, and it is the shape Sentry's red could not produce — there, the change stopped the app from
starting, so the suite never ran and the comment could only say "the run did not complete".

**Two generic fixes this world needed in the CI code**, both in `ops/ci-compose.py`:

- **`CI_COMPOSE_FILE` may now be an absolute path.** Three worlds ship a deployable Compose file
  in the application repository; Mattermost ships none at all. The file that describes the
  deployed world lives with the world's adapter, and reading it from there has a second benefit:
  a pull request cannot edit the image mapping that is used to judge it.
- **`${NAME:-default}` is now interpolated.** A Compose file that must run on the host, in the
  guest and in a fork writes its image as `${MM_SERVER_IMAGE:-paraglobe/mattermost-server:v11.11.0}`,
  and the default *is* the answer. Previously only `${NAME}` and `$NAME` were handled and the
  planner reported the whole `${…}` verbatim. Regression-tested against TrainTicket's
  `${IMG_REPO}/ts-order-service:${IMG_TAG}` and Mastodon's plain tag.

Not run on github.com. `sideworld/mattermost` exists, but these two pull requests went through
`ops/ci-runner-sim.sh`, which is the same path minus the GitHub-hosted runner.

## 12. Where the time went

Start 2026-09-23 03:56 UTC, end 05:40 UTC — **1 h 44 min**.

| | |
|---|--:|
| clone, inventory, and finding out what their Compose actually is | 10 min |
| `onboard-generic.sh` cold — two stops, both fixed generically | 6 min |
| the server image from source, and the Compose/Postgres design | 18 min |
| native ready, bootstrap, the round-trip gate, two self-inflicted faults | 12 min |
| **populate: the generator, its NULL-message defect, and 20M rows** | **34 min** |
| probes, EXPLAIN, two migrations | 8 min |
| the microVM path, twice (a quiesce fix forced a rebuild) | 20 min |
| five forks, PSS, isolation, PR swap | 9 min |
| alternative baseline (two port collisions) | 7 min |
| CI: config, suite, baseline, green and red | 10 min |

### Unsupported or not done — named, not dropped

| | status |
|---|---|
| their `e2e-tests/` (Playwright + Cypress) | **available, not wired.** Browser-driven and tens of minutes; a different job from a per-pull-request verdict. The CI suite is seven API checks plus the probes |
| Elasticsearch, Keycloak, OpenLDAP, Azurite, OpenSearch, Redis, Prometheus/Grafana/Loki/OTel | **deliberately out.** Default Mattermost search is Postgres full-text and the rest are Enterprise features or observability of the harness, not the product. §1 |
| file *bytes* in MinIO | **not uploaded.** 379,690 `FileInfo` rows address correctly-shaped MinIO paths and `file_stats` totals 171 GB, but the objects do not exist. Lists, search, counts, unread and file metadata are exercised; downloading a synthetic attachment is not |
| webapp changes in CI | **refused, loudly.** Our image takes the client bundle from the published release and replaces only the Go binaries, so a `webapp/` change would be built and not served. `ops/ci/mattermost.yml`'s `pre` fails the run with that explanation rather than reporting green |
| a pull request on github.com | **not opened.** Both ran through the runner simulator |
| more than 5 concurrent forks | **not measured.** Five were, at 1,528 MB summed PSS with 43 GiB still free; the ceiling was not looked for |
| user creation above 200 | **impossible, by the product.** `maxUsersLimit = 200` unlicensed (`channels/app/limits.go:13`). This world has 2,022 users, so `POST /api/v4/users` returns `ERROR_SAFETY_LIMITS_EXCEEDED`. Existing users log in and post normally; the readiness probe detects this and falls back to an existing user, saying so |

### What this world taught the runtime

Five fixes, all generic, all found by this world and none specific to it:

1. **`PROJECT_DIR`** — Compose resolves `extends:` and relative mounts against the project
   directory, which the runbook hardcoded to the repository root.
2. **The Postgres quiesce passes a password and uses `-w`** — in `vm/app-snapshot-native.sh`
   *and* in the guest's `quiesce`. Mattermost is the first world whose Postgres sets
   `--auth-local=scram-sha-256`; `vacuumdb` with no password and stdin at EOF re-prompts forever.
   It emitted **76,606** `Password:` lines before it was killed, while the runbook displayed only
   "VACUUM ANALYZE (all databases)". A hang that looks like work is worse than a crash.
3. **`CI_COMPOSE_FILE` may be absolute** — for a world whose repository ships no deployable
   Compose file.
4. **`${NAME:-default}` interpolation** in the CI image planner.
5. **`shm_size`** is now part of what a Postgres service needs in these worlds — Docker's 64 MB
   `/dev/shm` kills a parallel `VACUUM` at 20 million rows and cannot fail at fixture scale.

And one rule that keeps arriving in new clothes: **an artefact that exists is not an artefact
that means what you think.** Three instances in this world alone — a 404 body whose `id` is an
error code, read as a team id and then as "the post is present in every fork"; a `.token` file
that outlived its database; a `0.0 s` channel-history page that was a formatter's rounding and
could just as easily have been a 403. Every one of them reported success.
