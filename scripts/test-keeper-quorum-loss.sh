#!/usr/bin/env bash
# Scenario 2: Keeper drops below quorum (only 1 of 3 left). Replicated tables
# go read-only; SELECTs keep working.
set -euo pipefail
CH() { kubectl -n ch exec -i "chi-$1" -c clickhouse -- clickhouse-client "${@:2}"; }

echo "===== scale Keeper 3 -> 1 (quorum lost) ====="
kubectl -n ch scale sts chk --replicas=1
until [ "$(kubectl -n ch get pods -l app=chk --no-headers | wc -l)" = "1" ]; do sleep 3; done
sleep 35

echo "===== SELECT still works ====="
CH 0 -q "SELECT count() FROM dr.rmt"

echo "===== INSERT fails (bounded retries so it does not hang) ====="
CH 0 -q "INSERT INTO dr.rmt SELECT number+20000,'nq',1,now() FROM numbers(5) SETTINGS insert_keeper_max_retries=1" 2>&1 | grep -o "Code: [0-9]*.*TABLE_IS_READ_ONLY" || true

CH 0 -q "SELECT table,is_readonly,is_session_expired,active_replicas FROM system.replicas ORDER BY table FORMAT PrettyCompact"

echo "===== restore Keeper 1 -> 3 ====="
kubectl -n ch scale sts chk --replicas=3
kubectl -n ch rollout status sts/chk --timeout=5m
until [ "$(CH 0 -q 'SELECT min(NOT is_readonly) FROM system.replicas' 2>/dev/null)" = "1" ]; do sleep 5; done
CH 0 -q "SELECT table,is_readonly,active_replicas,total_replicas FROM system.replicas ORDER BY table FORMAT PrettyCompact"
CH 0 -q "INSERT INTO dr.rmt SELECT number+20000,'after-quorum',1,now() FROM numbers(5)" && echo "writes restored"
