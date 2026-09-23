#!/usr/bin/env bash
# The alternative a team would reach for today: ZFS clones of every dataset as "database branches",
# plus a conventional cold `docker compose up` of the same 38-service stack against them.
#   benchmarks/posthog/alt-baseline.sh up <k> | down <k> | isolation <k>
# `isolation`: capture an event in the branch, prove it is there and NOT in the baseline (port 8100),
# and report the ZFS delta the branch has accumulated (what a Compose fork on ZFS costs).
# Owns tank/ph-alt<k>-* and the compose project ph-alt<k>. Reports: t_clone, t_health (cold up ->
# /_health 200), t_trends_cold / t_trends_warm (the same TrendsQuery twice), and container memory.
set -euo pipefail
ACT=${1:?up|down|isolation}; K=${2:-1}
SPEC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); P=${PH_SRC:-/tank/work/posthog}
PROJ=ph-alt$K; PORT=$((8110 + K)); SNAP=${PH_SNAP:-ph-base}; OVR=$SPEC_DIR/compose/docker-compose.alt$K.yml
EMAIL=${PH_ADMIN_EMAIL:-sideworld@example.test}; PASS=${PH_ADMIN_PASS:-Sideworld-12345678}
SETS="pg:/var/lib/postgresql/data:db ch:/var/lib/clickhouse:clickhouse zk:/data:zookeeper zklog:/datalog:zookeeper kafka:/var/lib/redpanda/data:kafka redis:/data:redis7 minio:/data:objectstorage seaweedfs:/data:seaweedfs"
el() { echo "$1 $(date +%s.%N)" | awk '{printf "%.1f", $2-$1}'; }
dc() { docker compose -p "$PROJ" --project-directory "$P" --env-file "$SPEC_DIR/compose/hobby.env" -f "$SPEC_DIR/compose/docker-compose.hobby.sideworld.yml" -f "$SPEC_DIR/compose/docker-compose.ph.yml" -f "$OVR" "$@"; }
j() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
$1"; }
if [ "$ACT" = isolation ]; then
  sess() { CJ=$(mktemp); curl -sS -m 30 -c "$CJ" -o /dev/null "$1/login"; local c; c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
    curl -sS -m 60 -H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: $1/" -b "$CJ" -c "$CJ" -o /dev/null -X POST "$1/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
    c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: $1/" -b "$CJ" -c "$CJ"); }
  BR="http://127.0.0.1:$PORT"; BL="http://127.0.0.1:8100"; S=$(date +%s%N); EV="branch_isolation_$S"
  sess "$BR"; read -r PID TOK < <(curl -sS -m 30 "${H[@]}" "$BR/api/projects/@current/" | j "print(d.get('id',''), d.get('api_token',''))")
  curl -sS -m 30 -o /dev/null -H "Content-Type: application/json" -X POST "$BR/capture/" -d "{\"api_key\":\"$TOK\",\"event\":\"$EV\",\"distinct_id\":\"iso-$S\",\"properties\":{}}"
  cnt() { sess "$1"; local n=0; for _ in $(seq 1 $2); do n=$(curl -sS -m 60 "${H[@]}" -X POST "$1/api/projects/$PID/query/" -d "{\"query\":{\"kind\":\"HogQLQuery\",\"query\":\"select count() from events where event = '$EV'\"},\"refresh\":\"force_blocking\"}" | j "r=d.get('results') or [[0]]; print(r[0][0] if r and r[0] else 0)"); [ "${n:-0}" -ge 1 ] && break; sleep 0.5; done; echo "${n:-0}"; }
  a=$(cnt "$BR" 240); b=$(cnt "$BL" 20)
  echo "  branch  ($PORT): $a  <- $([ "$a" -ge 1 ] && echo correct || echo WRONG)"; echo "  baseline (8100): $b  <- $([ "$b" -eq 0 ] && echo 'correct (absent after 10 s)' || echo 'WRONG: not isolated')"
  echo "  ZFS delta of the branch:"; zfs list -H -o name,used,referenced tank/ph-alt$K-pg tank/ph-alt$K-ch tank/ph-alt$K-kafka tank/ph-alt$K-redis | sed 's/^/    /'
  exit 0
fi
if [ "$ACT" = down ]; then
  dc down -v --remove-orphans >/dev/null 2>&1 || true
  for e in $SETS; do ds=tank/ph-alt$K-${e%%:*}; zfs list -H -o name "$ds" >/dev/null 2>&1 || continue
    o=$(zfs get -H -o value origin "$ds"); case "$o" in tank/ph-*@*) zfs destroy "$ds" && echo "  destroyed $ds (origin $o)";; *) echo "  refusing $ds: origin '$o'" >&2; exit 1;; esac; done
  rm -f "$OVR"; exit 0
fi
echo "== the branches: $(echo $SETS | wc -w) datasets cloned from @$SNAP"; t0=$(date +%s.%N)
# One block per service: a YAML mapping cannot name a key twice, and the first version of this
# file did (volumes block, then ports block) -- Compose refused it, nothing started, and the
# health loop waited its full 20 minutes for a stack that did not exist.
python3 - "$OVR" "$K" "$PORT" "$SNAP" <<'PY2'
import sys
ovr,k,port,snap=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),sys.argv[4]
sets=[("pg","/var/lib/postgresql/data","db"),("ch","/var/lib/clickhouse","clickhouse"),("zk","/data","zookeeper"),("zklog","/datalog","zookeeper"),
      ("kafka","/var/lib/redpanda/data","kafka"),("redis","/data","redis7"),("minio","/data","objectstorage"),("seaweedfs","/data","seaweedfs")]
svc={}
for name,path,s in sets: svc.setdefault(s,{"volumes":[]})["volumes"].append(f"/tank/ph-alt{k}-{name}:{path}")
ports={"proxy":[f"127.0.0.1:{port}:80"],"objectstorage":[f"127.0.0.1:{19200+k}:19000"],"seaweedfs":[f"127.0.0.1:{8500+k}:8333"],
       "temporal":[f"127.0.0.1:{7400+k}:7233"],"temporal-ui":[f"127.0.0.1:{8200+k}:8080"],"maildev":[f"127.0.0.1:{1200+k}:1080"]}
for s,p in ports.items(): svc.setdefault(s,{})["ports"]=p
svc["seaweedfs"]["container_name"]=f"ph-alt{k}-seaweedfs"
env={"SITE_URL":f"http://localhost:{port}","OBJECT_STORAGE_PUBLIC_ENDPOINT":f"http://localhost:{port}"}
for s in ("web","worker","plugins"): svc.setdefault(s,{})["environment"]=env
svc.setdefault("temporal-django-worker",{})["environment"]={"SITE_URL":f"http://localhost:{port}"}
out=["# generated by alt-baseline.sh","services:"]
for s,d in svc.items():
    out.append(f"  {s}:")
    if "container_name" in d: out.append(f"    container_name: {d['container_name']}")
    if "volumes" in d: out.append("    volumes:"); out += [f"      - {v}" for v in d["volumes"]]
    if "ports" in d: out.append("    ports: !override [" + ", ".join(f'"{x}"' for x in d["ports"]) + "]")
    if "environment" in d: out.append("    environment:"); out += [f'      {kk}: "{vv}"' for kk,vv in d["environment"].items()]
open(ovr,"w").write("\n".join(out)+"\n")
PY2
for e in $SETS; do ds=tank/ph-alt$K-${e%%:*}; zfs list -H -o name "$ds" >/dev/null 2>&1 || zfs clone -o mountpoint=/$ds "tank/ph-${e%%:*}@$SNAP" "$ds"; done
T_CLONE=$(el "$t0"); echo "  t_clone=${T_CLONE}s (copy-on-write)"
echo "== conventional cold up of the stack against the branches"; t0=$(date +%s.%N)
up_rc=0; dc up -d --wait > "$SPEC_DIR/.alt$K.log" 2>&1 || up_rc=$?
# fail fast: an `up` that created nothing must not be followed by a 20-minute wait for it
if [ "$(docker ps -q --filter "label=com.docker.compose.project=$PROJ" | wc -l)" -lt 30 ]; then
  echo "  up --wait exited $up_rc with $(docker ps -q --filter "label=com.docker.compose.project=$PROJ" | wc -l) containers running:" >&2; grep -vE "level=warning" "$SPEC_DIR/.alt$K.log" | head -5 >&2; exit 1; fi
for _ in $(seq 1 1200); do [ "$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/_health" 2>/dev/null)" = 200 ] && break; sleep 1; done
T_H=$(el "$t0"); echo "  t_health=${T_H}s   (up --wait exit $up_rc -> /_health 200)"
CJ=$(mktemp); curl -sS -m 30 -c "$CJ" -o /dev/null "http://127.0.0.1:$PORT/login"; c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ")
curl -sS -m 60 -H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: http://127.0.0.1:$PORT/" -b "$CJ" -c "$CJ" -o /dev/null -X POST "http://127.0.0.1:$PORT/api/login/" -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
c=$(awk '$6=="posthog_csrftoken"{print $7}' "$CJ"); H=(-H "Content-Type: application/json" -H "X-CSRFToken: $c" -H "Referer: http://127.0.0.1:$PORT/" -b "$CJ" -c "$CJ")
PID=$(docker exec ph-alt$K-clickhouse-1 clickhouse-client --database posthog --query "select team_id from events group by team_id order by count() desc limit 1" 2>/dev/null)
tr() { curl -sS -m 300 "${H[@]}" -X POST "http://127.0.0.1:$PORT/api/projects/$PID/query/" -d '{"query":{"kind":"TrendsQuery","dateRange":{"date_from":"-30d"},"interval":"day","series":[{"kind":"EventsNode","event":"$pageview","math":"total"}]}}' | j "r=d.get('results') or []; print(sum(r[0].get('data',[])) if r else 'ERR')"; }
ms() { echo "$1 $(date +%s.%N)" | awk '{printf "%.0f", ($2-$1)*1000}'; }
t0=$(date +%s.%N); a=$(tr); T1=$(ms "$t0"); t0=$(date +%s.%N); b=$(tr); T2=$(ms "$t0")
echo "  trends: cold $T1 ms (total $a), warm $T2 ms (total $b)"
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' | grep "^$PROJ" | awk -F'\t' '{split($2,a," "); v=a[1]; if (v ~ /GiB/) {gsub(/GiB/,"",v); v=v*1024} else {gsub(/MiB/,"",v)}; s+=v; n++} END {printf "  memory: %.0f MiB across %d containers\n", s, n}'
rm -f "$CJ"; echo; echo "alt-baseline $PROJ: clone ${T_CLONE}s, health ${T_H}s, trends cold ${T1} ms / warm ${T2} ms, port $PORT"
