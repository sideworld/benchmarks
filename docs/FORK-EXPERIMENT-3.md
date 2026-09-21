# FORK-EXPERIMENT-3 — where a fork's memory goes

Third fork experiment, 2026-09-21, same box: Hetzner Ryzen 7 7700, 64 GB DDR5, 2×1 TB NVMe, Ubuntu
24.04 (host kernel 6.8.0-139), Firecracker v1.17.0, guest kernel 6.1.188. Same baseline data as
experiment 2: `tank/vm-data@clean2`, 13.3 GB referenced, 4,000,202 conversations in `conv_acme`.
Branch: **main**. Tooling: `vm/measure-mem.sh`.

Experiment 2 forked a running machine in 2.4 s and left one number looking wrong: five idle forks of a
6,144 MiB guest cost 9.2 GB of PSS. Time was nearly free and memory was not, which caps density at
roughly 40 forks on this box on memory alone, long before CPU. This experiment asks why, and how far
down it goes.

## Method

`./vm/measure-mem.sh <variant> [mem_mib]` runs one variant end to end: boot slot 1 at the given guest
size, snapshot it, restore five forks, and sample each fork's `/proc/<fc pid>/smaps_rollup` — `Pss`,
`Pss_Anon`, `Pss_File`, `Rss` — at t+10 s, t+60 s and t+120 s **after that fork's own restore**, plus a
simultaneous read across all five at each checkpoint. It also records a cumulative
sum-across-forks-1..k immediately after each fork turns healthy, so the marginal cost of a fork is a
measured quantity rather than a subtraction of two unrelated moments, and it probes inside fork 1 for
`docker stats` and the guest's own `memory.stat`.

Series in `vm/out/measure-mem-<variant>.csv`, roll-up in `vm/out/measure-mem-summary.csv`.

## The first result is a correction to experiment 2

**An idle fork is 473 MB of PSS, not 1,140 MB.** Experiment 2's figure was taken after every fork had
minted six persona sessions and taken a create through its gateway. Five genuinely idle forks sum to
**2,311 MB**, not 9.2 GB. Every number below is against that.

The 9.2 GB figure is not wrong, it is just a different question: it is what five forks cost *after
they have done some work*, and the gap between 2.3 GB and 9.2 GB is itself the headline — see
"Churn is the cost" below.

## Results

| variant | guest | PSS/fork @120 s (median) | sum PSS, 5 forks | anon | file | marginal fork 5 | `t_restore` (median) |
|---|---|---|---|---|---|---|---|
| `baseline6g` | 6,144 MiB | 473 MB | 2,311 MB | 1,889 MB | 422 MB | 398 MB | 2.38 s |
| `guest2g` | 2,048 MiB | **449 MB** | **2,253 MB** | 1,825 MB | 424 MB | 461 MB | 2.38 s |
| `jvmtrim` | 2,048 MiB | 540 MB | 2,659 MB | 2,210 MB | 446 MB | 498 MB | 2.39 s |
| `jvmtrim2` | 2,048 MiB | 489 MB | 2,368 MB | 1,925 MB | 443 MB | 402 MB | 2.40 s |
| `ksm` | 2,048 MiB | 506 MB | 2,583 MB | 2,207 MB | 372 MB | 676 MB | 2.40 s |

`t_restore_to_api_response` is 2.38–2.40 s in every variant: nothing here regressed what experiment 2
was for. The whole memory spread is 2,253–2,659 MB, ±8% around 2,400, and **the best variant is the
one that changes least**.

Guest-side, from inside fork 1:

| | baseline6g | guest2g | jvmtrim | jvmtrim2 |
|---|---|---|---|---|
| guest `anon` | 992 MB | 924 MB | 1,000 MB | **884 MB** |
| guest `file` | 1,021 MB | 859 MB | 755 MB | 908 MB |
| kafka RSS | 447 MB | 399 MB | 421 MB | **372 MB** |
| idp RSS | 237 MB | 230 MB | 260 MB | **222 MB** |
| otel-collector RSS | 156 MB | 160 MB | 160 MB | 159 MB |
| guest available | 4,569 MB | 738 MB | 678 MB | 804 MB |

## Hypothesis 1 — guest size. Wrong.

Booting 2,048 MiB instead of 6,144 MiB moved PSS by 2.5%: 473 → 449 MB per fork, 2,311 → 2,253 MB
summed. Tripling a guest's RAM is almost free. The guest's own accounting barely moves either
(anon 924 MB at 2 GB against 992 MB at 6 GB), which is the giveaway: what a fork privatises is what its
workload *dirties*, not what the guest is *sized for*. Page cache, slab and per-CPU structures scale
with RAM, but they are clean and shared with the snapshot's memory file, so they cost nothing per fork.

The real win from a small guest is somewhere else entirely. The memory file is 3× smaller, so
`PUT /snapshot/create` drops from **1.43 s to 0.52 s** and `t_quiesce_pause` — the window in which the
source VM's `/data` is frozen — from 5.9 s to 5.1 s. The cost is headroom: a 2 GiB guest sits at
738 MB available, against 4,569 MB at 6 GiB.

## Hypothesis 2 — JVM heaps. Wrong, and backwards.

Kafka at `-Xmx384m -Xms384m` and the IdP at `-Xmx192m -Xms192m`, both with SerialGC, baked into the
generated `docker-compose.vm.yml`. Both services healthy. PSS went **up 20%**, to 540 MB per fork and
2,659 MB summed, and Kafka's own RSS *rose* from 399 to 421 MB.

`-Xms` equal to `-Xmx` is the whole problem: it makes the JVM commit the entire heap at startup, so it
raises the RSS floor instead of lowering the ceiling, and capping `-Xmx` does nothing for a heap the
workload never filled. `jvmtrim2` — same caps, `-Xms64m` and `-Xms32m` — recovered most of it at
489 MB / 2,368 MB and gave the guest the **smallest footprint of any variant**: Kafka 372 MB, IdP
222 MB, guest anon 884 MB, every one best in the table.

And it still lost to leaving the heaps alone.

### Churn is the cost

That inversion is the finding of the experiment. **PSS measures pages dirtied *after* the snapshot.**
A heap that was fully committed and touched *before* the snapshot is already in the memory file: every
fork maps those pages clean, shares them through the host page cache, and pays a fraction of a page
each. A heap that starts small and grows *afterwards* dirties fresh pages in each fork independently,
and every one of those is a private copy.

Pre-touched and stable is free. Churn is what costs. Which is also why experiment 2's forks were at
1,140 MB and these are at 473 MB: the difference is not size, it is six minted sessions and a create.

## Hypothesis 3 — deduplication. It works, and it is not dependable.

`vm/ksm-exec` calls `prctl(PR_SET_MEMORY_MERGE, 1)` and `execv`s firecracker. The flag survives the
exec (`MMF_VM_MERGE_ANY` is in `MMF_INIT_MASK`, and 6.7+ re-registers the new mm from `ksm_execve`),
and every fork shows 58 mergeable VMAs including the 2 GiB guest-RAM mapping — which is a `MAP_PRIVATE`
mapping of the snapshot's memory file, so its clean pages are shared page cache already and only the
COW'd pages are KSM's to merge.

Two results, which do not reconcile. Both are recorded.

**Controlled A/B, same five processes, ksmd demonstrably scanning.** 166,148 pages merged
(`general_profit` 599 MB). `echo 2 > /sys/kernel/mm/ksm/run` to unmerge, then re-measure:

| | sum PSS, 5 forks |
|---|---|
| KSM merged | **2,920 MB** |
| unmerged | **3,564 MB** |
| saving | **644 MB, 18.1%** |

Cost: ~1.8% of one core at the briefed `pages_to_scan=100 sleep_millisecs=20`, rising to ~68% of a core
for 170 K pages at 100× that scan rate. This is the only real reduction anything in this experiment
produced.

**Scripted variant, three separate runs** (600 s, 1,200 s, and 600 s with a re-kick every two seconds):
1,549 / 3,342 / 4,616 pages merged, summed PSS unchanged. ksmd scans for a few seconds right after the
forks start — the guard in `measure-mem.sh` measured ~4,700 pages/s — and then parks itself for the
remainder of the run, with `run=1`, five marked processes in front of it, every guest-RAM VMA flagged
`mg`, and `ksmd_cpu` frozen to the tick. `pages_scanned` and `full_scans` both stall. Writing `run`
again does not revive it.

Why ksmd stops is **unexplained**. It is not the shim and not the VMA flags. Until it is understood,
18% is a ceiling to aim at, not a number to plan density on. The liveness guard stays in
`measure-mem.sh`, because without it the variant returns a confident, wrong zero.

## The marginal fork

Cumulative summed PSS as each fork comes up, and the difference each one adds:

| variant | +1 | +2 | +3 | +4 | +5 |
|---|---|---|---|---|---|
| `baseline6g` | 468 | 587 | 396 | 441 | **398** |
| `guest2g` | 447 | 528 | 396 | 409 | **461** |
| `jvmtrim` | 508 | 630 | 503 | 499 | **498** |
| `jvmtrim2` | 514 | 513 | 448 | 436 | **402** |
| `ksm` | 440 | 615 | 389 | 427 | **676** |

The marginal fork is flat at roughly 400–500 MB from the third onwards, in every variant. There is no
economy of scale beyond the second fork: the host page cache is already sharing everything shareable by
then, and each additional fork brings its own churn. Density on this box is therefore about
**(RAM − host) / 450 MB**, or ~100 forks on 64 GB before anything else binds — not the ~40 experiment 2
implied, but still memory-bound rather than CPU-bound.

## What broke

**`-XX:+UseSerialGC` in `KAFKA_HEAP_OPTS` breaks every Kafka CLI tool.** `kafka-run-class.sh` defaults
`KAFKA_JVM_PERFORMANCE_OPTS` to `-server -XX:+UseG1GC ...` when it is unset, so the tools get two
collectors and die with "Error occurred during initialization of VM / Multiple garbage collectors
selected". The broker ran perfectly. What died, in 0.19 s, was its *healthcheck* — which is one of
those tools — so Kafka never went healthy, `kafka-init` never fired, not one app service started, and
`boot.sh` sat in its 900 s health poll looking like a hang. SerialGC belongs in
`KAFKA_JVM_PERFORMANCE_OPTS`, where broker and tools see one collector.

**The IdP needs `JAVA_TOOL_OPTIONS`, not `JAVA_OPTS`.** Its entrypoint is
`java -cp @/app/jib-classpath-file ...` with no shell to expand the latter. `JAVA_TOOL_OPTIONS` is read
by the JVM itself however it was launched, and it announces itself in the log ("Picked up
JAVA_TOOL_OPTIONS: ..."), which is the only reason the mistake would be caught.

**`bake-rootfs.sh` had no cleanup path**, so that failed boot stranded slot 9's clone, tap and rootfs
copy for twelve minutes. It traps EXIT and runs `stop.sh` now. `build-rootfs.sh` also keeps the image
it replaces as `vm/out/rootfs.prev.ext4`.

**Two of ours.** `PSSCUM[NFORKS]` inside `$(( ))` looks up the literal key `NFORKS` in an associative
array, so the marginal cost came out as −1,871 MB on the first run. And `t_quiesce_pause`'s trailing
comment leaked into the CSV.

## What the engine must do

1. **Optimise for what the guest dirties after the snapshot, not for what it holds.** Pre-touch and
   stabilise before snapshotting; anything that grows afterwards is paid for once per fork.
2. **Do not cap memory to save memory.** `-Xms == -Xmx` is the wrong instinct twice over: it costs more
   and it buys nothing. If a runtime must be tuned, tune it to *touch less after restore*.
3. **Snapshot small guests.** Guest size barely affects per-fork memory, but it linearly affects
   snapshot cost and disk. 2 GiB is 2.7× cheaper to capture than 6 GiB for a 2.5% memory difference.
4. **Treat deduplication as unproven.** 18% is real and measurable, and it did not survive being
   scripted. Anything depending on it needs a liveness check that fails loudly.
5. **Budget ~450 MB per fork** from the third onwards, and expect that to multiply by 2–5× as soon as
   the fork does real work.

## Open question: idleness

Not guest RAM, and not JVM heap size — both were tested and neither moves it. The ~470 MB is
post-restore churn, and an "idle" fork is not idle: fourteen containers whose healthchecks fire every
3–5 s (several of them spawning a JVM or a shell), a Kafka group coordinator heart-beating, journald,
and chrony polling the PHC four times a second. Every one of those writes pages that were clean and
shared with the memory file a moment earlier.

The next lever is not memory sizing. It is how much a fork can be made to **stop doing** while nobody
is asking it for anything: healthchecks paused or stretched after restore, consumer heartbeats slowed,
chrony backed off once the clock has stepped. That also predicts the shape of the win — it should
compound with KSM, because fewer writes means fewer diverged pages for ksmd to fail to merge.
