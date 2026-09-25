#!/usr/bin/env python3
"""PAR-76's app: four HTTP services and an executor, all on one PgBouncer (transaction pooling).

    ROLE=api|billing|dashboard|ingest|executor  DATABASE_URL=postgresql://...@pgbouncer:5432/cascade

The services are the "unrelated" ones. They never touch the accounts the rehearsal deletes: each
request picks an account from SVC_LO..SVC_HI (2000..14000), and the deletes are account 1 (the
largest) and account 15000 (one of the many small ones).
  api        GET /functions   an account's functions and how many versions each has
  billing    GET /invoices    an account's last 12 invoices and their line counts
  dashboard  GET /runs        an account's 20 most recent runs
  ingest     POST /events     an event for an account, its payload, and the account's usage
                              counter bumped; GET /events/<id> reads one back
Every service also answers GET /healthz without the database and GET /ready with SELECT 1.
Each keeps a pool of POOL (10) client connections to PgBouncer, runs each request's statements
under a 10 s statement_timeout, and retries a failed request twice (0.2 s, then 0.5 s) before it
answers 503 with the error's class.

The executor is the traffic that DOES touch the deleted accounts: function runs arriving at RATE
(150) per second, open loop, for accounts picked in proportion to their size -- account 1, the
largest, gets about a quarter of them. Each job opens its own client connection to PgBouncer
and keeps it until it is done, retries included; at most MAX_INFLIGHT (600) at once, and a job
past that is shed. A run is one transaction: the account row (FOR KEY SHARE, first), an event and
its payload, the run, three steps, two run events, and the account's usage counter. A failed
transaction is retried on the same connection, up to ATTEMPTS (5) times, 0.25 s doubling to at
most 4 s between tries, under a 30 s statement_timeout: the retrying worker of the incident,
whose waiting jobs hold PgBouncer client slots -- and, while a statement waits on a lock, a
server connection too -- while new jobs keep arriving. An account that no longer exists (a
foreign-key violation on it) is dropped from the executor's list, not retried.

Every 10 s each process prints one JSON line of counters (ok, failed, retries, gave up, errors by
class, p50/p99 ms) to its log.
"""
import bisect
import json
import os
import random
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SVC_LO, SVC_HI = int(os.environ.get("SVC_LO", 2000)), int(os.environ.get("SVC_HI", 14000))


# ---------------------------------------------------------------------- pure pieces (tests/)
def error_class(e):
    """A short, stable name for why a database call failed, for the counters and the 503 body."""
    sqlstate = getattr(e, "sqlstate", None)
    text = str(e)
    if sqlstate == "57014":
        return "statement_timeout"
    if sqlstate == "55P03":
        return "lock_timeout"
    if sqlstate == "23503":
        return "fk_violation"
    if sqlstate == "40P01":
        return "deadlock"
    if "query_wait_timeout" in text:
        return "pgbouncer_query_wait_timeout"
    if "no more connections allowed" in text or "too many clients" in text:
        return "too_many_clients"
    if type(e).__name__ == "PoolTimeout":
        return "app_pool_timeout"
    if type(e).__name__ in ("OperationalError", "InterfaceError"):
        return "connection"
    return type(e).__name__


def with_retries(fn, attempts, backoff, sleep=time.sleep, retryable=lambda e: True, on_retry=None):
    """fn() until it returns, at most `attempts` times, sleeping backoff(k) before retry k (1-based).
    Raises the last error. on_retry(k, error) is told about each retry."""
    for k in range(1, attempts + 1):
        try:
            return fn()
        except Exception as e:                                   # noqa: BLE001 -- classified by the caller
            if k == attempts or not retryable(e):
                raise
            if on_retry:
                on_retry(k, e)
            sleep(backoff(k))


def executor_backoff(k):
    return min(4.0, 0.25 * 2 ** (k - 1))


def service_backoff(k):
    return (0.2, 0.5)[min(k, 2) - 1]


class Picker:
    """Accounts in proportion to their size (runs): the executor's traffic is skewed like its data."""

    def __init__(self, accounts, rng=None):
        self.rng = rng or random.Random()
        self.set(accounts)

    def set(self, accounts):
        self.accounts = [a for a in accounts if a[1] > 0]
        self.cum, total = [], 0
        for a in self.accounts:
            total += a[1]
            self.cum.append(total)
        self.total = total

    def pick(self):
        if not self.total:
            return None
        return self.accounts[bisect.bisect_right(self.cum, self.rng.random() * self.total)]

    def drop(self, account_id):
        self.set([a for a in self.accounts if a[0] != account_id])


class Counters:
    def __init__(self, role):
        self.role, self.lock = role, threading.Lock()
        self.reset()

    def reset(self):
        self.ok = self.failed = self.retries = 0
        self.errors, self.ms = {}, []

    def done(self, ms, err=None):
        with self.lock:
            if err is None:
                self.ok += 1
            else:
                self.failed += 1
                self.errors[err] = self.errors.get(err, 0) + 1
            self.ms.append(ms)

    def retry(self, err):
        with self.lock:
            self.retries += 1
            self.errors["retried:" + err] = self.errors.get("retried:" + err, 0) + 1

    def line(self):
        with self.lock:
            ms = sorted(self.ms)
            out = {"t": round(time.time(), 1), "role": self.role, "ok": self.ok, "failed": self.failed,
                   "retries": self.retries, "errors": self.errors,
                   "p50_ms": round(ms[len(ms) // 2], 1) if ms else None,
                   "p99_ms": round(ms[int(0.99 * (len(ms) - 1))], 1) if ms else None}
            self.reset()
        return json.dumps(out)


# ---------------------------------------------------------------------- the database side
def connect():
    import psycopg
    # prepare_threshold=None: no server-side prepared statements, which transaction pooling
    # would hand to whichever server connection the next transaction lands on.
    return psycopg.connect(os.environ["DATABASE_URL"], prepare_threshold=None, connect_timeout=10)


QUERIES = {
    "api": ("SELECT f.id, f.slug, count(v.id) FROM functions f LEFT JOIN function_versions v ON v.function_id = f.id "
            "WHERE f.account_id = %s GROUP BY f.id, f.slug ORDER BY f.id LIMIT 50"),
    "billing": ("SELECT i.period::text, i.total_cents, count(l.id) FROM invoices i JOIN invoice_lines l ON l.invoice_id = i.id "
                "WHERE i.account_id = %s GROUP BY i.id ORDER BY i.period DESC LIMIT 12"),
    "dashboard": "SELECT id, status, started_at::text FROM function_runs WHERE account_id = %s ORDER BY started_at DESC LIMIT 20",
}


class Service:
    def __init__(self, role, pool_size=10, rng=None):
        from psycopg_pool import ConnectionPool
        self.role, self.rng, self.counters = role, rng or random.Random(), Counters(role)
        self.pool = ConnectionPool(os.environ["DATABASE_URL"], min_size=2, max_size=pool_size, timeout=10,
                                   kwargs={"prepare_threshold": None, "connect_timeout": 10}, open=True)

    def account(self):
        return self.rng.randint(SVC_LO, SVC_HI)

    def call(self, work):
        t0, err = time.time(), None
        try:
            return with_retries(lambda: self._once(work), 3, service_backoff,
                                on_retry=lambda k, e: self.counters.retry(error_class(e)))
        except Exception as e:                                   # noqa: BLE001
            err = error_class(e)
            raise
        finally:
            self.counters.done((time.time() - t0) * 1000, err)

    def _once(self, work):
        with self.pool.connection() as conn:
            with conn.transaction():
                conn.execute("SET LOCAL statement_timeout = '10s'")
                return work(conn)

    def read(self):
        a = self.account()
        rows = self.call(lambda c: c.execute(QUERIES[self.role], (a,)).fetchall())
        return {"account": a, "rows": [list(r) for r in rows]}

    def ingest(self, name):
        a = self.account()

        def work(c):
            eid = c.execute("INSERT INTO events (workspace_id, account_id, name) VALUES (%s, %s, %s) RETURNING id",
                            (2 * a - 1, a, name)).fetchone()[0]
            c.execute("INSERT INTO event_payloads (event_id, body) VALUES (%s, %s)", (eid, json.dumps({"name": name})))
            c.execute("UPDATE usage_counters SET events = events + 1, updated_at = now() WHERE account_id = %s", (a,))
            return eid
        return {"account": a, "id": self.call(work)}

    def event(self, eid):
        row = self.call(lambda c: c.execute("SELECT e.id, e.account_id, e.name, p.body FROM events e JOIN event_payloads p "
                                            "ON p.event_id = e.id WHERE e.id = %s", (eid,)).fetchone())
        return None if row is None else {"id": row[0], "account": row[1], "name": row[2], "body": row[3]}

    def ready(self):
        return self.call(lambda c: c.execute("SELECT 1").fetchone()[0]) == 1


def serve(role, port):
    svc = Service(role, int(os.environ.get("POOL", 10)))

    class H(BaseHTTPRequestHandler):
        def answer(self, code, obj):
            body = json.dumps(obj, default=str).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def guarded(self, fn, ok=200):
            try:
                self.answer(ok, fn())
            except Exception as e:                               # noqa: BLE001
                self.answer(503, {"error": error_class(e), "detail": str(e)[:200]})

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/healthz":
                return self.answer(200, {"ok": True, "role": role})
            if path == "/ready":
                return self.guarded(lambda: {"ready": svc.ready()})
            if role in QUERIES and path == {"api": "/functions", "billing": "/invoices", "dashboard": "/runs"}[role]:
                return self.guarded(svc.read)
            m = re.fullmatch(r"/events/(\d+)", path)
            if role == "ingest" and m:
                try:
                    ev = svc.event(int(m.group(1)))
                except Exception as e:                           # noqa: BLE001
                    return self.answer(503, {"error": error_class(e)})
                return self.answer(200 if ev else 404, ev or {"error": "not found"})
            self.answer(404, {"error": "no such path"})

        def do_POST(self):
            if role == "ingest" and self.path.split("?")[0] == "/events":
                n = int(self.headers.get("Content-Length") or 0)
                try:
                    name = json.loads(self.rfile.read(n) or b"{}").get("name") or "probe"
                except ValueError:
                    name = "probe"
                return self.guarded(lambda: svc.ingest(str(name)[:80]), ok=201)
            self.answer(404, {"error": "no such path"})

        def log_message(self, *a):
            pass

    threading.Thread(target=report, args=(svc.counters,), daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    srv.daemon_threads = True
    print(json.dumps({"role": role, "listening": port, "accounts": [SVC_LO, SVC_HI]}), flush=True)
    srv.serve_forever()


def report(counters, every=10):
    while True:
        time.sleep(every)
        print(counters.line(), flush=True)


# ---------------------------------------------------------------------- the executor
def load_accounts(conn):
    return [tuple(r) for r in conn.execute(
        "SELECT a.id, u.runs, a.fn_lo, a.fn_n FROM accounts a JOIN usage_counters u ON u.account_id = a.id").fetchall()]


def record_run(conn, acct, rng):
    a, _, fn_lo, fn_n = acct
    with conn.transaction():
        conn.execute("SET LOCAL statement_timeout = '30s'")
        # The account first, and held until commit: the lock the foreign-key checks below would
        # take anyway, taken before any of them. Without it the first insert locks the workspace
        # row (its FK check) before the account row, a hard delete cascading account -> workspace
        # locks them the other way round, and Postgres's deadlock detector kills one side within
        # deadlock_timeout -- measured locally, it killed the delete (see the README).
        conn.execute("SELECT 1 FROM accounts WHERE id = %s FOR KEY SHARE", (a,))
        eid = conn.execute("INSERT INTO events (workspace_id, account_id, name) VALUES (%s, %s, 'app/run.requested') RETURNING id",
                           (2 * a - 1, a)).fetchone()[0]
        conn.execute("INSERT INTO event_payloads (event_id, body) VALUES (%s, '{}')", (eid,))
        rid = conn.execute("INSERT INTO function_runs (function_id, account_id, event_id, status) VALUES (%s, %s, %s, 'completed') RETURNING id",
                           (fn_lo + rng.randrange(fn_n), a, eid)).fetchone()[0]
        conn.execute("INSERT INTO run_steps (run_id, name, status) SELECT %s, 'step-' || g, 'completed' FROM generate_series(1, 3) g", (rid,))
        conn.execute("INSERT INTO run_events (run_id, kind) VALUES (%s, 'started'), (%s, 'finished')", (rid, rid))
        conn.execute("UPDATE usage_counters SET runs = runs + 1, events = events + 1, updated_at = now() WHERE account_id = %s", (a,))


def executor(rate, max_inflight, attempts, clock=time.time, sleep=time.sleep):
    """Jobs arrive at `rate` per second whatever happens to the earlier ones (open loop), each on
    its own client connection for as long as it runs, retries included. At most `max_inflight` at
    once; a job past that is shed and counted, as a queue consumer at its concurrency limit would."""
    counters, picker, lock = Counters("executor"), Picker([]), threading.Lock()
    inflight = threading.BoundedSemaphore(max_inflight)
    live = [0]

    def refresh():
        while True:
            try:
                with connect() as c:
                    accts = load_accounts(c)
                with lock:
                    picker.set(accts)
            except Exception as e:                               # noqa: BLE001
                print(json.dumps({"role": "executor", "refresh_failed": error_class(e)}), flush=True)
            time.sleep(30)

    def job(acct, seed):
        rng, conn, t0, err = random.Random(seed), None, clock(), None
        with lock:
            live[0] += 1

        def once():
            nonlocal conn
            if conn is None or conn.closed or conn.broken:
                conn = connect()
            record_run(conn, acct, rng)
        try:
            with_retries(once, attempts, executor_backoff,
                         retryable=lambda e: error_class(e) != "fk_violation",
                         on_retry=lambda k, e: counters.retry(error_class(e)))
        except Exception as e:                                   # noqa: BLE001
            err = error_class(e)
            if err == "fk_violation":                            # the account is gone: stop sending it work
                with lock:
                    picker.drop(acct[0])
        finally:
            if conn is not None:
                conn.close()
            with lock:
                live[0] -= 1
            inflight.release()
            counters.done((clock() - t0) * 1000, err)

    def status():
        while True:
            time.sleep(10)
            line = json.loads(counters.line())
            with lock:
                line["inflight"] = live[0]
            print(json.dumps(line), flush=True)

    threading.Thread(target=refresh, daemon=True).start()
    threading.Thread(target=status, daemon=True).start()
    print(json.dumps({"role": "executor", "rate": rate, "max_inflight": max_inflight, "attempts": attempts}), flush=True)
    rng, due, n = random.Random(0), clock(), 0
    while True:
        due += rng.expovariate(rate)
        sleep(max(0.0, due - clock()))
        with lock:
            acct = picker.pick()
        if acct is None:
            continue
        if not inflight.acquire(blocking=False):
            counters.done(0.0, "shed")
            continue
        n += 1
        threading.Thread(target=job, args=(acct, n), daemon=True).start()


def main():
    role = os.environ.get("ROLE", "api")
    if role == "executor":
        executor(float(os.environ.get("RATE", 150)), int(os.environ.get("MAX_INFLIGHT", 600)), int(os.environ.get("ATTEMPTS", 5)))
    elif role in ("api", "billing", "dashboard", "ingest"):
        serve(role, int(os.environ.get("PORT", 8080)))
    else:
        sys.exit(f"unknown ROLE {role!r}")


if __name__ == "__main__":
    main()
