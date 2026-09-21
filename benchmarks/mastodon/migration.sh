#!/usr/bin/env bash
# Two migrations Mastodon's strong_migrations would refuse if written naively, run against the
# 100M-row statuses table and rolled back, with the lock mode observed from a second session;
# then the safe form of each, timed. Nothing is left behind.
#   benchmarks/mastodon/migration.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
psql() { "$HERE/md.sh" exec -T db psql -U postgres -d mastodon_production -Atq "$@"; }
locks() { psql -c "select string_agg(distinct l.mode, ',') from pg_locks l join pg_class c on c.oid=l.relation where c.relname='statuses' and l.granted and l.pid<>pg_backend_pid()"; }
run_naive() { # $1 label, $2 sql (inside a transaction, rolled back)
  echo "== naive: $1"
  "$HERE/md.sh" stop web sidekiq streaming >/dev/null 2>&1
  psql -c "select count(*) from statuses" | sed 's/^/   rows: /'
  ( sleep 3; echo "   lock on statuses while it runs: $(locks)" ) &
  t0=$(date +%s.%N); psql -c "BEGIN; $2; ROLLBACK;" 2>&1 | grep -iE 'error' | sed 's/^/   /'; wait
  echo "   duration: $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s (rolled back)"
}
run_naive "CREATE INDEX without CONCURRENTLY (strong_migrations: blocks writes on the table for the whole build)" \
  "CREATE INDEX index_statuses_on_language_and_id ON statuses (language, id DESC)"
run_naive "ALTER COLUMN language SET NOT NULL (strong_migrations: full-table scan under ACCESS EXCLUSIVE)" \
  "ALTER TABLE statuses ALTER COLUMN language SET NOT NULL"
echo "== safe: CREATE INDEX CONCURRENTLY (writes continue; cannot run in a transaction, so built then dropped)"
( sleep 3; echo "   lock on statuses while it runs: $(locks)" ) &
t0=$(date +%s.%N); psql -c "CREATE INDEX CONCURRENTLY index_statuses_on_language_and_id ON statuses (language, id DESC)"; wait
echo "   duration: $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
t0=$(date +%s.%N); psql -c "DROP INDEX CONCURRENTLY index_statuses_on_language_and_id"; echo "   drop: $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
echo "== safe: CHECK (language IS NOT NULL) NOT VALID, then VALIDATE (SHARE UPDATE EXCLUSIVE: reads and writes continue), then SET NOT NULL skips the scan"
( sleep 3; echo "   lock on statuses during VALIDATE: $(locks)" ) &
# two transactions: in one, the ADD's ACCESS EXCLUSIVE lock would be held through the VALIDATE scan
t0=$(date +%s.%N); psql -c "ALTER TABLE statuses ADD CONSTRAINT statuses_language_null CHECK (language IS NOT NULL) NOT VALID"; psql -c "ALTER TABLE statuses VALIDATE CONSTRAINT statuses_language_null"; wait
echo "   add+validate: $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
t0=$(date +%s.%N); psql -c "ALTER TABLE statuses ALTER COLUMN language SET NOT NULL; ALTER TABLE statuses DROP CONSTRAINT statuses_language_null; ALTER TABLE statuses ALTER COLUMN language DROP NOT NULL"; echo "   set not null (no scan) + undo: $(echo "$t0 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}')s"
"$HERE/md.sh" start web sidekiq streaming >/dev/null 2>&1
psql -c "select indexname from pg_indexes where indexname='index_statuses_on_language_and_id'" | grep -q . && echo "LEFTOVER INDEX" || echo "== clean: nothing left behind"
