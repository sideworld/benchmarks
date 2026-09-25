"""PAR-76's rehearsal, tested without a database: the box should only have to run it.

    python3 -m unittest discover -s tests      # from the rehearsal's directory; needs PyYAML

The app's retrying and skew against fakes; the world's files against each other (the schema, the
generator, the changes, the compose file, the Migration Check adapter, the app spec); and, when
paraglobe is checked out beside this repository (or PARAGLOBE_DIR names it), each change put
through the Check's own extractor with the world's own config, as a pull request would be.
"""
import json
import os
import random
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

import yaml

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HERE, "app"))
import cascade_app as app  # noqa: E402

PARAGLOBE = os.environ.get("PARAGLOBE_DIR") or os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "paraglobe"))
REL = "benchmarks/incident-shapes/cascade-delete"


def read(*p):
    with open(os.path.join(HERE, *p)) as f:
        return f.read()


SCHEMA = read("migrations", "0001_schema.sql")
TABLES = re.findall(r"^CREATE TABLE (\w+)", SCHEMA, re.M)
CHANGES = {n: read("changes", n + ".sql") for n in ("delete-small-account", "delete-huge-account", "purge-huge-account-batched")}


class PgError(Exception):
    def __init__(self, msg, sqlstate=None):
        super().__init__(msg)
        self.sqlstate = sqlstate


class OperationalError(Exception):
    pass


class PoolTimeout(Exception):
    pass


class ErrorClasses(unittest.TestCase):
    def test_each_failure_is_named(self):
        cases = [(PgError("canceling statement due to statement timeout", "57014"), "statement_timeout"),
                 (PgError("canceling statement due to lock timeout", "55P03"), "lock_timeout"),
                 (PgError("insert violates foreign key", "23503"), "fk_violation"),
                 (PgError("deadlock detected", "40P01"), "deadlock"),
                 (OperationalError("server closed the connection: ERROR: query_wait_timeout"), "pgbouncer_query_wait_timeout"),
                 (OperationalError("ERROR: no more connections allowed (max_client_conn)"), "too_many_clients"),
                 (PoolTimeout("couldn't get a connection after 10.00 sec"), "app_pool_timeout"),
                 (OperationalError("connection refused"), "connection"),
                 (ValueError("x"), "ValueError")]
        for e, want in cases:
            self.assertEqual(app.error_class(e), want, repr(e))


class Retries(unittest.TestCase):
    def test_the_executor_tries_five_times_then_gives_up(self):
        calls, sleeps, told = [], [], []

        def fail():
            calls.append(1)
            raise PgError("timeout", "57014")
        with self.assertRaises(PgError):
            app.with_retries(fail, 5, app.executor_backoff, sleep=sleeps.append, on_retry=lambda k, e: told.append(k))
        self.assertEqual(len(calls), 5)
        self.assertEqual(sleeps, [0.25, 0.5, 1.0, 2.0])
        self.assertEqual(told, [1, 2, 3, 4])

    def test_backoff_is_capped(self):
        self.assertEqual([app.executor_backoff(k) for k in range(1, 8)], [0.25, 0.5, 1.0, 2.0, 4.0, 4.0, 4.0])
        self.assertEqual([app.service_backoff(k) for k in (1, 2)], [0.2, 0.5])

    def test_a_vanished_account_is_not_retried(self):
        calls = []

        def fail():
            calls.append(1)
            raise PgError("violates foreign key constraint", "23503")
        with self.assertRaises(PgError):
            app.with_retries(fail, 5, app.executor_backoff, sleep=lambda s: None,
                             retryable=lambda e: app.error_class(e) != "fk_violation")
        self.assertEqual(len(calls), 1)

    def test_success_after_a_retry_returns_the_value(self):
        n = []

        def flaky():
            n.append(1)
            if len(n) < 3:
                raise OperationalError("query_wait_timeout")
            return "ok"
        self.assertEqual(app.with_retries(flaky, 3, app.service_backoff, sleep=lambda s: None), "ok")


class Skew(unittest.TestCase):
    def test_accounts_are_picked_in_proportion_to_their_size(self):
        # the generator's shape: runs(a) = max(5, 600000 / a^1.3)
        accts = [(a, max(5, int(600000 / a ** 1.3)), 0, 5) for a in range(1, 20001)]
        p = app.Picker(accts, random.Random(1))
        n = 50000
        hits = sum(1 for _ in range(n) if p.pick()[0] == 1)
        share = accts[0][1] / sum(a[1] for a in accts)
        self.assertAlmostEqual(hits / n, share, delta=0.01)
        self.assertGreater(share, 0.2, "account 1 gets about a quarter of the executor's runs")

    def test_a_dropped_account_is_never_picked_again(self):
        p = app.Picker([(1, 100, 0, 5), (2, 1, 5, 5)], random.Random(2))
        p.drop(1)
        self.assertEqual({p.pick()[0] for _ in range(200)}, {2})
        p.drop(2)
        self.assertIsNone(p.pick())


class FakeConn:
    def __init__(self):
        self.sql, self.in_txn = [], 0

    class Txn:
        def __init__(self, c):
            self.c = c

        def __enter__(self):
            self.c.in_txn += 1

        def __exit__(self, *a):
            self.c.in_txn -= 1

    def transaction(self):
        return self.Txn(self)

    def execute(self, sql, params=None):
        assert self.in_txn, "every statement of a run is inside its transaction"
        self.sql.append(" ".join(sql.split()))

        class R:
            def fetchone(_):
                return (len(self.sql),)
        return R()


class TheRun(unittest.TestCase):
    def test_a_run_locks_its_account_before_anything_else(self):
        c = FakeConn()
        app.record_run(c, (1, 600000, 1, 100), random.Random(3))
        self.assertTrue(c.sql[0].startswith("SET LOCAL statement_timeout = '30s'"))
        self.assertEqual(c.sql[1], "SELECT 1 FROM accounts WHERE id = %s FOR KEY SHARE",
                         "without it the cascade and the run lock account and workspace in opposite orders: a deadlock")
        joined = " | ".join(c.sql)
        for t in ("events", "event_payloads", "function_runs", "run_steps", "run_events", "usage_counters"):
            self.assertIn(t, joined)


class Changes(unittest.TestCase):
    def test_every_change_expects_to_lose_every_table(self):
        for name, text in CHANGES.items():
            m = re.search(r"--\s*paraglobe:\s*expect-row-loss\s+(.+)$", text, re.M)
            self.assertIsNotNone(m, name)
            self.assertEqual(sorted(t.strip() for t in m.group(1).split(",")), sorted(TABLES), name)

    def test_the_deletes_are_one_statement_each_on_the_right_account(self):
        self.assertIn("DELETE FROM accounts WHERE id = 15000;", CHANGES["delete-small-account"])
        self.assertIn("DELETE FROM accounts WHERE id = 1;", CHANGES["delete-huge-account"])
        for n in ("delete-small-account", "delete-huge-account"):
            code = [ln for ln in CHANGES[n].splitlines() if ln.strip() and not ln.startswith("--")]
            self.assertEqual(len(code), 1, n)

    def test_the_services_never_touch_the_deleted_accounts(self):
        self.assertTrue(app.SVC_LO > 1 and app.SVC_HI < 15000)

    def test_the_batched_purge_reaches_every_table_and_runs_outside_a_transaction(self):
        text = CHANGES["purge-huge-account-batched"]
        self.assertTrue(text.startswith("-- cascade:no-transaction"))
        deleted = set(re.findall(r"DELETE FROM (\w+)", text))
        # usage_counters goes with the account row, in the last step's cascade
        self.assertEqual(sorted(deleted | {"usage_counters"}), sorted(TABLES))
        self.assertIn("set_config('lock_timeout', '2s', true)", text)
        self.assertIn("WHEN lock_not_available", text)
        self.assertIn("CALL purge_account(1, 2000);", text)
        self.assertNotRegex(text, r"\bON\s+\w+\.\w+", "the Check's table detection reads a join's ON alias.id as a table named id")

    def test_each_batch_commits(self):
        body = CHANGES["purge-huge-account-batched"].split("CREATE PROCEDURE", 1)[1]
        self.assertEqual(body.count("COMMIT;"), 6, "four batched loops, the small tables, the account row")


class TheWorld(unittest.TestCase):
    compose = yaml.safe_load(read("compose", "docker-compose.cascade.yml"))
    adapter = yaml.safe_load(read("migration-check.yml"))
    spec = dict(tok.split("=", 1) for ln in read("app.spec").splitlines()
                for tok in shlex.split(ln, comments=True) if "=" in tok)

    def env(self, name):
        return dict(ln.split("=", 1) for ln in read("compose", name).splitlines() if ln and not ln.startswith("#"))

    def test_every_foreign_key_cascades_and_is_indexed(self):
        fks = re.findall(r"(\w+)\s+bigint(?: NOT NULL)?(?: PRIMARY KEY)? REFERENCES (\w+) ON DELETE (\w+)", SCHEMA)
        self.assertGreaterEqual(len(fks), 24)
        self.assertEqual({act for _, _, act in fks}, {"CASCADE"})
        self.assertEqual(len(TABLES), 25, "PAR-76: an account root and 10-30 tables under it")
        for col, parent, _ in fks:
            if "PRIMARY KEY REFERENCES" in SCHEMA.split(col, 1)[1][:40]:
                continue
            self.assertRegex(SCHEMA, rf"CREATE INDEX ON \w+ \({col}[,)]", f"{col} -> {parent} has no index")

    def test_the_generator_fills_every_table(self):
        gen = read("scale", "gen.sql")
        filled = set(re.findall(r"INSERT INTO (\w+)", gen))
        self.assertEqual(sorted(filled), sorted(TABLES))
        self.assertIn(":scale", gen)
        self.assertIn(":accounts", gen)
        code = "\n".join(ln for ln in gen.splitlines() if not ln.lstrip().startswith("--"))
        self.assertNotRegex(code, r"\brandom\(", "deterministic: the same size is the same world")

    def test_pgbouncer_pools_by_transaction_well_under_the_cap(self):
        pb = self.compose["services"]["pgbouncer"]["environment"]
        self.assertEqual(pb["POOL_MODE"], "transaction")
        self.assertEqual(int(pb["DEFAULT_POOL_SIZE"]), 20)
        self.assertIn("-c max_connections=100", self.compose["services"]["db"]["command"])
        for s in ("api", "billing", "dashboard", "ingest", "executor"):
            self.assertIn("@pgbouncer:5432/", self.compose["services"][s]["environment"]["DATABASE_URL"], s)

    def test_nothing_is_bind_mounted_but_the_database(self):
        for name, svc in self.compose["services"].items():
            for v in svc.get("volumes", []):
                self.assertEqual(name, "db", f"{name} mounts {v}: the guest would not have it")
        self.assertEqual({s.get("image") for n, s in self.compose["services"].items() if n not in ("db", "pgbouncer")},
                         {"sideworld/cascade-app:v1"})
        self.assertIn("IMG=sideworld/cascade-app:v1", read("build-image.sh"))

    def test_the_guest_ports_line_up_with_the_probes(self):
        vm, host = self.env("vm.env"), self.env("cascade.env")
        ports = self.spec["GUEST_PORTS"].split()
        self.assertEqual(ports, [vm[k] for k in ("API_PORT", "BILLING_PORT", "DASHBOARD_PORT", "INGEST_PORT")])
        self.assertEqual(vm["CASCADE_BIND"], "0.0.0.0")
        self.assertEqual(host["CASCADE_BIND"], "127.0.0.1")
        # the fork forwards the guest ports, in order, to 3<kk>80, 90, 70, 60
        urls = {p["name"]: p["url"] for p in self.adapter["probes"]}
        self.assertEqual(urls["api_functions"], "http://127.0.0.1:${PORT}/functions")
        self.assertIn(":3${CI_KK}90/invoices", urls["billing_invoices"])
        self.assertIn(":3${CI_KK}70/runs", urls["dashboard_runs"])
        self.assertIn(":3${CI_KK}60/events", urls["ingest_event"])
        self.assertIn(self.adapter["drain_probe"], urls)

    def test_the_check_reaches_postgres_directly(self):
        self.assertIn("cascade-db psql", self.adapter["db_exec"])
        self.assertEqual(self.compose["services"]["db"]["container_name"], "cascade-db")
        self.assertEqual(self.adapter["table"], "accounts")


@unittest.skipUnless(os.path.exists(os.path.join(PARAGLOBE, "ops", "ci-migration-extract.py"))
                     and os.path.exists(os.path.join(PARAGLOBE, "ops", "ci", "cascade.yml")),
                     "paraglobe with ops/ci/cascade.yml is not checked out beside this repository (set PARAGLOBE_DIR)")
class TheCheckReadsThem(unittest.TestCase):
    """Each change as a pull request's migration file, through the Check's own extractor."""

    def extract(self, name):
        with tempfile.TemporaryDirectory() as t:
            path = f"{REL}/migrations/0002_{name.replace('-', '_')}.sql"
            os.makedirs(os.path.join(t, os.path.dirname(path)))
            with open(os.path.join(t, path), "w") as f:
                f.write(CHANGES[name])
            with open(os.path.join(t, "changed"), "w") as f:
                f.write(path + "\n")
            subprocess.run([sys.executable, os.path.join(PARAGLOBE, "ops", "ci-migration-extract.py"),
                            os.path.join(PARAGLOBE, "ops", "ci", "cascade.yml"), t, os.path.join(t, "changed"),
                            os.path.join(t, "m.json")], check=True)
            with open(os.path.join(t, "m.json")) as f:
                return json.load(f)

    def test_the_deletes(self):
        for name in ("delete-small-account", "delete-huge-account"):
            m = self.extract(name)
            self.assertEqual([f["version"] for f in m["files"]], ["0002"], name)
            self.assertTrue(m["naive"]["transaction"], name)
            self.assertEqual([s["kind"] for s in m["naive"]["statements"]], ["delete"], name)
            self.assertEqual(m["tables"], ["accounts"], name)
            self.assertEqual(sorted(m["named"]["expected_loss"]), sorted(TABLES), name)
            self.assertFalse(m["safe"]["available"], name)

    def test_the_batched_purge(self):
        m = self.extract("purge-huge-account-batched")
        self.assertFalse(m["naive"]["transaction"], "CALL with COMMITs inside must not be wrapped in BEGIN")
        self.assertEqual(m["tables"], ["function_runs"])
        self.assertEqual(sorted(m["named"]["expected_loss"]), sorted(TABLES))
        self.assertTrue(m["named"]["deletes"])


if __name__ == "__main__":
    unittest.main()
