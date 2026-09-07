# ClickHouse DR lab on kind — 3 replicas, one-node-down verification

1 shard × 3 replicas of ClickHouse 24.8, backed by a 3-node ClickHouse Keeper
ensemble, on a 4-node kind cluster (1 control-plane + 3 workers). Each
ClickHouse replica and each Keeper member sits on a different worker, so
stopping one worker container is a genuine single-node failure.

```
worker    worker2   worker3
chi-0     chi-1     chi-2      <- ReplicatedMergeTree / ReplicatedReplacingMergeTree
chk-0     chk-2     chk-1      <- ClickHouse Keeper (raft)
```

## Layout

| Path | What |
| --- | --- |
| `kind/cluster.yaml` | 4-node kind cluster |
| `k8s/10-keeper.yaml` | Keeper StatefulSet; an initContainer writes `server_id` from the pod ordinal |
| `k8s/20-clickhouse.yaml` | ClickHouse StatefulSet, `dr_cluster` topology, per-pod `macros` + `interserver_http_host` |
| `sql/01-schema.sql` | `dr.rmt` (ReplicatedMergeTree) and `dr.rrmt` (ReplicatedReplacingMergeTree) |
| `scripts/setup.sh` | Build the lab from scratch |
| `scripts/test-node-down.sh` | Scenario 1 — one worker node killed |
| `scripts/test-keeper-quorum-loss.sh` | Scenario 2 — Keeper below quorum |
| `scripts/teardown.sh` | Delete the kind cluster |
| `docs/insert-quorum.md` | How to change `insert_quorum` (per query / session / HTTP / permanent) |

```bash
./scripts/setup.sh
./scripts/test-node-down.sh
./scripts/test-keeper-quorum-loss.sh
```

## Scenario 1 — one node down (Keeper keeps quorum 2/3)

Killed `ch-dr-worker3`, which held **both** `chi-2` and `chk-1` (the Keeper
raft *leader*).

| Check | Result |
| --- | --- |
| Keeper leader election | `chk-0` promoted to leader within ~20s |
| `system.replicas.is_readonly` on survivors | `0` — stays writable |
| `active_replicas` | `3` → `2` |
| `INSERT` on `chi-0` (stock `insert_quorum=0`) | succeeds, 0.29s |
| `SELECT` on survivors | unaffected |
| `SELECT ... FROM cluster('dr_cluster', …)` | succeeds, routed to a live replica |
| `errors_count` for the dead host in `system.clusters` | stayed `0` (only bumped by actual distributed query attempts) |

**Both engines behave identically here** — replication is an engine-agnostic
layer. The only difference is what a read returns:

| | `dr.rmt` (RMT) | `dr.rrmt` (RRMT) |
| --- | --- | --- |
| rows written | 1000 + 500 | 1000 + 300 re-inserted ids with `ver=2` |
| `count()` | 1500 | 1300 (duplicates not yet merged) |
| `count() FINAL` | 1500 | 1000, of which 300 rows are `v2` |

The node outage does not change ReplacingMergeTree semantics — dedup is a
*merge-time* property, not a replication property. Duplicates linger until a
background merge collapses them, with or without a failed node, so `FINAL`
(or `argMax` aggregation) is required for a deterministic read either way.

### `insert_quorum` is where the two-replica state actually bites

```
insert_quorum=3     -> Code 285. TOO_FEW_LIVE_REPLICAS:
                       Number of alive replicas (2) is less than requested quorum (3/3)
insert_quorum=2     -> OK
insert_quorum='auto'-> OK   (auto = majority = 2 of 3)
```

Default `insert_quorum=0` means an `INSERT` is acked as soon as **one** replica
plus Keeper has it. If that replica dies before another replica fetches the
part, the ack was a lie. `insert_quorum='auto'` is the setting that survives one
node down *and* keeps the durability promise — a hard `insert_quorum=3` turns a
single node failure into a full write outage. **This lab now ships
`insert_quorum=auto` as the cluster-wide default** in the `ch-config` ConfigMap;
the numbers above were measured against the stock `0`, and both survive one node
down because `auto` resolves to 2 of 3.

See [`docs/insert-quorum.md`](docs/insert-quorum.md) for how to actually change
it, including the `subPath` ConfigMap gotcha that makes an edit look like a
no-op.

### Recovery

`docker start` on the worker → `chi-2` restarted and caught up on its own:

```
chi-2 answering 12s after node start, rmt=1520 (fully caught up)
queue_size=0  absolute_delay=0  active_replicas=3
```

All three replicas converged to `rmt=1520`, `rrmt_raw=1300`,
`rrmt FINAL=1000`, `final_v2=300`. No manual `SYSTEM RESTORE REPLICA` or
`SYNC REPLICA` was needed — the returning replica replayed the Keeper
replication log and fetched the missing parts over the interserver port.

## Scenario 2 — Keeper below quorum (only 1 of 3 alive)

This is the failure that actually stops writes, and it is a *separate* failure
domain from the ClickHouse replicas.

```
SELECT count() FROM dr.rmt         -> 1520      (reads never touch Keeper)
INSERT ...                         -> Code 242. TABLE_IS_READ_ONLY
system.replicas.is_readonly        -> 1
system.replicas.is_session_expired -> 1
system.replicas.active_replicas    -> 0
```

Note the failure mode: with default settings the `INSERT` **hangs** rather than
erroring, because `insert_keeper_max_retries` (default 20, exponential backoff)
keeps retrying. Setting `insert_keeper_max_retries=1` surfaces the real error.
Worth knowing for client timeout tuning — a Keeper outage looks like a hang, not
a failure, to an application.

Restoring Keeper to 3 members cleared read-only automatically within ~30s and
writes resumed with no operator action.

## Takeaways

1. **One node down is a non-event for writes** as long as Keeper keeps quorum
   and you are not using `insert_quorum` > number of surviving replicas.
2. **ReplicatedMergeTree and ReplicatedReplacingMergeTree fail identically.**
   RRMT's dedup is orthogonal to availability; it only ever guarantees
   *eventual* collapse, so read with `FINAL`.
3. **Keeper quorum, not replica count, is the write-availability boundary.**
   3 Keeper members tolerate 1 loss. Do not co-locate Keeper members, and do
   not run Keeper on the same failure domain pattern that would take two out at
   once.
4. **Use `insert_quorum='auto'`** if you need "the ack means it survived a node
   loss". The default 0 trades durability for availability silently.
5. **A Keeper outage presents as a hang.** Tune `insert_keeper_max_retries` and
   client-side timeouts so this is observable.

## Notes / limitations

- `kind`'s local-path provisioner gives each pod a hostPath PV on its node, so
  a node that never comes back also loses its data — the same as a real
  node-local-disk deployment. Recovery here was tested as node restart, not
  node replacement.
- Kubernetes marks a node `NotReady` after ~40s and only evicts its pods after
  the 5m toleration, so `kubectl get pods` shows the dead replica as `Running`
  for several minutes. `system.replicas.active_replicas` reflects reality much
  faster (Keeper ephemeral node expiry, ~30s session timeout).
- ClickHouse is deployed as plain StatefulSets on purpose, to keep the failure
  behaviour visible. A production deployment would use the Altinity
  clickhouse-operator.
