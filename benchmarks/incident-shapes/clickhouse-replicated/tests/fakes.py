"""A fake ClickHouse pair (or single node) for rehearse.py and writer.py: just enough of the
replication queue's ordering to be the incident's shape, on a fake clock.

What it models, from what the real 25.8 did on the laptop (the README's "checked locally"):
  - DROP INDEX on a replicated table schedules a mutation on every replica and returns at once
    (mutations_sync=0); each replica works through it at its own speed, and not at all while its
    merges are stopped
  - ADD COLUMN on a replicated table queues an ALTER_METADATA on every replica that applies only
    once that replica's earlier mutations are done; the statement waits for the replica it ran on
    (alter_sync=1) or for every replica (alter_sync=2)
  - on a single MergeTree node, DROP INDEX waits for its mutation and ADD COLUMN applies at once
  - an INSERT naming a column the replica does not have fails with code 16
Time only moves when the rehearsal sleeps; a statement that must wait blocks its thread until the
main thread's sleeps have moved the clock far enough.
"""
import json
import re
import threading
import time

from writer import CHError, Writer


class Clock:
    def __init__(self, cluster):
        self.t, self.cluster, self.tickers = 1_000_000.0, cluster, []

    def __call__(self):
        return self.t

    def sleep(self, dt):
        with self.cluster.lock:
            self.t += dt
            self.cluster.advance(dt)
        for tick in list(self.tickers):
            tick()
        time.sleep(0.0005)   # let a blocked statement thread see the new time


class Replica:
    def __init__(self, name, mutation_s):
        self.name, self.mutation_s = name, mutation_s
        self.columns = {"org_id", "event_id", "ts", "name", "environment", "payload", "batch_id"}
        self.indexes = ["idx_name", "idx_payload"]
        self.mutations = []          # [seconds of work left]
        self.meta = []               # [(column, mutations that must finish first)]
        self.stopped = False
        self.inactive_until = None   # clock time before which it applies nothing (a lost Keeper session)
        self.batches = {}
        self.readonly = 0


class Cluster:
    def __init__(self, mutation_s, replicated=True, rows=30_000_000):
        self.lock = threading.RLock()
        self.replicated, self.rows = replicated, rows
        self.r = {n: Replica(n, s) for n, s in mutation_s.items()}
        self.clock = Clock(self)
        self.queries = []
        self.fail_statement = None
        self.alter_sync_gives_up_s = None   # alter_sync=2 raising UNFINISHED after this much clock, as for an inactive replica

    def client(self, name):
        return Client(self, name)

    def advance(self, dt):
        for rep in self.r.values():
            if rep.stopped:
                continue
            left = dt
            while rep.mutations and left > 0:
                use = min(left, rep.mutations[0])
                rep.mutations[0] -= use
                left -= use
                if rep.mutations[0] <= 1e-9:
                    rep.mutations.pop(0)
            self.apply_meta(rep)

    def apply_meta(self, rep):
        if rep.inactive_until is not None and self.clock() < rep.inactive_until:
            return
        while rep.meta and len(rep.mutations) == 0:
            rep.columns.add(rep.meta.pop(0))

    def wait_until(self, cond, real_timeout=10):
        end = time.time() + real_timeout
        while time.time() < end:
            with self.lock:
                if cond():
                    return
            time.sleep(0.0002)
        raise AssertionError("fake: a statement waited too long (the test's clock never got there)")


class Client:
    def __init__(self, cluster, name):
        self.k, self.name = cluster, name

    @property
    def rep(self):
        return self.k.r[self.name]

    def query(self, sql, body=None, timeout=None):
        k, rep = self.k, self.rep
        k.queries.append((self.name, sql))
        s = " ".join(sql.split())
        if k.fail_statement and k.fail_statement in s:
            raise CHError(999, "fake: told to fail")
        with k.lock:
            if s.startswith("INSERT INTO events (") and body is not None:
                cols = [c.strip() for c in s[len("INSERT INTO events ("):s.index(")")].split(",")]
                missing = [c for c in cols if c not in rep.columns]
                if missing:
                    raise CHError(16, f"Code: 16. DB::Exception: No such column {missing[0]} in table default.events")
                for line in body.splitlines():
                    b = json.loads(line)["batch_id"]
                    for other in (k.r.values() if k.replicated else [rep]):
                        other.batches[b] = other.batches.get(b, 0) + 1
                return ""
            m = re.match(r"SELECT count\(\) FROM events WHERE batch_id = (\d+)$", s)
            if m:
                return f"{rep.batches.get(int(m.group(1)), 0)}\n"
            if s.startswith("SYSTEM STOP MERGES"):
                rep.stopped = True
                return ""
            if s.startswith("SYSTEM START MERGES"):
                rep.stopped = False
                return ""
            if s.startswith("SYSTEM SYNC REPLICA"):
                return ""
            if s.startswith("SELECT batch_id, count()"):
                return "".join(f"{b}\t{n}\n" for b, n in sorted(rep.batches.items()))
            if "AS has_column" in s and "alter_metadata_queued" in s:
                return json.dumps({"has_column": int("region" in rep.columns), "mutations_open": len(rep.mutations),
                                   "parts_to_do": 10 * len(rep.mutations), "queue": len(rep.mutations) + len(rep.meta),
                                   "alter_metadata_queued": len(rep.meta), "parts": 12}) + "\n"
            if "AS skip_indexes" in s:
                return json.dumps({"rows": str(k.rows), "parts": "12", "bytes": str(3 << 30), "skip_indexes": rep.indexes}) + "\n"
            if "AS readonly" in s:
                return json.dumps({"readonly": rep.readonly, "queue": len(rep.mutations) + len(rep.meta),
                                   "mutations_open": len(rep.mutations), "has_column": int("region" in rep.columns)}) + "\n"
            if s.startswith("SELECT count() FROM events WHERE batch_id < 2000000000"):
                return f"{k.rows}\n"
            if s.startswith("INSERT INTO events (org_id, event_id, ts, name, environment, payload, batch_id) VALUES"):
                b = int(re.search(r", (\d+)\)$", s).group(1))
                for other in (k.r.values() if k.replicated else [rep]):
                    other.batches[b] = 1
                return ""
            if s.startswith("ALTER TABLE events DROP INDEX"):
                targets = k.r.values() if k.replicated else [rep]
                for t in targets:
                    t.indexes = [i for i in t.indexes if i != "idx_payload"]
                    t.mutations.append(t.mutation_s)
                mine = len(rep.mutations)
            elif s.startswith("ALTER TABLE events ADD COLUMN region"):
                targets = k.r.values() if k.replicated else [rep]
                if not k.replicated:
                    rep.columns.add("region")
                    return ""
                for t in targets:
                    t.meta.append("region")
                    k.apply_meta(t)
                everyone = "alter_sync = 2" in s
            else:
                raise AssertionError(f"fake: no answer for {s[:120]!r}")
        # the statements that wait, outside the lock so the clock can move
        if s.startswith("ALTER TABLE events DROP INDEX"):
            if not k.replicated:
                k.wait_until(lambda: len(rep.mutations) < mine)
            return ""
        if everyone and k.alter_sync_gives_up_s is not None:
            t0 = k.clock()
            k.wait_until(lambda: all("region" in t.columns for t in k.r.values()) or k.clock() - t0 >= k.alter_sync_gives_up_s)
            if not all("region" in t.columns for t in k.r.values()):
                raise CHError(341, "Code: 341. DB::Exception: Timeout exceeded while waiting for replicas. (UNFINISHED)")
        elif everyone:
            k.wait_until(lambda: all("region" in t.columns for t in k.r.values()))
        else:
            k.wait_until(lambda: "region" in rep.columns)
        return ""


class Handle:
    """A writer 'process' on the fake clock: sends the batches its schedule has made due, each tick."""

    def __init__(self, cluster, version, first, log, names, rate=4, rows=10, retries=3):
        self.k, self.out = cluster, open(log, "a")
        self.w = Writer(version, {n: cluster.client(n) for n in names}, first, rows, retries, (0.5, 1, 2),
                        clock=cluster.clock, sleep=lambda s: None, out=self.out)
        self.period, self.due, self.live = 1 / rate, cluster.clock(), True
        cluster.clock.tickers.append(self.tick)

    def tick(self):
        while self.live and self.k.clock() >= self.due:
            self.w.send()
            self.due += self.period

    def stop(self):
        self.live = False
        self.out.close()


def spawner(cluster, rows=10, retries=3):
    return lambda version, first, log, names: Handle(cluster, version, first, log, names, rows=rows, retries=retries)
