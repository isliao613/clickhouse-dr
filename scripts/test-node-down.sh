#!/usr/bin/env bash
# Scenario 1: one k8s node dies, taking one ClickHouse replica AND one Keeper
# member with it. Keeper keeps quorum (2/3), so the cluster stays writable.
set -euo pipefail
cd "$(dirname "$0")/.."
CH() { kubectl -n ch exec -i "chi-$1" -c clickhouse -- clickhouse-client "${@:2}"; }
VICTIM=$(kubectl -n ch get pod chi-2 -o jsonpath='{.spec.nodeName}')

hr() { printf '\n===== %s =====\n' "$*"; }

hr "0. baseline"
CH 0 -q "TRUNCATE TABLE dr.rmt ON CLUSTER dr_cluster" >/dev/null
CH 0 -q "TRUNCATE TABLE dr.rrmt ON CLUSTER dr_cluster" >/dev/null
CH 0 -q "INSERT INTO dr.rmt  SELECT number,'v1',1,now() FROM numbers(1000)"
CH 0 -q "INSERT INTO dr.rrmt SELECT number,'v1',1,now() FROM numbers(1000)"
sleep 3
for r in 0 1 2; do echo "chi-$r rmt=$(CH $r -q 'SELECT count() FROM dr.rmt') rrmt=$(CH $r -q 'SELECT count() FROM dr.rrmt')"; done

hr "1. kill node $VICTIM (holds chi-2)"
docker stop "$VICTIM" >/dev/null
sleep 25
CH 0 -q "SELECT table,is_readonly,active_replicas,total_replicas FROM system.replicas ORDER BY table FORMAT PrettyCompact"

hr "2. writes during the outage"
CH 0 -q "INSERT INTO dr.rmt  SELECT number+1000,'v2',1,now() FROM numbers(500)" && echo "rmt insert  : OK"
CH 0 -q "INSERT INTO dr.rrmt SELECT number,'v2',2,now() FROM numbers(300)"      && echo "rrmt upsert : OK (300 ids get ver=2)"

hr "3. insert_quorum behaviour with 2/3 replicas alive"
CH 0 -q "INSERT INTO dr.rmt SELECT number+9000,'q3',1,now() FROM numbers(10) SETTINGS insert_quorum=3" 2>&1 | grep -o "Code: [0-9]*.*TOO_FEW_LIVE_REPLICAS" || true
CH 0 -q "INSERT INTO dr.rmt SELECT number+8000,'q2',1,now() FROM numbers(10) SETTINGS insert_quorum=2" && echo "insert_quorum=2    : OK"
CH 0 -q "INSERT INTO dr.rmt SELECT number+7000,'qa',1,now() FROM numbers(10) SETTINGS insert_quorum='auto'" && echo "insert_quorum=auto : OK"

hr "4. reads during the outage"
for r in 0 1; do
  echo "chi-$r rmt=$(CH $r -q 'SELECT count() FROM dr.rmt') rrmt_raw=$(CH $r -q 'SELECT count() FROM dr.rrmt') rrmt_FINAL=$(CH $r -q 'SELECT count() FROM dr.rrmt FINAL')"
done
echo "distributed read: $(CH 0 -q "SELECT count() FROM cluster('dr_cluster', dr.rmt)")"

hr "5. bring the node back"
docker start "$VICTIM" >/dev/null
until CH 2 -q "SELECT 1" >/dev/null 2>&1; do sleep 5; done
until [ "$(CH 2 -q 'SELECT max(absolute_delay) FROM system.replicas' 2>/dev/null)" = "0" ]; do sleep 3; done
for r in 0 1 2; do
  echo "chi-$r rmt=$(CH $r -q 'SELECT count() FROM dr.rmt') rrmt_raw=$(CH $r -q 'SELECT count() FROM dr.rrmt') rrmt_FINAL=$(CH $r -q 'SELECT count() FROM dr.rrmt FINAL') final_v2=$(CH $r -q "SELECT count() FROM dr.rrmt FINAL WHERE val='v2'")"
done
CH 2 -q "SELECT table,is_readonly,active_replicas,queue_size,absolute_delay FROM system.replicas ORDER BY table FORMAT PrettyCompact"
