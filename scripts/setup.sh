#!/usr/bin/env bash
# Build the whole lab from scratch: kind cluster -> Keeper -> ClickHouse -> tables.
set -euo pipefail
cd "$(dirname "$0")/.."

kind create cluster --config kind/cluster.yaml --wait 120s

for img in clickhouse/clickhouse-server:24.8 clickhouse/clickhouse-keeper:24.8; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull "$img"
  kind load docker-image "$img" --name ch-dr
done

kubectl apply -f k8s/00-namespace.yaml -f k8s/10-keeper.yaml
kubectl -n ch rollout status sts/chk --timeout=5m

kubectl apply -f k8s/20-clickhouse.yaml
kubectl -n ch rollout status sts/chi --timeout=5m

kubectl -n ch exec -i chi-0 -c clickhouse -- clickhouse-client -mn < sql/01-schema.sql
echo "lab ready"
