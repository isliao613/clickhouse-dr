#!/usr/bin/env bash
# ch.sh <replica-ordinal> <query>  -- run a query on one ClickHouse replica
set -euo pipefail
kubectl -n ch exec -i "chi-$1" -c clickhouse -- clickhouse-client "${@:2}"
