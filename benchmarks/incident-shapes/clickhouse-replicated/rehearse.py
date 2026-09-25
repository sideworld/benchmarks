#!/usr/bin/env python3
"""PAR-73's rehearsal runner: the Migration Check's phases for a replicated ClickHouse change.

    rehearse.py generate --world replicated|single          # schema + the history, then its facts
    rehearse.py run --run naive-held --out <dir>             # one entry of scenario.yml's runs
    rehearse.py verify --world replicated --rows <n>         # a (restored) pair is healthy: quiesce-check.sh
    rehearse.py report <dir>...                              # the runs' results as markdown

`run`, on a world already generated (run.sh brings each up fresh):
  1  facts: rows, active parts and skip indexes on every replica
  2  the old writer starts (cell old-app-new-schema); warm-up, then the before window
  3  lag=held: SYSTEM STOP MERGES events on the lagging replica, started again hold_s later
  4  the form's statements, each timed, on run_on -- in a thread, so the sampler keeps going and a
     held replica is released on time even while a statement blocks on it
  5  the deploy: the new writer starts (cell new-app-new-schema) when the runner returns (naive), or
     once every replica shows the column (safe), then the safe form's after_deploy statements
  6  settling: until every replica has the column and no open mutation on the table, or settle_max
  7  the after window; the writers stop
  8  the round trip: SYSTEM SYNC REPLICA on each replica, then every batch any writer attempted is
     looked for on every replica. A batch that is on none of them, or not on all, never landed.
Every sample_s the sampler reads, on every replica: the column there or not, open mutations and
their parts to do, the replication queue and its ALTER_METADATA entries, active parts.

Verdict, per matrix cell: red when a batch the cell's writer attempted never landed on every
replica (dropped after its retries, or acked and then missing). Also reported, not judged: how long
the runner took to report success, and when the column was visible on every replica -- the gap
between the two is PAR-73's "the migration succeeds quickly while the replica is still behind".

Clients, the writers, the clock and sleep are injected; tests/ runs all of it against a fake
cluster. Measures; claims nothing about Trigger.dev's system beyond the shape (see the README).
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from writer import CHError, HTTP  # noqa: E402

PORT_ENV = {"ch1": "CH1_PORT", "ch2": "CH2_PORT", "ch": "CH_PORT"}
FIRST_BATCH = {"old": 1, "new": 1_000_000_000}   # batch ids never collide across the two writers


def load_scenario(path=os.path.join(HERE, "scenario.yml")):
    import yaml
    with open(path) as f:
        s = yaml.safe_load(f)
    check_scenario(s)
    return s


def check_scenario(s):
    """The keys rehearse.py reads, so a typo fails before a 30-million-row world is built."""
    for k in ("label", "table", "worlds", "rows", "chunk", "now", "writer", "windows", "lag", "naive", "safe",
              "column", "matrix", "runs"):
        if k not in s:
            raise SystemExit(f"scenario: missing {k!r}")
    for form in ("naive", "safe"):
        f = s[form]
        if not f.get("statements"):
            raise SystemExit(f"scenario: {form} has no statements")
        if f.get("deploy") not in ("on_return", "when_column_on_every_replica"):
            raise SystemExit(f"scenario: {form}.deploy must be on_return or when_column_on_every_replica")
    names = set()
    for r in s["runs"]:
        if r["name"] in names:
            raise SystemExit(f"scenario: run {r['name']!r} twice")
        names.add(r["name"])
        if r["form"] not in ("naive", "safe") or r["world"] not in s["worlds"] or r["lag"] not in ("pool", "held"):
            raise SystemExit(f"scenario: run {r['name']!r} has an unknown form, world or lag")
        if s[r["form"]]["run_on"] not in s["worlds"][r["world"]]["replicas"] and r["world"] == "replicated":
            raise SystemExit(f"scenario: run {r['name']!r}: run_on is not a replica of {r['world']}")
    for c in s["matrix"]:
        if c["writer"] not in FIRST_BATCH or c["from"] not in ("start", "deploy"):
            raise SystemExit(f"scenario: matrix cell {c.get('cell')!r} is malformed")


def run_entry(s, name):
    for r in s["runs"]:
        if r["name"] == name:
            return r
    raise SystemExit(f"scenario: no run {name!r} (runs: {', '.join(r['name'] for r in s['runs'])})")


def clients_for(s, world):
    return {n: HTTP(f"http://127.0.0.1:{os.environ.get(PORT_ENV.get(n, ''), p)}")
            for n, p in s["worlds"][world]["replicas"].items()}


def run_on(s, run, clients):
    """The replica the statements go to: the form's run_on, or the single node."""
    want = s[run["form"]]["run_on"]
    return want if want in clients else next(iter(clients))


SAMPLE = """SELECT
  (SELECT count() FROM system.columns WHERE database = currentDatabase() AND table = '{t}' AND name = '{c}') AS has_column,
  (SELECT count() FROM system.mutations WHERE database = currentDatabase() AND table = '{t}' AND NOT is_done) AS mutations_open,
  (SELECT sum(parts_to_do) FROM system.mutations WHERE database = currentDatabase() AND table = '{t}' AND NOT is_done) AS parts_to_do,
  (SELECT count() FROM system.replication_queue WHERE database = currentDatabase() AND table = '{t}') AS queue,
  (SELECT countIf(type = 'ALTER_METADATA') FROM system.replication_queue WHERE database = currentDatabase() AND table = '{t}') AS alter_metadata_queued,
  (SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = '{t}' AND active) AS parts
FORMAT JSONEachRow"""


class Rehearsal:
    def __init__(self, scenario, run, clients, spawn, out_dir, clock=time.time, sleep=time.sleep, log=print):
        self.s, self.run, self.c = scenario, run, clients
        self.form = scenario[run["form"]]
        self.world = scenario["worlds"][run["world"]]
        self.spawn, self.dir, self.clock, self.sleep, self.log = spawn, out_dir, clock, sleep, log
        self.w = scenario["windows"]
        self.table, self.column = scenario["table"], scenario["column"]
        self.lagging = self.world["lagging"] if self.world["lagging"] in clients else next(iter(clients))
        self.run_on = run_on(scenario, run, clients)
        self.timeline, self.writers, self.events = [], {}, []
        self.t0 = None
        self.hold_until = None

    # ------------------------------------------------------------------ helpers
    def now(self):
        return round(self.clock() - self.t0, 3)

    def event(self, what, **kw):
        self.events.append({"t": self.now(), "event": what, **kw})
        self.log(f"  t={self.now():7.1f}s  {what}" + (f"  {kw}" if kw else ""))

    def sample(self):
        row = {"t": self.now()}
        for name, cl in self.c.items():
            try:
                row[name] = json.loads(cl.query(SAMPLE.format(t=self.table, c=self.column), timeout=10).strip() or "{}")
                row[name] = {k: int(v or 0) for k, v in row[name].items()}
            except (CHError, ValueError) as e:
                row[name] = {"error": str(e)[:160]}
        self.timeline.append(row)
        self.release_if_due()
        return row

    def release_if_due(self, force=False):
        if self.hold_until is not None and (force or self.clock() >= self.hold_until):
            self.hold_until = None
            try:
                self.c[self.lagging].query(f"SYSTEM START MERGES {self.table}")
                self.event("hold released", replica=self.lagging)
            except CHError as e:
                self.event("hold release FAILED", replica=self.lagging, error=str(e)[:160])

    def wait(self, seconds=None, until=None, thread=None):
        """Sample every sample_s for `seconds`, or until `until(last sample)` or `thread` is done.
        Returns whether the condition was met (always True for a plain wait)."""
        end = None if seconds is None else self.clock() + seconds
        while True:
            last = self.sample()
            if until is not None and until(last):
                return True
            if thread is not None and not thread.is_alive():
                return True
            if end is not None and self.clock() >= end:
                return until is None and thread is None
            self.sleep(self.w["sample"])

    def column_everywhere(self, row):
        return all(isinstance(row.get(n), dict) and row[n].get("has_column") == 1 for n in self.c)

    def settled(self, row):
        return self.column_everywhere(row) and all(row[n].get("mutations_open") == 0 for n in self.c)

    def start_writer(self, cell):
        c = next(x for x in self.s["matrix"] if x["cell"] == cell)
        path = os.path.join(self.dir, f"writer-{c['cell']}.jsonl")
        self.writers[cell] = {"handle": self.spawn(c["writer"], FIRST_BATCH[c["writer"]], path, list(self.c)),
                              "log": path, "version": c["writer"], "started": self.now(),
                              "rows_per_batch": self.s["writer"]["rows_per_batch"]}
        self.event("writer started", cell=cell, version=c["writer"])

    def statements(self, key):
        """Run a form's statement list on run_on in a thread, sampling while it runs."""
        done = []

        def go():
            for st in self.form.get(key) or []:
                t = self.clock()
                try:
                    self.c[self.run_on].query(st["sql"], timeout=self.w["settle_max"] + 600)
                    done.append({"sql": st["sql"], "seconds": round(self.clock() - t, 3), "ok": True})
                except CHError as e:
                    done.append({"sql": st["sql"], "seconds": round(self.clock() - t, 3), "ok": False,
                                 "code": e.code, "error": str(e)[:300]})
                    break

        th = threading.Thread(target=go, daemon=True)
        th.start()
        self.wait(thread=th)
        th.join()
        return done

    # ------------------------------------------------------------------ the run
    def go(self):
        self.t0 = self.clock()
        r = {"run": self.run["name"], "form": self.run["form"], "world": self.run["world"], "lag": self.run["lag"],
             "label": self.s["label"], "description": self.form["description"], "run_on": self.run_on,
             "lagging": self.lagging, "replicas": list(self.c), "windows": self.w, "writer": self.s["writer"],
             "hold_s": self.s["lag"]["hold_s"] if self.run["lag"] == "held" else None,
             "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.t0))}
        r["facts"] = facts(self.c, self.table)
        try:
            for c in self.s["matrix"]:
                if c["from"] == "start":
                    self.start_writer(c["cell"])
            self.wait(self.w["warm"] + self.w["before"])
            if self.run["lag"] == "held":
                self.c[self.lagging].query(f"SYSTEM STOP MERGES {self.table}")
                self.hold_until = self.clock() + self.s["lag"]["hold_s"]
                self.event("hold: merges and mutations stopped", replica=self.lagging, seconds=self.s["lag"]["hold_s"])
            t_mig = self.now()
            self.event("migration started", on=self.run_on)
            r["statements"] = self.statements("statements")
            r["migration_started_s"] = t_mig
            r["runner_returned_s"] = self.now()
            r["runner_ok"] = all(st["ok"] for st in r["statements"])
            self.event("runner returned", ok=r["runner_ok"],
                       seconds=round(r["runner_returned_s"] - t_mig, 3))
            r["gate_opened"] = True
            if self.form["deploy"] == "when_column_on_every_replica":
                r["gate_opened"] = self.wait(self.w["settle_max"], until=self.column_everywhere)
                self.event("deploy gate", column_on_every_replica=r["gate_opened"])
            r["deployed_s"] = self.now() if r["gate_opened"] else None
            for c in self.s["matrix"]:
                if c["from"] == "deploy" and r["gate_opened"]:     # a gate that never opens deploys nothing
                    self.start_writer(c["cell"])
            r["after_deploy"] = self.statements("after_deploy") if self.form.get("after_deploy") else []
            r["settled"] = self.wait(self.w["settle_max"], until=self.settled)
            r["settled_s"] = self.now()
            self.event("settled" if r["settled"] else "NOT settled within settle_max")
            self.wait(self.w["after"])
        finally:
            for name, wr in self.writers.items():
                wr["handle"].stop()
                wr["stopped"] = self.now()
            self.release_if_due(force=True)
        self.event("writers stopped")
        r["round_trip"] = round_trip(self.c, self.table, self.run["world"] == "replicated")
        r["events"], r["timeline"] = self.events, self.timeline
        r["cells"] = {cell: cell_result(read_log(wr["log"]), r["round_trip"], list(self.c), wr, self.t0)
                      for cell, wr in self.writers.items()}
        r["visibility"] = visibility(self.timeline, list(self.c), t_mig, r["runner_returned_s"])
        r["verdict"] = verdict(r)
        return r


# ---------------------------------------------------------------------- pieces, tested one by one
def facts(clients, table):
    out = {}
    for name, cl in clients.items():
        try:
            out[name] = json.loads(cl.query(
                f"SELECT (SELECT count() FROM {table}) AS rows, "
                f"(SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = '{table}' AND active) AS parts, "
                f"(SELECT sum(bytes_on_disk) FROM system.parts WHERE database = currentDatabase() AND table = '{table}' AND active) AS bytes, "
                f"(SELECT groupArray(name) FROM system.data_skipping_indices WHERE database = currentDatabase() AND table = '{table}') AS skip_indexes "
                "FORMAT JSONEachRow", timeout=60).strip())
            out[name]["rows"], out[name]["parts"], out[name]["bytes"] = (int(out[name][k]) for k in ("rows", "parts", "bytes"))
        except (CHError, ValueError) as e:
            out[name] = {"error": str(e)[:160]}
    return out


def round_trip(clients, table, replicated, sync_timeout=600):
    """Every replica's batch_id -> row count, after it has caught up with the replication log."""
    out = {}
    for name, cl in clients.items():
        rec = {}
        if replicated:
            t = time.time()
            try:
                cl.query(f"SYSTEM SYNC REPLICA {table}", timeout=sync_timeout)
                rec["synced"] = True
            except CHError as e:
                rec["synced"], rec["sync_error"] = False, str(e)[:160]
            rec["sync_seconds"] = round(time.time() - t, 1)
        try:
            text = cl.query(f"SELECT batch_id, count() FROM {table} WHERE batch_id > 0 GROUP BY batch_id FORMAT TSV",
                            timeout=120)
            rec["batches"] = {int(b): int(n) for b, n in (ln.split("\t") for ln in text.splitlines() if ln.strip())}
        except CHError as e:
            rec["batches"], rec["error"] = None, str(e)[:160]
        out[name] = rec
    return out


def read_log(path):
    out = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
    return out


def cell_result(records, rt, replicas, wr, t0):
    """A matrix cell's writer, its log against what every replica holds. A batch landed when every
    replica has all its rows; t0 turns the log's clock times into seconds since the run began."""
    n = wr.get("rows_per_batch")
    attempted = {x["batch"]: x for x in records}
    on = {name: (rt[name].get("batches") or {}) for name in replicas}
    unknown = [name for name in replicas if rt[name].get("batches") is None]

    def complete(b, name):
        got = on[name].get(b, 0)
        return got > 0 and (n is None or got == n)

    everywhere = [b for b in attempted if all(complete(b, name) for name in replicas)]
    never = sorted(b for b in attempted if b not in set(everywhere))
    codes = {}
    for x in records:
        for e in x["errors"]:
            codes[str(e["code"])] = codes.get(str(e["code"]), 0) + 1
    return {
        "version": wr["version"], "started_s": wr.get("started"), "stopped_s": wr.get("stopped"),
        "attempted": len(attempted),
        "acked": sum(1 for x in records if x["outcome"] == "acked"),
        "dropped": sum(1 for x in records if x["outcome"] == "dropped"),
        "retried": sum(1 for x in records if x["attempts"] > 1 and x["outcome"] == "acked"),
        "failed_attempts_by_code": codes,
        "read_back_failed": sum(1 for x in records if x["outcome"] == "acked" and x["read_back"] is False),
        "landed_everywhere": len(everywhere),
        "never_landed": len(never),
        "acked_but_missing": sum(1 for b in never if attempted[b]["outcome"] == "acked"),
        "never_landed_by_replica": {name: sum(1 for b in never if attempted[b]["replica"] == name) for name in replicas},
        "first_never_landed_s": round(min(attempted[b]["t"] for b in never) - t0, 1) if never else None,
        "unreadable_replicas": unknown,
        "never_landed_sample": never[:10],
    }


def visibility(timeline, replicas, t_mig, t_ret):
    """When each replica first showed the column (and kept it), and when its mutations were all done
    -- counted from the runner's return, since before the statements ran there was nothing open."""
    out = {"column_visible_s": {}, "mutations_done_s": {}}
    for name in replicas:
        vis = done = None
        for row in timeline:
            x = row.get(name) or {}
            if row["t"] < t_mig or "error" in x:
                continue
            if x.get("has_column") == 1:
                vis = row["t"] if vis is None else vis
            else:
                vis = None
            if row["t"] < t_ret:
                continue
            if x.get("mutations_open") == 0:
                done = row["t"] if done is None else done
            else:
                done = None
        out["column_visible_s"][name] = None if vis is None else round(vis - t_mig, 3)
        out["mutations_done_s"][name] = None if done is None else round(done - t_mig, 3)
    vs = list(out["column_visible_s"].values())
    out["everywhere_s"] = None if (not vs or None in vs) else max(vs)
    out["runner_returned_s"] = round(t_ret - t_mig, 3)
    out["gap_s"] = None if out["everywhere_s"] is None else round(out["everywhere_s"] - out["runner_returned_s"], 3)
    return out


def verdict(r):
    findings, red = [], False
    for cell, c in r["cells"].items():
        if c["unreadable_replicas"]:
            findings.append(f"{cell}: could not read batches back from {', '.join(c['unreadable_replicas'])}")
            red = True
        if c["never_landed"]:
            red = True
            where = ", ".join(f"{n} {k}" for n, k in c["never_landed_by_replica"].items() if k)
            findings.append(f"{cell}: {c['never_landed']} of {c['attempted']} batches never landed on every replica "
                            f"({c['dropped']} dropped after {r['writer']['retries']} retries, {c['acked_but_missing']} acked "
                            f"and missing; sent to {where})")
    v = r["visibility"]
    if v["everywhere_s"] is None:
        findings.append("the column never became visible on every replica within the run")
    elif v["gap_s"] is not None and v["gap_s"] > 0:
        findings.append(f"the runner returned after {v['runner_returned_s']} s; the column was on every replica "
                        f"{v['gap_s']} s later ({v['everywhere_s']} s after the migration started)")
    if not r.get("runner_ok", True):
        findings.append("a statement failed: " + "; ".join(st.get("error", "")[:120] for st in r["statements"] if not st["ok"]))
    if not r.get("gate_opened", True):
        findings.append("the deploy gate never opened within settle_max: the new writer was not deployed")
    if not r.get("settled", True):
        findings.append("did not settle within settle_max")
    return {"red": red, "findings": findings}


# ---------------------------------------------------------------------- verify (quiesce-check.sh)
def verify(clients, table, column, rows, drain_s=300, clock=time.time, sleep=time.sleep):
    """Is a (restored) pair healthy: writable, caught up, the same on both replicas, and does a
    round trip through each replica land on the other?"""
    out, ok = {}, True
    end = clock() + drain_s
    for name, cl in clients.items():
        rec = {}
        while True:
            try:
                x = json.loads(cl.query(
                    f"SELECT (SELECT any(is_readonly) FROM system.replicas WHERE table = '{table}') AS readonly, "
                    f"(SELECT count() FROM system.replication_queue WHERE table = '{table}') AS queue, "
                    f"(SELECT count() FROM system.mutations WHERE table = '{table}' AND NOT is_done) AS mutations_open, "
                    f"(SELECT count() FROM system.columns WHERE table = '{table}' AND name = '{column}') AS has_column "
                    "FORMAT JSONEachRow", timeout=10).strip())
                x = {k: int(v) for k, v in x.items()}
            except (CHError, ValueError) as e:
                x = {"error": str(e)[:160]}
            if "error" not in x and x["readonly"] == 0 and x["queue"] == 0 and x["mutations_open"] == 0:
                break
            if clock() >= end:
                break
            sleep(1)
        rec.update(x)
        out[name] = rec
    names = list(clients)
    for i, name in enumerate(names):
        other = names[(i + 1) % len(names)]
        batch = 2_000_000_000 + i
        try:
            clients[name].query(f"INSERT INTO {table} (org_id, event_id, ts, name, environment, payload, batch_id) "
                                f"VALUES (1, {batch}, now(), 'verify', 'production', 'verify', {batch})")
            if len(names) > 1:
                clients[other].query(f"SYSTEM SYNC REPLICA {table}", timeout=120)
            got = int(clients[other].query(f"SELECT count() FROM {table} WHERE batch_id = {batch}").strip())
            out[name]["round_trip"] = got == 1
        except (CHError, ValueError) as e:
            out[name]["round_trip"], out[name]["round_trip_error"] = False, str(e)[:160]
        try:
            out[name]["rows"] = int(clients[name].query(f"SELECT count() FROM {table} WHERE batch_id < 2000000000").strip())
        except (CHError, ValueError):
            out[name]["rows"] = None
    for name, rec in out.items():
        good = ("error" not in rec and rec.get("readonly") == 0 and rec.get("queue") == 0 and rec.get("mutations_open") == 0
                and rec.get("round_trip") and (rows is None or rec.get("rows") == rows))
        rec["ok"] = bool(good)
        ok = ok and rec["ok"]
    cols = {rec.get("has_column") for rec in out.values()}
    return {"ok": ok and len(cols) == 1, "replicas": out, "column_agrees": len(cols) == 1, "expected_rows": rows}


# ---------------------------------------------------------------------- report
def fmt_s(x):
    return "—" if x is None else f"{x:.1f} s"


def report(results):
    lines = ["| run | world | lag | runner reported | column on every replica | new writer: dropped / never landed | old writer: never landed | verdict |",
             "|---|---|---|---|---|---|---|---|"]
    for r in results:
        v, cells = r["visibility"], r["cells"]
        new, old = cells.get("new-app-new-schema", {}), cells.get("old-app-new-schema", {})
        ok = "ok" if r.get("runner_ok") else "FAILED"
        lines.append(f"| {r['run']} | {r['world']} | {r['lag']}{' ' + str(r['hold_s']) + ' s' if r['hold_s'] else ''} "
                     f"| {ok} after {fmt_s(v['runner_returned_s'])} | {fmt_s(v['everywhere_s'])} "
                     f"| {new.get('dropped', '—')} / {new.get('never_landed', '—')} of {new.get('attempted', '—')} "
                     f"| {old.get('never_landed', '—')} of {old.get('attempted', '—')} | {'🔴 red' if r['verdict']['red'] else '🟢 green'} |")
    out = ["\n".join(lines), ""]
    for r in results:
        v = r["visibility"]
        out += [f"## {r['run']}", "", f"{r['description']}. World **{r['world']}**, lag **{r['lag']}**"
                + (f" (merges and mutations on {r['lagging']} stopped for {r['hold_s']} s from just before the migration)" if r["hold_s"] else
                   f" ({r['lagging']}'s background pool is 2 threads; nothing else done to it)") + f". Run started {r['started_utc']}.", ""]
        out += ["| | |", "|---|---|"]
        for name, f in r["facts"].items():
            if "error" in f:
                out.append(f"| {name} before | could not read: {f['error']} |")
            else:
                out.append(f"| {name} before | {f['rows']:,} rows, {f['parts']} active parts, {f['bytes'] / 2**30:.2f} GiB; skip indexes {', '.join(f['skip_indexes'])} |")
        for st in r["statements"] + r.get("after_deploy", []):
            out.append(f"| `{st['sql']}` | {'returned' if st['ok'] else 'FAILED'} after {st['seconds']:.2f} s"
                       + ("" if st["ok"] else f": {st.get('error', '')[:160]}") + " |")
        for name in r["replicas"]:
            out.append(f"| {name} | column visible {fmt_s(v['column_visible_s'][name])} after the migration started; "
                       f"its mutations done {fmt_s(v['mutations_done_s'][name])} |")
        out.append(f"| the gap | runner returned {fmt_s(v['runner_returned_s'])}; column on every replica {fmt_s(v['everywhere_s'])}; gap {fmt_s(v['gap_s'])} |")
        for cell, c in r["cells"].items():
            codes = ", ".join(f"code {k} × {n}" for k, n in sorted(c["failed_attempts_by_code"].items())) or "none"
            out.append(f"| {cell} ({c['version']} writer) | {c['attempted']} batches: {c['acked']} acked ({c['retried']} after a retry), "
                       f"{c['dropped']} dropped; **{c['never_landed']} never landed on every replica** ({c['acked_but_missing']} acked and missing); "
                       f"failed attempts: {codes}; read-back misses {c['read_back_failed']} |")
        for name, rt in r["round_trip"].items():
            s = "synced" if rt.get("synced", True) else f"SYNC failed: {rt.get('sync_error')}"
            out.append(f"| round trip on {name} | {s}{' in ' + str(rt['sync_seconds']) + ' s' if 'sync_seconds' in rt else ''}; "
                       f"{len(rt['batches'] or {})} writer batches present |")
        out.append(f"| verdict | {'🔴 red' if r['verdict']['red'] else '🟢 green'}"
                   + ("".join(f"<br>{f}" for f in r["verdict"]["findings"])) + " |")
        out += ["", "<details><summary>Every replica, every 5 s from the migration</summary>", "", "```",
                "     t  " + "  ".join(f"{n + ': col mut parts_to_do queue alter_meta':<44}" for n in r["replicas"])]
        last = None
        for row in r["timeline"]:
            if row["t"] < r["migration_started_s"] - 0.001 or (last is not None and row["t"] - last < 5):
                continue
            last = row["t"]
            cols = []
            for n in r["replicas"]:
                x = row.get(n) or {}
                cols.append(f"{'err':<44}" if "error" in x else
                            f"{'':<4}{x['has_column']:>3} {x['mutations_open']:>3} {x['parts_to_do']:>10} {x['queue']:>5} {x['alter_metadata_queued']:>10}{'':<5}")
            out.append(f"{row['t'] - r['migration_started_s']:6.1f}  " + "  ".join(cols))
        out += ["```", "", "</details>", ""]
    return "\n".join(out)


# ---------------------------------------------------------------------- CLI
class Proc:
    """A writer process: stop() sends SIGTERM and waits for it to finish its batch."""

    def __init__(self, argv):
        self.p = subprocess.Popen(argv)

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.p.kill()


def spawner(s, world):
    reps = s["worlds"][world]["replicas"]

    def spawn(version, first, log, names):
        targets = ",".join(f"{n}=http://127.0.0.1:{os.environ.get(PORT_ENV.get(n, ''), reps[n])}" for n in names)
        w = s["writer"]
        return Proc([sys.executable, os.path.join(HERE, "writer.py"), "--version", version, "--targets", targets,
                     "--log", log, "--first-batch", str(first), "--batches-per-s", str(w["batches_per_s"]),
                     "--rows", str(w["rows_per_batch"]), "--retries", str(w["retries"]),
                     "--backoff", ",".join(str(b) for b in w["backoff_s"])])
    return spawn


def generate(s, world, clients, rows=None, log=print):
    first = next(iter(clients.values()))
    first.query(open(os.path.join(HERE, s["worlds"][world]["schema"])).read())
    gen = open(os.path.join(HERE, "sql", "generate.sql")).read()
    t, total = time.time(), rows or s["rows"]
    for off in range(0, total, s["chunk"]):
        n = min(s["chunk"], total - off)
        first.query(gen.replace("{offset}", str(off)).replace("{rows}", str(n)).replace("{now}", s["now"]), timeout=3600)
        log(f"  generated {off + n:,} / {total:,} rows ({time.time() - t:.0f} s)", file=sys.stderr)
    if world == "replicated":
        for name, cl in clients.items():
            cl.query(f"SYSTEM SYNC REPLICA {s['table']}", timeout=3600)
        log(f"  every replica caught up ({time.time() - t:.0f} s)", file=sys.stderr)
    return facts(clients, s["table"])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", default=os.path.join(HERE, "scenario.yml"), help="default: scenario.yml beside this file")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--world", required=True)
    g.add_argument("--rows", type=int, help="default: the scenario's rows")
    r = sub.add_parser("run")
    r.add_argument("--run", required=True)
    r.add_argument("--out", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--world", default="replicated")
    v.add_argument("--rows", type=int)
    v.add_argument("--drain-s", type=int, default=300)
    p = sub.add_parser("report")
    p.add_argument("dirs", nargs="+")
    a = ap.parse_args(argv)
    s = load_scenario(a.scenario)
    if a.cmd == "generate":
        print(json.dumps(generate(s, a.world, clients_for(s, a.world), a.rows), indent=1))
    elif a.cmd == "run":
        run = run_entry(s, a.run)
        os.makedirs(a.out, exist_ok=True)
        cl = clients_for(s, run["world"])
        res = Rehearsal(s, run, cl, spawner(s, run["world"]), a.out).go()
        json.dump(res, open(os.path.join(a.out, "result.json"), "w"), indent=1)
        print(json.dumps({"run": res["run"], "verdict": res["verdict"], "visibility": res["visibility"]}, indent=1))
    elif a.cmd == "verify":
        res = verify(clients_for(s, a.world), s["table"], s["column"], a.rows, a.drain_s)
        print(json.dumps(res, indent=1))
        return 0 if res["ok"] else 1
    elif a.cmd == "report":
        results = [json.load(open(os.path.join(d, "result.json"))) for d in a.dirs]
        print(report(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
