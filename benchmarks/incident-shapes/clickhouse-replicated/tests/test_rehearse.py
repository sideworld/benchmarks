"""PAR-73's rehearsal against the fake cluster: the box should only have to run it.

    python3 -m unittest discover -s tests      # from the rehearsal's directory; needs PyYAML
"""
import copy
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import rehearse  # noqa: E402
import writer  # noqa: E402
from fakes import Cluster, spawner  # noqa: E402

SCENARIO = rehearse.load_scenario()


def small(**windows):
    """The real scenario.yml with short windows and small batches, so a run takes the fake a moment."""
    s = copy.deepcopy(SCENARIO)
    s["windows"] = {"warm": 2, "before": 5, "settle_max": 300, "after": 5, "sample": 0.5, **windows}
    s["writer"]["rows_per_batch"] = 10
    s["lag"]["hold_s"] = 30
    return s


def rehearse_with(run_name, mutation_s, scenario=None, replicated=None, fail=None, gives_up=None, spawn=None, inactive_s=None):
    s = scenario or small()
    run = rehearse.run_entry(s, run_name)
    replicated = run["world"] == "replicated" if replicated is None else replicated
    names = s["worlds"][run["world"]]["replicas"]
    k = Cluster({n: mutation_s.get(n, 0.2) for n in names}, replicated=replicated)
    k.fail_statement, k.alter_sync_gives_up_s = fail, gives_up
    for n, secs in (inactive_s or {}).items():
        k.r[n].inactive_until = k.clock() + secs
    out = tempfile.mkdtemp()
    r = rehearse.Rehearsal(s, run, {n: k.client(n) for n in names}, (spawn or spawner)(k), out,
                           clock=k.clock, sleep=k.clock.sleep, log=lambda *a, **kw: None).go()
    json.loads(json.dumps(r))    # what run writes must be JSON
    return r, k


class Writers(unittest.TestCase):
    class Refuses:
        def __init__(self, fail_times, code=16):
            self.left, self.code, self.inserts = fail_times, code, 0

        def query(self, sql, body=None, timeout=None):
            if body is not None:
                self.inserts += 1
                if self.left:
                    self.left -= 1
                    raise writer.CHError(self.code, "Code: 16. No such column region")
                self.rows = len(body.splitlines())
                return ""
            return f"{self.rows}\n"

    def test_three_retries_then_the_batch_is_dropped(self):
        sleeps = []
        c = self.Refuses(99)
        w = writer.Writer("new", {"ch2": c}, 7, rows_per_batch=5, retries=3, backoff=(0.5, 1, 2), sleep=sleeps.append)
        rec = w.send()
        self.assertEqual(rec["outcome"], "dropped")
        self.assertEqual(rec["attempts"], 4)
        self.assertEqual(c.inserts, 4)
        self.assertEqual(sleeps, [0.5, 1, 2])
        self.assertEqual([e["code"] for e in rec["errors"]], [16] * 4)
        self.assertIsNone(rec["read_back"])

    def test_a_retry_that_succeeds_is_acked_and_read_back(self):
        c = self.Refuses(2)
        rec = writer.Writer("new", {"ch2": c}, 7, rows_per_batch=5, sleep=lambda s: None).send()
        self.assertEqual((rec["outcome"], rec["attempts"], rec["read_back"]), ("acked", 3, True))

    def test_only_the_new_writer_names_the_new_column(self):
        self.assertIn("region", writer.Writer("new", {}, 1).insert_sql())
        self.assertNotIn("region", writer.Writer("old", {}, 1).insert_sql())
        self.assertTrue(all("region" in json.loads(x) for x in writer.rows("new", 3, 4, 0).splitlines()))
        self.assertFalse(any("region" in json.loads(x) for x in writer.rows("old", 3, 4, 0).splitlines()))

    def test_batches_round_robin_over_the_replicas(self):
        w = writer.Writer("old", {"ch1": self.Refuses(0), "ch2": self.Refuses(0)}, 1, rows_per_batch=2, sleep=lambda s: None)
        self.assertEqual([w.send()["replica"] for _ in range(4)], ["ch1", "ch2", "ch1", "ch2"])

    def test_event_ids_never_collide_across_the_two_writers(self):
        old = {json.loads(x)["event_id"] for b in range(1, 50) for x in writer.rows("old", b, 1000, 0).splitlines()}
        new = {json.loads(x)["event_id"] for b in range(rehearse.FIRST_BATCH["new"], rehearse.FIRST_BATCH["new"] + 50)
               for x in writer.rows("new", b, 1000, 0).splitlines()}
        self.assertFalse(old & new)


class TheShape(unittest.TestCase):
    """The incident's shape, the safe form, and the single node, end to end on the fake."""

    def test_naive_with_a_held_replica_is_red(self):
        r, k = rehearse_with("naive-held", {"ch1": 0.2, "ch2": 5})
        v = r["visibility"]
        self.assertLess(v["runner_returned_s"], 2, "the runner reports success quickly")
        self.assertGreaterEqual(v["column_visible_s"]["ch2"], 30, "ch2 has the column only after the hold")
        self.assertLess(v["column_visible_s"]["ch1"], 2)
        self.assertGreater(v["gap_s"], 25)
        new, old = r["cells"]["new-app-new-schema"], r["cells"]["old-app-new-schema"]
        self.assertGreater(new["dropped"], 0)
        self.assertEqual(new["never_landed"], new["dropped"])
        self.assertEqual(new["never_landed_by_replica"]["ch1"], 0, "only the lagging replica refuses")
        self.assertGreater(new["never_landed_by_replica"]["ch2"], 0)
        self.assertEqual(new["failed_attempts_by_code"].get("16", 0), 4 * new["dropped"])
        self.assertEqual(old["never_landed"], 0, "the old writer is fine on the new schema")
        self.assertTrue(r["verdict"]["red"])
        self.assertTrue(any("never landed" in f for f in r["verdict"]["findings"]))
        self.assertTrue(any("the column was on every replica" in f for f in r["verdict"]["findings"]))
        self.assertFalse(k.r["ch2"].stopped, "the hold is released")
        self.assertTrue(r["settled"])

    def test_naive_without_lag_is_green(self):
        r, _ = rehearse_with("naive-pool", {"ch1": 0.2, "ch2": 0.2})
        self.assertFalse(r["verdict"]["red"], r["verdict"])
        self.assertEqual(r["cells"]["new-app-new-schema"]["never_landed"], 0)

    def test_the_safe_form_under_the_same_hold_is_green(self):
        r, k = rehearse_with("safe-held", {"ch1": 0.2, "ch2": 5})
        self.assertFalse(r["verdict"]["red"], r["verdict"])
        self.assertEqual(r["cells"]["new-app-new-schema"]["dropped"], 0)
        v = r["visibility"]
        self.assertLessEqual(v["everywhere_s"], r["deployed_s"] - r["migration_started_s"],
                             "the new writer starts only once every replica has the column")
        self.assertEqual([st["sql"] for st in r["after_deploy"]], ["ALTER TABLE events DROP INDEX idx_payload"])
        self.assertGreaterEqual(v["mutations_done_s"]["ch2"], 30, "the index drop waits out the hold, harmlessly")
        self.assertEqual(k.r["ch2"].indexes, ["idx_name"])

    def test_the_safe_forms_gate_holds_the_deploy_when_alter_sync_gives_up(self):
        # ch2 is inactive for the first 40 s (its Keeper session lost), so alter_sync=2 raises
        # UNFINISHED once replication_wait_for_inactive_replica_timeout passes: the runner has
        # "returned" and the column is still not on ch2. The gate is what keeps the new writer back.
        r, _ = rehearse_with("safe-held", {"ch1": 0.2, "ch2": 5}, gives_up=5, inactive_s={"ch2": 40})
        self.assertFalse(r["runner_ok"])
        self.assertLess(r["visibility"]["runner_returned_s"], 10)
        self.assertGreaterEqual(r["deployed_s"] - r["migration_started_s"], 30)
        self.assertEqual(r["cells"]["new-app-new-schema"]["dropped"], 0)
        self.assertFalse(any("never landed" in f for f in r["verdict"]["findings"]))

    def test_a_gate_that_never_opens_deploys_nothing(self):
        r, _ = rehearse_with("safe-held", {"ch1": 0.2, "ch2": 5}, scenario=small(settle_max=20), gives_up=5,
                             inactive_s={"ch2": 10_000})
        self.assertFalse(r["gate_opened"])
        self.assertIsNone(r["deployed_s"])
        self.assertNotIn("new-app-new-schema", r["cells"])
        self.assertTrue(any("gate never opened" in f for f in r["verdict"]["findings"]))

    def test_the_single_node_blocks_the_runner_instead(self):
        r, _ = rehearse_with("single-held", {"ch": 2})
        self.assertGreaterEqual(r["visibility"]["runner_returned_s"], 30, "DROP INDEX waits for its mutation")
        self.assertLessEqual(r["visibility"]["gap_s"], 0.5, "no gap: the column is there when the runner returns")
        self.assertFalse(r["verdict"]["red"], r["verdict"])

    def test_a_failing_statement_still_releases_the_hold_and_stops_the_writers(self):
        r, k = rehearse_with("naive-held", {"ch1": 0.2, "ch2": 5}, fail="DROP INDEX")
        self.assertFalse(r["runner_ok"])
        self.assertFalse(k.r["ch2"].stopped)
        self.assertTrue(all(c["stopped_s"] is not None for c in r["cells"].values()))
        self.assertTrue(any("a statement failed" in f for f in r["verdict"]["findings"]))

    def test_a_crash_mid_run_still_releases_the_hold_and_stops_the_old_writer(self):
        handles = []

        def spawn(k):
            real = spawner(k)

            def go(version, first, log, names):
                if version == "new":
                    raise RuntimeError("the deploy failed")
                handles.append(real(version, first, log, names))
                return handles[-1]
            return go
        k_box = []
        with self.assertRaises(RuntimeError):
            rehearse_with("naive-held", {"ch1": 0.2, "ch2": 5}, spawn=lambda k: (k_box.append(k), spawn(k))[1])
        self.assertFalse(k_box[0].r["ch2"].stopped, "the hold is released on the way out")
        self.assertFalse(handles[0].live, "the old writer is stopped")

    def test_the_report_renders_every_run(self):
        rs = [rehearse_with(n, {"ch1": 0.2, "ch2": 5, "ch": 2})[0] for n in ("naive-held", "safe-held", "single-held")]
        md = rehearse.report(rs)
        self.assertIn("| naive-held | replicated | held 30 s | ok after", md)
        self.assertIn("🔴 red", md)
        self.assertIn("🟢 green", md)
        self.assertEqual(md.count("\n## "), 3)


class RoundTrip(unittest.TestCase):
    """cell_result and verdict on their own: what counts as a write that never landed."""

    def cell(self, records, on, n=10):
        rt = {name: {"batches": b} for name, b in on.items()}
        return rehearse.cell_result(records, rt, list(on), {"version": "new", "rows_per_batch": n}, 0)

    def rec(self, b, outcome="acked", replica="ch1"):
        return {"batch": b, "replica": replica, "t": 5.0, "attempts": 1, "errors": [], "outcome": outcome,
                "read_back": outcome == "acked" or None}

    def test_acked_on_one_replica_and_missing_on_the_other_never_landed(self):
        c = self.cell([self.rec(1), self.rec(2)], {"ch1": {1: 10, 2: 10}, "ch2": {1: 10}})
        self.assertEqual((c["never_landed"], c["acked_but_missing"], c["landed_everywhere"]), (1, 1, 1))
        self.assertEqual(c["first_never_landed_s"], 5.0)

    def test_a_partial_batch_did_not_land(self):
        self.assertEqual(self.cell([self.rec(1)], {"ch1": {1: 7}, "ch2": {1: 7}})["never_landed"], 1)

    def test_an_unreadable_replica_is_red(self):
        rt = {"ch1": {"batches": {1: 10}}, "ch2": {"batches": None, "error": "x"}}
        c = rehearse.cell_result([self.rec(1)], rt, ["ch1", "ch2"], {"version": "old", "rows_per_batch": 10}, 0)
        r = {"cells": {"x": c}, "writer": {"retries": 3}, "statements": [],
             "visibility": {"everywhere_s": 1, "gap_s": 0, "runner_returned_s": 1}}
        self.assertTrue(rehearse.verdict(r)["red"])

    def test_all_landed_is_green(self):
        c = self.cell([self.rec(1), self.rec(2, replica="ch2")], {"ch1": {1: 10, 2: 10}, "ch2": {1: 10, 2: 10}})
        r = {"cells": {"x": c}, "writer": {"retries": 3}, "statements": [],
             "visibility": {"everywhere_s": 1, "gap_s": 0, "runner_returned_s": 1}}
        self.assertEqual(rehearse.verdict(r), {"red": False, "findings": []})


class Visibility(unittest.TestCase):
    def row(self, t, **reps):
        return {"t": t, **{n: {"has_column": c, "mutations_open": m} for n, (c, m) in reps.items()}}

    def test_visible_means_visible_and_stays_so(self):
        tl = [self.row(0, a=(0, 0), b=(0, 0)), self.row(1, a=(1, 1), b=(0, 2)), self.row(2, a=(1, 0), b=(1, 1)),
              self.row(3, a=(1, 0), b=(0, 1)), self.row(4, a=(1, 0), b=(1, 0))]
        v = rehearse.visibility(tl, ["a", "b"], 0, 1)
        self.assertEqual(v["column_visible_s"], {"a": 1, "b": 4})
        self.assertEqual(v["mutations_done_s"], {"a": 2, "b": 4})
        self.assertEqual((v["everywhere_s"], v["gap_s"]), (4, 3))

    def test_never_visible_is_none(self):
        v = rehearse.visibility([self.row(1, a=(1, 0), b=(0, 1))], ["a", "b"], 0, 0.5)
        self.assertIsNone(v["everywhere_s"])
        self.assertIsNone(v["gap_s"])


class Scenario(unittest.TestCase):
    def test_the_scenario_file_is_well_formed(self):
        names = [r["name"] for r in SCENARIO["runs"]]
        self.assertEqual(names, ["naive-pool", "naive-held", "safe-held", "single-pool", "single-held"])
        self.assertGreaterEqual(SCENARIO["rows"], 10_000_000, "PAR-73: tens of millions of rows")
        self.assertEqual(SCENARIO["writer"]["retries"], 3, "PAR-73: dropped after 3 retries")

    def test_a_malformed_scenario_is_refused(self):
        for mutate in (lambda s: s.pop("column"),
                       lambda s: s["naive"].update(deploy="whenever"),
                       lambda s: s["runs"].append(dict(s["runs"][0])),
                       lambda s: s["runs"][0].update(lag="slow"),
                       lambda s: s["matrix"][0].update(writer="newer")):
            s = copy.deepcopy(SCENARIO)
            mutate(s)
            with self.assertRaises(SystemExit):
                rehearse.check_scenario(s)

    def test_the_generator_covers_every_row_once(self):
        k = Cluster({"ch1": 0, "ch2": 0})
        seen = []

        class Recorder:
            def query(self, sql, body=None, timeout=None):
                seen.append(sql)
                return k.client("ch1").query(sql) if "AS skip_indexes" in sql else ""
        s = copy.deepcopy(SCENARIO)
        rehearse.generate(s, "replicated", {"ch1": Recorder(), "ch2": Recorder()}, rows=12_000_000, log=lambda *a, **kw: None)
        chunks = [q for q in seen if "FROM numbers(" in q]
        self.assertEqual(len(chunks), 3)
        self.assertIn("numbers(10000000, 2000000)", chunks[-1])
        self.assertTrue(all("{" not in q.split("FROM numbers")[1] for q in chunks))
        self.assertIn("CREATE TABLE IF NOT EXISTS events ON CLUSTER rehearsal", seen[0])
        self.assertEqual(sum(1 for q in seen if q.startswith("SYSTEM SYNC REPLICA")), 2)

    def test_the_schema_has_the_skip_indexes_and_the_single_node_is_not_replicated(self):
        rep = open(os.path.join(os.path.dirname(HERE), "sql", "schema-replicated.sql")).read()
        one = open(os.path.join(os.path.dirname(HERE), "sql", "schema-single.sql")).read()
        self.assertIn("ReplicatedMergeTree", rep)
        self.assertIn("INDEX idx_payload", rep)
        self.assertNotIn("Replicated", one.split("ENGINE")[1])
        self.assertNotIn("ON CLUSTER", one)


class Verify(unittest.TestCase):
    def pair(self):
        k = Cluster({"ch1": 0, "ch2": 0}, rows=1000)
        return k, {n: k.client(n) for n in ("ch1", "ch2")}

    def test_a_healthy_pair(self):
        k, c = self.pair()
        v = rehearse.verify(c, "events", "region", 1000, drain_s=5, clock=k.clock, sleep=k.clock.sleep)
        self.assertTrue(v["ok"], v)

    def test_a_read_only_replica_fails(self):
        k, c = self.pair()
        k.r["ch2"].readonly = 1
        self.assertFalse(rehearse.verify(c, "events", "region", 1000, drain_s=5, clock=k.clock, sleep=k.clock.sleep)["ok"])

    def test_missing_rows_fail(self):
        k, c = self.pair()
        self.assertFalse(rehearse.verify(c, "events", "region", 1001, drain_s=5, clock=k.clock, sleep=k.clock.sleep)["ok"])

    def test_replicas_disagreeing_on_the_column_fail(self):
        k, c = self.pair()
        k.r["ch1"].columns.add("region")
        self.assertFalse(rehearse.verify(c, "events", "region", 1000, drain_s=5, clock=k.clock, sleep=k.clock.sleep)["ok"])

    def test_a_stuck_queue_fails_after_the_drain(self):
        k, c = self.pair()
        k.r["ch2"].mutations.append(1)
        k.r["ch2"].stopped = True
        v = rehearse.verify(c, "events", "region", 1000, drain_s=5, clock=k.clock, sleep=k.clock.sleep)
        self.assertFalse(v["ok"])
        self.assertEqual(v["replicas"]["ch2"]["mutations_open"], 1)


if __name__ == "__main__":
    unittest.main()
