CREATE DATABASE IF NOT EXISTS dr ON CLUSTER dr_cluster;

-- Plain replicated table: every row inserted is kept.
CREATE TABLE IF NOT EXISTS dr.rmt ON CLUSTER dr_cluster
(
    id  UInt64,
    val String,
    ver UInt64,
    ts  DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/rmt', '{replica}')
ORDER BY id;

-- Replicated + deduplicating on ORDER BY key, keeping the highest `ver`.
-- Dedup happens on merge, so reads need FINAL to be deterministic.
CREATE TABLE IF NOT EXISTS dr.rrmt ON CLUSTER dr_cluster
(
    id  UInt64,
    val String,
    ver UInt64,
    ts  DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/rrmt', '{replica}', ver)
ORDER BY id;
