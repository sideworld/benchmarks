#!/usr/bin/env python3
"""PAR-73's writer: the app that inserts events continuously and reads each batch back.

    writer.py --version old|new --targets ch1=http://127.0.0.1:18123,ch2=http://127.0.0.1:28123 \
              --log writer-new.jsonl --first-batch 1000000000 [--batches-per-s 4] [--rows 1000]

Two versions of one writer, like two builds of the same service:
  old  inserts the columns the table had before the migration
  new  also inserts `region`, the column the migration adds -- named in the INSERT's column list,
       so a replica without the column refuses the batch (NO_SUCH_COLUMN_IN_TABLE, code 16).
       Without the column list, JSONEachRow's input_format_skip_unknown_fields (on by default since
       23.x) would drop the value silently instead: a different failure, and not the incident's.

Batches go round-robin across the targets, as a pool of writers spread over the writer replicas
would send them. A failed insert is retried on the same replica up to `retries` times with the
backoff given, then the batch is DROPPED -- the incident's "after 3 retries the batches are
dropped". Every batch is one line of the JSONL log: its id, replica, attempts, the error code of
each failed attempt, the outcome (acked | dropped), and whether reading it back on the replica that
acked it found all its rows. The round trip in rehearse.py compares these logs with what every
replica holds at the end.

Standard library only: the box runs it with its own python3.
"""
import argparse
import json
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

COLUMNS = {
    "old": ["org_id", "event_id", "ts", "name", "environment", "payload", "batch_id"],
    "new": ["org_id", "event_id", "ts", "name", "environment", "payload", "batch_id", "region"],
}
CODE = re.compile(r"Code: (\d+)")
REGIONS = ["us-east-1", "us-west-2", "eu-central-1", "eu-west-1", "ap-southeast-2"]


class CHError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class HTTP:
    """One ClickHouse server over its HTTP interface."""

    def __init__(self, url, timeout=30):
        self.url, self.timeout = url.rstrip("/"), timeout

    def query(self, sql, body=None, timeout=None):
        if body is None:
            url, data = self.url + "/", sql.encode()
        else:
            url, data = self.url + "/?" + urllib.parse.urlencode({"query": sql}), body.encode()
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=timeout or self.timeout) as r:
                return r.read().decode()
        except urllib.error.HTTPError as e:
            text = e.read().decode(errors="replace")
            m = CODE.search(text)
            raise CHError(int(m.group(1)) if m else e.code, text.strip()[:300]) from None
        except (urllib.error.URLError, OSError) as e:   # refused, reset, timed out
            raise CHError(-1, f"{type(e).__name__}: {e}") from None


def rows(version, batch_id, n, now):
    """The batch's rows: org 1..500, an event id unique across every writer (batch_id * 100000 + i)."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(now))
    out = []
    for i in range(n):
        r = {"org_id": 1 + (batch_id * 7 + i) % 500, "event_id": batch_id * 100000 + i, "ts": ts,
             "name": f"event.{i % 40}", "environment": "production", "payload": f"batch {batch_id} row {i}",
             "batch_id": batch_id}
        if version == "new":
            r["region"] = REGIONS[i % len(REGIONS)]
        out.append(json.dumps(r))
    return "\n".join(out) + "\n"


class Writer:
    """The writer's loop, one batch per send(). Clients, clock and sleep are injected for the tests."""

    def __init__(self, version, targets, first_batch, rows_per_batch=1000, retries=3, backoff=(0.5, 1, 2),
                 clock=time.time, sleep=time.sleep, out=None):
        if version not in COLUMNS:
            raise ValueError(f"version must be old or new, not {version!r}")
        self.version, self.targets = version, list(targets.items())
        self.next_batch, self.n, self.retries = first_batch, rows_per_batch, retries
        self.backoff, self.clock, self.sleep, self.out = list(backoff), clock, sleep, out
        self.turn = 0

    def insert_sql(self):
        return f"INSERT INTO events ({', '.join(COLUMNS[self.version])}) FORMAT JSONEachRow"

    def send(self):
        name, client = self.targets[self.turn % len(self.targets)]
        self.turn += 1
        batch, self.next_batch = self.next_batch, self.next_batch + 1
        body, t0, errors = rows(self.version, batch, self.n, self.clock()), self.clock(), []
        for attempt in range(1 + self.retries):
            if attempt:
                self.sleep(self.backoff[min(attempt - 1, len(self.backoff) - 1)])
            try:
                client.query(self.insert_sql(), body)
            except CHError as e:
                errors.append({"code": e.code, "message": str(e)[:160]})
                continue
            rec = {"batch": batch, "version": self.version, "replica": name, "t": round(t0, 3),
                   "attempts": attempt + 1, "errors": errors, "outcome": "acked",
                   "read_back": self.read_back(client, batch)}
            break
        else:
            rec = {"batch": batch, "version": self.version, "replica": name, "t": round(t0, 3),
                   "attempts": 1 + self.retries, "errors": errors, "outcome": "dropped", "read_back": None}
        if self.out:
            self.out.write(json.dumps(rec) + "\n")
            self.out.flush()
        return rec

    def read_back(self, client, batch):
        """All the batch's rows on the replica that acked it (select_sequential_consistency is off:
        an ack from a replica means it holds the part)."""
        try:
            return int(client.query(f"SELECT count() FROM events WHERE batch_id = {batch}").strip() or 0) == self.n
        except CHError:
            return False


def parse_targets(text):
    out = {}
    for part in text.split(","):
        name, _, url = part.partition("=")
        if not url:
            raise SystemExit(f"--targets: {part!r} is not name=url")
        out[name] = HTTP(url)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True, choices=sorted(COLUMNS))
    ap.add_argument("--targets", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--first-batch", type=int, required=True)
    ap.add_argument("--batches-per-s", type=float, default=4)
    ap.add_argument("--rows", type=int, default=1000)
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--backoff", default="0.5,1,2")
    a = ap.parse_args(argv)
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    with open(a.log, "a") as out:
        w = Writer(a.version, parse_targets(a.targets), a.first_batch, a.rows, a.retries,
                   [float(x) for x in a.backoff.split(",")], out=out)
        period, due = 1 / a.batches_per_s, time.time()
        while not stop:            # on a fixed schedule: a batch that ran late (retries) is followed at once by the next one due
            w.send()
            due += period
            time.sleep(max(0, due - time.time()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
