# Migration Check, connection exhaustion — `mastodon`

Can the Migration Check show not just the lock, but connections hitting the cap and requests failing, and whether the app comes back on its own? Each scenario below is one fork of the CI baseline `ci-mastodon`, with Postgres capped and the app's pool sized past the cap, under a replayed workload. Knobs: `migration_check.exhaustion` in `ops/ci/mastodon.yml`; harness: `ops/migration-check-exhaustion.sh`. Nothing here describes or predicts any real incident; it is what these statements did to this database under this load.

**Workload, all scenarios.** Postgres `max_connections` = **100**; the app connects as a superuser, so the 3 reserved slots are not a margin. The app's pool, unless a scenario says otherwise: 3 Puma workers × 30 threads, 30 connections each = 90, plus Sidekiq and streaming. Replay: **30 requests/s open-loop** across the adapter's probes (public timeline, an account's statuses, a home timeline, and a status post into the migrated table), **at most 95 in flight** on the client side, tokens spread over 40 accounts so the app's own per-token and per-user throttles stay out of the way; 30 s warm-up, then 60 s before, the trouble, 60 s after; 30 s request timeout. Connections are sampled every 0.2 s from one psql session opened before the pile-up (its own connection is included in the counts).

## constraint-drop

`ALTER TABLE statuses DROP CONSTRAINT fk_c7fa917661`, no long reader. App pool for this run: 3 Puma workers × 30 connections = **90** against the cap of 100. Run `20260924T032036Z-constraint-drop`.

| | |
|---|---|
| the statement | returned after **0.3 s**; queued **0.0 s** for its lock; held: granted and released between two 0.2 s samples |
| connections | **peak 28 of 100** (active 3); **0.0 s at the cap**; 28 before the trouble; lock waiters at peak 0 |
| refused by Postgres | **0** `too many clients already`; the app logged 0 pool timeouts and 0 `too many clients` |
| requests during the trouble (0.3 s) | **0 of 8 failed** (none); p99 40 ms; client-side wait p99 0 ms |
| requests before (60 s) | 0 of 1800 failed; p50 27 ms, p99 100 ms |
| requests after (60 s) | 0 of 1800 failed; p50 30 ms, p99 107 ms |
| recovered without a restart? | **yes** — recovered 0 s after the load stopped (30 in a row) (0 of 30 probe requests failed while watching; connections 28–28 of 100 with the load stopped); afterwards a status posted and read back: yes; containers restarted or recreated: none |

<details><summary>Connections vs cap, every 5 s</summary>

t = seconds since the sampler started (the trouble begins at about t = 20). `#` = 5 connections of the 100-connection cap. `failed/sent` counts the replay; once it stops (0/0), the recovery watch's 1-per-second probes are counted in the recovery row above.

```
   t  conns  lockwait  failed/sent  
   0     28         0       0/150   ######
   5     28         0       0/150   ######
  10     28         0       0/150   ######
  15     28         0       0/150   ######
  20     28         0       0/150   ######
  25     28         0       0/150   ######
  30     28         0       0/150   ######
  35     28         0       0/150   ######
  40     28         0       0/150   ######
  45     28         0       0/150   ######
  50     28         0       0/150   ######
  55     28         0       0/150   ######
  60     28         0       0/150   ######
  65     28         0       0/150   ######
  70     28         0       0/150   ######
  75     28         0       0/150   ######
  80     28         0       0/16    ######
  85     28         0       0/0     ######
  90     28         0       0/0     ######
  95     28         0       0/0     ######
 100     28         0       0/0     ######
 105     28         0       0/0     ######
 110     28         0       0/0     ######
 115     28         0       0/0     ######
 120     28         0       0/0     ######
 125     28         0       0/0     ######
 130     28         0       0/0     ######
 135     28         0       0/0     ######
```

</details>

## column-add-behind-reader

`ALTER TABLE statuses ADD COLUMN mc_rehearsal_note text`, behind a long reader: a transaction holding `AccessShareLock` on the table for 90 s, started 5 s before the migration asked for its lock. App pool for this run: 3 Puma workers × 30 connections = **90** against the cap of 100. Run `20260924T031424Z-column-add-behind-reader`.

| | |
|---|---|
| the statement | returned after **85.2 s**; queued **84.7 s** for its lock; held: granted and released between two 0.2 s samples |
| connections | **peak 98 of 100** (active 93); **80.2 s at the cap**; 46 before the trouble; lock waiters at peak 91 |
| refused by Postgres | **0** `too many clients already`; the app logged 0 pool timeouts and 0 `too many clients` |
| requests during the trouble (90.4 s) | **190 of 2711 failed** (190× ERR:TimeoutError); p99 79616 ms; client-side wait p99 76345 ms |
| requests before (60 s) | 0 of 1800 failed; p50 28 ms, p99 98 ms |
| requests after (60 s) | 0 of 1800 failed; p50 12730 ms, p99 30943 ms |
| recovered without a restart? | **yes** — recovered 0 s after the load stopped (30 in a row) (0 of 30 probe requests failed while watching; connections 96–96 of 100 with the load stopped); afterwards a status posted and read back: yes; containers restarted or recreated: none |

<details><summary>Connections vs cap, every 5 s</summary>

t = seconds since the sampler started (the trouble begins at about t = 20). `#` = 5 connections of the 100-connection cap. `failed/sent` counts the replay; once it stops (0/0), the recovery watch's 1-per-second probes are counted in the recovery row above.

```
   t  conns  lockwait  failed/sent  
   0     46         0       0/150   #########
   5     46         0       0/150   #########
  10     46         0       0/150   #########
  15     46         0       0/150   #########
  20     47         0       0/150   #########
  25     98        91     129/150   #################### <- cap
  30     98        91      61/150   #################### <- cap
  35     98        91       0/150   #################### <- cap
  40     98        91       0/150   #################### <- cap
  45     98        91       0/150   #################### <- cap
  50     98        91       0/150   #################### <- cap
  55     98        91       0/150   #################### <- cap
  60     98        91       0/150   #################### <- cap
  65     98        91       0/150   #################### <- cap
  70     98        91       0/150   #################### <- cap
  75     98        91       0/150   #################### <- cap
  80     98        91       0/150   #################### <- cap
  85     98        91       0/150   #################### <- cap
  90     98        91       0/150   #################### <- cap
  95     98        91       0/150   #################### <- cap
 100     98        91       0/150   #################### <- cap
 105     98        91       0/150   #################### <- cap
 110     98        91       0/150   #################### <- cap
 115     96         0       0/150   ###################
 120     96         0       0/150   ###################
 125     96         0       0/150   ###################
 130     96         0       0/150   ###################
 135     96         0       0/150   ###################
 140     96         0       0/150   ###################
 145     96         0       0/150   ###################
 150     96         0       0/150   ###################
 155     96         0       0/150   ###################
 160     96         0       0/150   ###################
 165     96         0       0/150   ###################
 170     96         0       0/18    ###################
 175     96         0       0/0     ###################
 180     96         0       0/0     ###################
 185     96         0       0/0     ###################
 190     96         0       0/0     ###################
 195     96         0       0/0     ###################
 200     96         0       0/0     ###################
 205     96         0       0/0     ###################
 210     96         0       0/0     ###################
 215     96         0       0/0     ###################
 220     96         0       0/0     ###################
 225     96         0       0/0     ###################
```

</details>

## column-add-behind-reader-pool-past-cap

`ALTER TABLE statuses ADD COLUMN mc_rehearsal_note text`, behind a long reader: a transaction holding `AccessShareLock` on the table for 90 s, started 5 s before the migration asked for its lock. App pool for this run: 4 Puma workers × 30 connections = **120** against the cap of 100. Run `20260924T030416Z-column-add-behind-reader-pool-past-cap`.

| | |
|---|---|
| the statement | returned after **85.1 s**; queued **84.9 s** for its lock; held: granted and released between two 0.2 s samples |
| connections | **peak 100 of 100** (active 95); **387.4 s at the cap**; 39 before the trouble; lock waiters at peak 93 |
| refused by Postgres | **6210** `too many clients already`; the app logged 0 pool timeouts and 12392 `too many clients` |
| requests during the trouble (90.3 s) | **2545 of 2710 failed** (2453× 500, 92× ERR:TimeoutError); p99 30030 ms; client-side wait p99 1629 ms |
| requests before (60 s) | 0 of 1800 failed; p50 28 ms, p99 105 ms |
| requests after (60 s) | 475 of 1800 failed; p50 32 ms, p99 630 ms |
| recovered without a restart? | **yes** — recovered 223 s after the load stopped (30 in a row) (162 of 253 probe requests failed while watching; connections 25–100 of 100 with the load stopped); afterwards a status posted and read back: yes; containers restarted or recreated: none |

<details><summary>Connections vs cap, every 5 s</summary>

t = seconds since the sampler started (the trouble begins at about t = 20). `#` = 5 connections of the 100-connection cap. `failed/sent` counts the replay; once it stops (0/0), the recovery watch's 1-per-second probes are counted in the recovery row above.

```
   t  conns  lockwait  failed/sent  
   0     39         0       0/150   ########
   5     39         0       0/150   ########
  10     39         0       0/150   ########
  15     39         0       0/150   ########
  20     40         0       0/150   ########
  25    100        93     124/150   #################### <- cap
  30    100        93     150/150   #################### <- cap
  35    100        93     150/150   #################### <- cap
  40    100        93     150/150   #################### <- cap
  45    100        93     150/150   #################### <- cap
  50    100        93     150/150   #################### <- cap
  55    100        93     150/150   #################### <- cap
  60    100        93     150/150   #################### <- cap
  65    100        93     150/150   #################### <- cap
  70    100        93     150/150   #################### <- cap
  75    100        93     150/150   #################### <- cap
  80    100        93     150/150   #################### <- cap
  85    100        93     150/150   #################### <- cap
  90    100        93     150/150   #################### <- cap
  95    100        93     150/150   #################### <- cap
 100    100        93     150/150   #################### <- cap
 105    100        93     150/150   #################### <- cap
 110    100        93      52/150   #################### <- cap
 115    100         0      43/150   #################### <- cap
 120    100         0      48/150   #################### <- cap
 125    100         0      51/150   #################### <- cap
 130    100         0      46/150   #################### <- cap
 135    100         0      43/150   #################### <- cap
 140    100         0      43/150   #################### <- cap
 145    100         0      45/150   #################### <- cap
 150    100         0      38/150   #################### <- cap
 155    100         0      33/150   #################### <- cap
 160    100         0      29/150   #################### <- cap
 165    100         0      18/150   #################### <- cap
 170    100         0       7/22    #################### <- cap
 175    100         0       0/0     #################### <- cap
 180    100         0       0/0     #################### <- cap
 185    100         0       0/0     #################### <- cap
 190    100         0       0/0     #################### <- cap
 195    100         0       0/0     #################### <- cap
 200    100         0       0/0     #################### <- cap
 205    100         0       0/0     #################### <- cap
 210    100         0       0/0     #################### <- cap
 215    100         0       0/0     #################### <- cap
 220    100         0       0/0     #################### <- cap
 225    100         0       0/0     #################### <- cap
 230    100         0       0/0     #################### <- cap
 235    100         0       0/0     #################### <- cap
 240    100         0       0/0     #################### <- cap
 245    100         0       0/0     #################### <- cap
 250    100         0       0/0     #################### <- cap
 255    100         0       0/0     #################### <- cap
 260    100         0       0/0     #################### <- cap
 265    100         0       0/0     #################### <- cap
 270    100         0       0/0     #################### <- cap
 275    100         0       0/0     #################### <- cap
 280    100         0       0/0     #################### <- cap
 285    100         0       0/0     #################### <- cap
 290    100         0       0/0     #################### <- cap
 295    100         0       0/0     #################### <- cap
 300    100         0       0/0     #################### <- cap
 305    100         0       0/0     #################### <- cap
 310    100         0       0/0     #################### <- cap
 315    100         0       0/0     #################### <- cap
 320    100         0       0/0     #################### <- cap
 325    100         0       0/0     #################### <- cap
 330    100         0       0/0     #################### <- cap
 335    100         0       0/0     #################### <- cap
 340    100         0       0/0     #################### <- cap
 345    100         0       0/0     #################### <- cap
 350    100         0       0/0     #################### <- cap
 355    100         0       0/0     #################### <- cap
 360    100         0       0/0     #################### <- cap
 365    100         0       0/0     #################### <- cap
 370    100         0       0/0     #################### <- cap
 375    100         0       0/0     #################### <- cap
 380    100         0       0/0     #################### <- cap
 385    100         0       0/0     #################### <- cap
 390    100         0       0/0     #################### <- cap
 395    100         0       0/0     #################### <- cap
 400    100         0       0/0     #################### <- cap
 405    100         0       0/0     #################### <- cap
 410    100         0       0/0     #################### <- cap
 415    100         0       0/0     #################### <- cap
 420    100         0       0/0     #################### <- cap
 425     77         0       0/0     ###############
 430     27         0       0/0     #####
 435     27         0       0/0     #####
 440     28         0       0/0     ######
 445     28         0       0/0     ######
 450     27         0       0/0     #####
```

</details>

<sub>Paraglobe Migration Check, exhaustion rehearsal · every number above is from the named run on this box · the fork is destroyed after each run; the baseline is untouched</sub>
