#!/usr/bin/env bash
# Quiesce TrainTicket's 25 stateful services and snapshot every tank/tt-* dataset as @<name>.
#   benchmarks/trainticket/snapshot.sh <name>
# Mongo: db.fsyncLock() on all 24 (flushes and blocks writes, no restart).
# MySQL: a clean stop (FLUSH TABLES WITH READ LOCK needs a session held open across
#        the snapshot; a clean stop is simpler, explicit, and the voucher DB is tiny).
# Then sync, snapshot all 25 datasets, start MySQL, fsyncUnlock all 24.
set -euo pipefail
NAME=${1:?usage: snapshot.sh <name>}
case "$NAME" in *[!A-Za-z0-9_-]*) echo "bad name" >&2; exit 2 ;; esac
P=${TT_PROJECT:-tt}
MONGOS=$(docker ps --format '{{.Names}}' | grep -E "^$P-ts-.*-mongo-1$" | sort)
MYSQL=$P-ts-voucher-mysql-1
DATASETS=$(zfs list -H -o name -t filesystem | grep '^tank/tt-')
n_ds=$(echo "$DATASETS" | wc -l); n_mongo=$(echo "$MONGOS" | wc -l)
echo "== quiescing $n_mongo mongos + mysql, snapshotting $n_ds datasets as @$NAME"

t0=$(date +%s.%N)
for c in $MONGOS; do docker exec "$c" mongo --quiet --eval 'assert(db.fsyncLock().ok)' >/dev/null; done
docker stop -t 30 "$MYSQL" >/dev/null
sync
t_frozen=$(date +%s.%N)
for d in $DATASETS; do zfs snapshot "$d@$NAME"; done
t_snap=$(date +%s.%N)
docker start "$MYSQL" >/dev/null
for c in $MONGOS; do docker exec "$c" mongo --quiet --eval 'assert(db.fsyncUnlock().ok)' >/dev/null; done
t1=$(date +%s.%N)
f() { echo "$1 $2" | awk '{printf "%.2f", $2-$1}'; }
echo "t_quiesce=$(f "$t0" "$t_frozen")s  t_snapshot_25=$(f "$t_frozen" "$t_snap")s  t_thaw=$(f "$t_snap" "$t1")s  total_frozen=$(f "$t0" "$t1")s"
echo "== snapshots"; zfs list -H -o name,used,referenced -t snapshot | grep "@$NAME$" | awk '{u+=0} {print}' | head -3; echo "   ... $(zfs list -H -o name -t snapshot | grep -c "@$NAME$") snapshots @$NAME"
